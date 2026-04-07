package com.clawdphone.app.channels

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Platform channel handling all file-related tools:
 * FileSearch, FileRead, FileWrite, FileEdit, Metadata, StorageStats,
 * DirectoryList, FileContentSearch, RecentActivity, LargeFiles
 */
class FileToolsChannel private constructor(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {

    private data class SearchSpec(
        val globRegex: Regex?,
        val extensions: Set<String>,
        val terms: List<String>,
    )

    private data class EpubContentEntry(
        val entryName: String,
        val title: String?,
    )

    private data class RecentReadKey(
        val path: String,
        val entry: String?,
        val startLine: Int,
        val limit: Int,
        val modifiedTimeMs: Long,
    )

    private data class RecentReadValue(
        val timestampMs: Long,
        val contentType: String,
    )

    private data class WorkspaceTextSnapshot(
        val normalizedContent: String,
        val hadBom: Boolean,
        val lineEnding: String,
    )

    private data class WorkspaceReadState(
        val modifiedTimeMs: Long,
        val normalizedContent: String,
        val hadBom: Boolean,
        val lineEnding: String,
        val isPartial: Boolean,
        val timestampMs: Long,
    )

    private data class WorkspaceTarget(
        val relativePath: String,
        val file: File,
        val extension: String,
    )

    companion object {
        private const val CHANNEL = "com.clawdphone.app/tools"
        private const val TAG = "FileToolsChannel"
        private var currentInstance: FileToolsChannel? = null

        fun register(engine: FlutterEngine, activity: Activity) {
            currentInstance?.shutdown()
            val instance = FileToolsChannel(activity)
            currentInstance = instance
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler(instance)
        }
    }

    private val contentResolver: ContentResolver get() = activity.contentResolver

    private val deviceTools = DeviceToolsChannel(activity)
    private val personalTools = PersonalToolsChannel(activity)
    private val appTools = AppToolsChannel(activity)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "clawd-tool-worker").also { it.isDaemon = true }
    }
    private val recentReadCache = LinkedHashMap<RecentReadKey, RecentReadValue>()

    private val recentReadWindowMs = 60_000L
    private val maxRecentReadEntries = 24
    private val maxReadOutputTokens = 25_000
    private val maxTextFileSize = 256L * 1024
    private val maxTextLineLength = 10_000
    private val maxReadOutputChars = 80_000
    private val maxEpubOutputChars = 40_000
    private val maxEpubSyntheticLineLength = 240
    private val maxEpubLineLength = 2_000
    private val workspaceRoot = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        "Clawd-Phone"
    )
    private val workspaceAllowedExtensions = setOf("html", "md", "txt", "csv")
    private val workspaceReadState = LinkedHashMap<String, WorkspaceReadState>()
    private val maxWorkspaceReadEntries = 48

    fun shutdown() {
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "FileSearch" -> runHeavyTool("FileSearch", result) { proxy -> handleFileSearch(call, proxy) }
            "FileRead" -> runHeavyTool("FileRead", result) { proxy -> handleFileRead(call, proxy) }
            "FileWrite" -> runHeavyTool("FileWrite", result) { proxy -> handleFileWrite(call, proxy) }
            "FileEdit" -> runHeavyTool("FileEdit", result) { proxy -> handleFileEdit(call, proxy) }
            "ImageAnalyze" -> runHeavyTool("ImageAnalyze", result) { proxy -> handleImageAnalyze(call, proxy) }
            "Metadata" -> runHeavyTool("Metadata", result) { proxy -> handleMetadata(call, proxy) }
            "StorageStats" -> runHeavyTool("StorageStats", result) { proxy -> handleStorageStats(call, proxy) }
            "DirectoryList" -> runHeavyTool("DirectoryList", result) { proxy -> handleDirectoryList(call, proxy) }
            "LargeFiles" -> runHeavyTool("LargeFiles", result) { proxy -> handleLargeFiles(call, proxy) }
            "RecentActivity" -> runHeavyTool("RecentActivity", result) { proxy -> handleRecentActivity(call, proxy) }
            "FileContentSearch" -> runHeavyTool("FileContentSearch", result) { proxy -> handleFileContentSearch(call, proxy) }
            "DeviceInfo", "Battery" -> deviceTools.onMethodCall(call, result)
            "Contacts", "Calendar", "Location", "CallLog", "Notifications" -> personalTools.onMethodCall(call, result)
            "AppDetail", "UsageStats" -> appTools.onMethodCall(call, result)
            "checkUsageStatsPermission" -> {
                try {
                    val appOps = activity.getSystemService(android.content.Context.APP_OPS_SERVICE) as android.app.AppOpsManager
                    val mode = if (Build.VERSION.SDK_INT >= 29) {
                        appOps.unsafeCheckOpNoThrow(
                            android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                            android.os.Process.myUid(),
                            activity.packageName
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        appOps.checkOpNoThrow(
                            android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                            android.os.Process.myUid(),
                            activity.packageName
                        )
                    }
                    result.success(mode == android.app.AppOpsManager.MODE_ALLOWED)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "checkNotificationListenerPermission" -> {
                try {
                    val pkgName = activity.packageName
                    val flat = android.provider.Settings.Secure.getString(
                        activity.contentResolver,
                        "enabled_notification_listeners"
                    )
                    result.success(flat != null && flat.contains(pkgName))
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "checkCalendarPermission" -> {
                result.success(
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED
                )
            }
            "checkCallLogPermission" -> {
                result.success(
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
                )
            }
            "checkStoragePermission" -> {
                val hasFullAccess = hasFullStorageAccess()

                val hasMediaAccess = if (Build.VERSION.SDK_INT >= 33) {
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_AUDIO) == PackageManager.PERMISSION_GRANTED
                } else {
                    ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                }

                val resultMap = HashMap<String, Boolean>()
                resultMap["full_access"] = hasFullAccess
                resultMap["media_access"] = hasMediaAccess || hasFullAccess
                result.success(resultMap)
            }
            "openUsageAccessSettings" -> {
                try {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS)
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("SETTINGS_ERROR", e.message, null)
                }
            }
            "openNotificationListenerSettings" -> {
                try {
                    val intent = android.content.Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("SETTINGS_ERROR", e.message, null)
                }
            }
            "openAllFilesAccessSettings" -> {
                try {
                    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        android.content.Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                            data = Uri.parse("package:${activity.packageName}")
                        }
                    } else {
                        android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:${activity.packageName}")
                        }
                    }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    try {
                        val fallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            android.content.Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        } else {
                            android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:${activity.packageName}")
                            }
                        }
                        activity.startActivity(fallback)
                        result.success(true)
                    } catch (inner: Exception) {
                        result.error("SETTINGS_ERROR", inner.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun runHeavyTool(
        toolName: String,
        result: MethodChannel.Result,
        work: (MethodChannel.Result) -> Unit
    ) {
        val replied = AtomicBoolean(false)
        val proxyResult = object : MethodChannel.Result {
            override fun success(res: Any?) {
                postResult(replied) {
                    try {
                        result.success(res)
                    } catch (_: IllegalStateException) {
                        // Engine detached while background work was running.
                    }
                }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                postResult(replied) {
                    try {
                        result.error(errorCode, errorMessage, errorDetails)
                    } catch (_: IllegalStateException) {
                        // Engine detached while background work was running.
                    }
                }
            }

            override fun notImplemented() {
                postResult(replied) {
                    try {
                        result.notImplemented()
                    } catch (_: IllegalStateException) {
                        // Engine detached while background work was running.
                    }
                }
            }
        }

        try {
            executor.execute {
                val start = System.currentTimeMillis()
                try {
                    work(proxyResult)
                } catch (e: Exception) {
                    proxyResult.error("${toolName}_ERROR", e.message, null)
                } finally {
                    Log.d(TAG, "$toolName ${System.currentTimeMillis() - start}ms")
                }
            }
        } catch (_: RejectedExecutionException) {
            try {
                result.error("EXECUTOR_SHUTDOWN", "Tool executor unavailable", null)
            } catch (_: IllegalStateException) {
                // Engine detached before we could report the failure.
            }
        }
    }

    private fun postResult(replied: AtomicBoolean, block: () -> Unit) {
        mainHandler.post {
            if (replied.compareAndSet(false, true)) {
                block()
            }
        }
    }

    private fun estimateTextTokens(text: String): Int {
        return (text.length + 3) / 4
    }

    private fun truncateReadLine(line: String, maxChars: Int): String {
        if (line.length <= maxChars) return line
        return line.substring(0, maxChars) + "... [line truncated at $maxChars chars]"
    }

    private fun suggestReadLimit(
        totalChars: Int,
        lineCount: Int,
        maxChars: Int,
        maxTokens: Int,
        fallbackLimit: Int,
    ): Int {
        if (lineCount <= 0 || totalChars <= 0) return fallbackLimit
        val avgCharsPerLine = maxOf(1, totalChars / lineCount)
        val charBudget = minOf(maxChars, maxTokens * 4)
        return maxOf(1, charBudget / avgCharsPerLine)
    }

    private fun oversizedReadMessage(
        label: String,
        charCount: Int,
        estimatedTokens: Int,
        maxChars: Int,
        maxTokens: Int,
        suggestedLimit: Int,
    ): String {
        return "The requested $label produced $charCount characters and $estimatedTokens estimated tokens " +
            "(max $maxChars chars / $maxTokens tokens). Reduce the limit parameter — try limit=$suggestedLimit."
    }

    private fun maybeReturnRecentReadStub(
        result: MethodChannel.Result,
        file: File,
        entry: String?,
        startLine: Int,
        limit: Int,
    ): Boolean {
        val key = RecentReadKey(
            path = file.absolutePath,
            entry = entry,
            startLine = startLine,
            limit = limit,
            modifiedTimeMs = file.lastModified(),
        )
        val now = System.currentTimeMillis()
        val cached = synchronized(recentReadCache) {
            pruneRecentReadCacheLocked(now)
            recentReadCache[key]
        } ?: return false

        if (now - cached.timestampMs > recentReadWindowMs) return false

        val response = JSONObject().apply {
            put("content_type", "file_unchanged")
            put("file_name", file.name)
            put("path", file.absolutePath)
            put("original_content_type", cached.contentType)
            put("start_line", startLine)
            put("requested_limit", limit)
            if (!entry.isNullOrBlank()) put("entry", entry)
            put(
                "message",
                "File unchanged since the last identical FileRead. Use the earlier FileRead result for this same range instead of re-reading."
            )
        }
        result.success(response.toString())
        return true
    }

    private fun rememberRecentRead(
        file: File,
        entry: String?,
        startLine: Int,
        limit: Int,
        contentType: String,
    ) {
        val key = RecentReadKey(
            path = file.absolutePath,
            entry = entry,
            startLine = startLine,
            limit = limit,
            modifiedTimeMs = file.lastModified(),
        )
        val value = RecentReadValue(
            timestampMs = System.currentTimeMillis(),
            contentType = contentType,
        )
        synchronized(recentReadCache) {
            recentReadCache[key] = value
            pruneRecentReadCacheLocked(value.timestampMs)
            while (recentReadCache.size > maxRecentReadEntries) {
                val eldestKey = recentReadCache.entries.firstOrNull()?.key ?: break
                recentReadCache.remove(eldestKey)
            }
        }
    }

    private fun normalizeLineEndings(text: String): String {
        return text.replace("\r\n", "\n").replace('\r', '\n')
    }

    private fun detectLineEnding(text: String): String {
        return when {
            text.contains("\r\n") -> "\r\n"
            text.contains('\r') -> "\r"
            else -> "\n"
        }
    }

    private fun readWorkspaceTextSnapshot(file: File): WorkspaceTextSnapshot {
        val bytes = file.readBytes()
        val hasBom = bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() &&
            bytes[1] == 0xBB.toByte() &&
            bytes[2] == 0xBF.toByte()
        val raw = if (hasBom) bytes.copyOfRange(3, bytes.size) else bytes
        val decoded = raw.toString(Charsets.UTF_8)
        return WorkspaceTextSnapshot(
            normalizedContent = normalizeLineEndings(decoded),
            hadBom = hasBom,
            lineEnding = detectLineEnding(decoded),
        )
    }

    private fun encodeWorkspaceText(
        normalizedContent: String,
        lineEnding: String,
        includeBom: Boolean,
    ): ByteArray {
        val onDiskText = when (lineEnding) {
            "\r\n" -> normalizedContent.replace("\n", "\r\n")
            "\r" -> normalizedContent.replace("\n", "\r")
            else -> normalizedContent
        }
        val encoded = onDiskText.toByteArray(Charsets.UTF_8)
        if (!includeBom) return encoded
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        return bom + encoded
    }

    private fun isWorkspacePath(path: String): Boolean {
        val rootPath = workspaceRoot.canonicalFile.path
        val filePath = File(path).canonicalFile.path
        return filePath == rootPath || filePath.startsWith("$rootPath${File.separator}")
    }

    private fun ensureWorkspaceRoot() {
        if (workspaceRoot.exists()) return
        if (!workspaceRoot.mkdirs() && !workspaceRoot.exists()) {
            throw IllegalStateException("Failed to create Clawd-Phone workspace.")
        }
    }

    private fun resolveWorkspaceTarget(rawRelativePath: String?): WorkspaceTarget {
        val normalizedSlashes = rawRelativePath?.trim()?.replace('\\', '/') ?: ""
        if (normalizedSlashes.isBlank()) {
            throw IllegalArgumentException("relative_path is required.")
        }
        if (normalizedSlashes.startsWith("/") || normalizedSlashes.startsWith("~")) {
            throw IllegalArgumentException("relative_path must be inside Download/Clawd-Phone/, not absolute.")
        }

        val segments = normalizedSlashes
            .split('/')
            .filter { it.isNotBlank() }
        if (segments.isEmpty()) {
            throw IllegalArgumentException("relative_path is required.")
        }
        if (segments.any { it == "." || it == ".." }) {
            throw IllegalArgumentException("relative_path may not contain '.' or '..'.")
        }

        val normalizedRelativePath = segments.joinToString("/")
        val target = File(workspaceRoot, normalizedRelativePath).canonicalFile
        val root = workspaceRoot.canonicalFile
        val rootPath = root.path
        if (target.path == rootPath || !target.path.startsWith("$rootPath${File.separator}")) {
            throw IllegalArgumentException("relative_path escapes the Clawd-Phone workspace.")
        }

        val extension = target.extension.lowercase()
        if (extension !in workspaceAllowedExtensions) {
            throw IllegalArgumentException("Unsupported file type. Allowed: .html, .md, .txt, .csv.")
        }

        return WorkspaceTarget(
            relativePath = normalizedRelativePath,
            file = target,
            extension = extension,
        )
    }

    private fun updateWorkspaceReadState(
        file: File,
        snapshot: WorkspaceTextSnapshot,
        isPartial: Boolean,
    ) {
        val path = file.absolutePath
        val modifiedTime = file.lastModified()
        val now = System.currentTimeMillis()
        synchronized(workspaceReadState) {
            val existing = workspaceReadState[path]
            if (isPartial &&
                existing != null &&
                !existing.isPartial &&
                existing.modifiedTimeMs == modifiedTime
            ) {
                return
            }
            workspaceReadState[path] = WorkspaceReadState(
                modifiedTimeMs = modifiedTime,
                normalizedContent = if (isPartial) "" else snapshot.normalizedContent,
                hadBom = snapshot.hadBom,
                lineEnding = snapshot.lineEnding,
                isPartial = isPartial,
                timestampMs = now,
            )
            while (workspaceReadState.size > maxWorkspaceReadEntries) {
                val eldestKey = workspaceReadState.entries.firstOrNull()?.key ?: break
                workspaceReadState.remove(eldestKey)
            }
        }
    }

    private fun getWorkspaceReadState(file: File): WorkspaceReadState? {
        return synchronized(workspaceReadState) {
            workspaceReadState[file.absolutePath]
        }
    }

    private fun requireFreshWorkspaceRead(file: File, action: String): WorkspaceReadState {
        val state = getWorkspaceReadState(file)
            ?: throw IllegalStateException("Read the current file with FileRead before trying to $action it.")
        if (state.isPartial) {
            throw IllegalStateException("Read the full file with FileRead before trying to $action it.")
        }
        if (file.lastModified() != state.modifiedTimeMs) {
            throw IllegalStateException("File changed since the last read. Read it again before trying to $action it.")
        }
        return state
    }

    private fun countOccurrences(text: String, needle: String): Int {
        if (needle.isEmpty()) return 0
        var count = 0
        var start = 0
        while (true) {
            val index = text.indexOf(needle, startIndex = start)
            if (index < 0) break
            count++
            start = index + needle.length
        }
        return count
    }

    private fun pruneRecentReadCacheLocked(now: Long) {
        val iterator = recentReadCache.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (now - entry.value.timestampMs > recentReadWindowMs) {
                iterator.remove()
            }
        }
    }

    private fun handleFileSearch(call: MethodCall, result: MethodChannel.Result) {
        if (!hasMediaPermission()) {
            return result.error("PERMISSION_DENIED", "Media permission not granted. Please grant storage/media permissions in Settings.", null)
        }
        try {
            val query = call.argument<String>("query")
            val mimeType = call.argument<String>("mime_type")
            val minSize = call.argument<Number>("min_size_bytes")?.toLong()
            val maxSize = call.argument<Number>("max_size_bytes")?.toLong()
            val dateAfter = call.argument<String>("date_after")
            val dateBefore = call.argument<String>("date_before")
            val directory = call.argument<String>("directory")
            val sortBy = call.argument<String>("sort_by") ?: "date_modified"
            val limit = (call.argument<Int>("limit") ?: 20).coerceIn(1, 100)
            val offset = (call.argument<Int>("offset") ?: 0).coerceAtLeast(0)
            val querySpec = buildSearchSpec(query)

            val uri = MediaStore.Files.getContentUri("external")
            // RELATIVE_PATH only available on Android 10+ (API 29).
            // On older devices use _data (full path) instead.
            val hasRelativePath = Build.VERSION.SDK_INT >= 29
            val projection = if (hasRelativePath) arrayOf(
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                MediaStore.Files.FileColumns.RELATIVE_PATH,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.MIME_TYPE,
                MediaStore.Files.FileColumns.DATE_MODIFIED,
                MediaStore.Files.FileColumns.DATE_ADDED
            ) else arrayOf(
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                @Suppress("DEPRECATION") MediaStore.Files.FileColumns.DATA,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.MIME_TYPE,
                MediaStore.Files.FileColumns.DATE_MODIFIED,
                MediaStore.Files.FileColumns.DATE_ADDED
            )

            val selection = StringBuilder()
            val selectionArgs = mutableListOf<String>()

            if (!mimeType.isNullOrEmpty()) {
                if (selection.isNotEmpty()) selection.append(" AND ")
                if (mimeType.endsWith("/*")) {
                    selection.append("${MediaStore.Files.FileColumns.MIME_TYPE} LIKE ?")
                    selectionArgs.add(mimeType.replace("/*", "/%"))
                } else {
                    selection.append("${MediaStore.Files.FileColumns.MIME_TYPE} = ?")
                    selectionArgs.add(mimeType)
                }
            }

            if (minSize != null) {
                if (selection.isNotEmpty()) selection.append(" AND ")
                selection.append("${MediaStore.Files.FileColumns.SIZE} >= ?")
                selectionArgs.add(minSize.toString())
            }

            if (maxSize != null) {
                if (selection.isNotEmpty()) selection.append(" AND ")
                selection.append("${MediaStore.Files.FileColumns.SIZE} <= ?")
                selectionArgs.add(maxSize.toString())
            }

            if (!dateAfter.isNullOrEmpty()) {
                val epochSeconds = parseToEpochSeconds(dateAfter) ?: dateAfter.toLongOrNull()
                if (epochSeconds != null) {
                    if (selection.isNotEmpty()) selection.append(" AND ")
                    selection.append("${MediaStore.Files.FileColumns.DATE_MODIFIED} >= ?")
                    selectionArgs.add(epochSeconds.toString())
                }
            }

            if (!dateBefore.isNullOrEmpty()) {
                val epochSeconds = parseToEpochSeconds(dateBefore) ?: dateBefore.toLongOrNull()
                if (epochSeconds != null) {
                    if (selection.isNotEmpty()) selection.append(" AND ")
                    selection.append("${MediaStore.Files.FileColumns.DATE_MODIFIED} <= ?")
                    selectionArgs.add(epochSeconds.toString())
                }
            }

            if (!directory.isNullOrEmpty()) {
                if (selection.isNotEmpty()) selection.append(" AND ")
                if (hasRelativePath) {
                    selection.append("${MediaStore.Files.FileColumns.RELATIVE_PATH} LIKE ?")
                    selectionArgs.add("%$directory%")
                } else {
                    @Suppress("DEPRECATION")
                    selection.append("${MediaStore.Files.FileColumns.DATA} LIKE ?")
                    selectionArgs.add("%$directory%")
                }
            }

            val sortColumn = when (sortBy) {
                "name" -> MediaStore.Files.FileColumns.DISPLAY_NAME
                "size" -> MediaStore.Files.FileColumns.SIZE
                "date_added" -> MediaStore.Files.FileColumns.DATE_ADDED
                else -> MediaStore.Files.FileColumns.DATE_MODIFIED
            }

            val resultByPath = linkedMapOf<String, JSONObject>()

            val cursor = contentResolver.query(
                uri, projection,
                selection.toString().ifEmpty { null },
                if (selectionArgs.isEmpty()) null else selectionArgs.toTypedArray(),
                "$sortColumn DESC"
            )

            cursor?.use { c ->
                while (c.moveToNext()) {
                    val name = c.getStringOrNull(MediaStore.Files.FileColumns.DISPLAY_NAME) ?: ""
                    val fullPath: String
                    val relativePath: String
                    if (hasRelativePath) {
                        relativePath = c.getStringOrNull(MediaStore.Files.FileColumns.RELATIVE_PATH) ?: ""
                        fullPath = "/storage/emulated/0/$relativePath$name"
                    } else {
                        @Suppress("DEPRECATION")
                        fullPath = c.getStringOrNull(MediaStore.Files.FileColumns.DATA) ?: ""
                        relativePath = fullPath.removePrefix("/storage/emulated/0/").removeSuffix(name)
                    }
                    val sizeBytes = c.getLongOrNull(MediaStore.Files.FileColumns.SIZE) ?: 0
                    val file = JSONObject().apply {
                        put("name", name)
                        put("relative_path", relativePath)
                        put("path", fullPath)
                        put("size_bytes", sizeBytes)
                        put("size_human", formatSize(sizeBytes))
                        put("mime_type", c.getStringOrNull(MediaStore.Files.FileColumns.MIME_TYPE))
                        put("date_modified", c.getLongOrNull(MediaStore.Files.FileColumns.DATE_MODIFIED))
                        put("date_added", c.getLongOrNull(MediaStore.Files.FileColumns.DATE_ADDED))
                    }
                    if (!matchesSearchSpec(name, relativePath, querySpec)) continue
                    addSearchResult(resultByPath, file)
                }
            }

            // Always search the filesystem too — real public storage traversal
            // instead of relying only on MediaStore indexing.
            val mimeMatch = mimeType?.let {
                val regexStr = it.split("*").joinToString(".*") { part ->
                    Regex.escape(part)
                }
                Regex("^$regexStr$", RegexOption.IGNORE_CASE)
            }
            for (root in getSearchRoots(directory)) {
                _walkFilesFiltered(
                    root = root,
                    out = resultByPath,
                    limit = Int.MAX_VALUE,
                    spec = querySpec,
                    mimeMatch = mimeMatch,
                    minSize = minSize,
                    maxSize = maxSize,
                    dateAfter = dateAfter,
                    dateBefore = dateBefore,
                    maxDepth = if (directory.isNullOrEmpty()) 4 else 6,
                    currentDepth = 0
                )
            }

            val sortedFiles = resultByPath.values.toMutableList()
            when (sortBy) {
                "name" -> sortedFiles.sortBy { it.optString("name").lowercase() }
                "size" -> sortedFiles.sortByDescending { it.optLong("size_bytes") }
                "date_added" -> sortedFiles.sortByDescending { it.optLong("date_added") }
                else -> sortedFiles.sortByDescending { it.optLong("date_modified") }
            }

            val files = JSONArray()
            sortedFiles.drop(offset).take(limit).forEach { files.put(it) }
            val totalMatches = sortedFiles.size
            val returned = files.length()
            val nextOffset = (offset + returned).takeIf { it < totalMatches }
            val hasMore = nextOffset != null

            val response = JSONObject().apply {
                put("files", files)
                put("total_matches", totalMatches)
                put("returned", returned)
                put("offset", offset)
                put("has_more", hasMore)
                put("truncated", hasMore)
                if (nextOffset != null) put("next_offset", nextOffset)
            }

            // Warn when document queries may be incomplete due to limited permissions
            if (Build.VERSION.SDK_INT >= 33 && !hasFullStorageAccess()) {
                val docExtensions = setOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "txt", "csv")
                val isDocumentQuery = mimeType?.startsWith("application/") == true ||
                    querySpec.extensions.any { it in docExtensions } ||
                    (query?.lowercase()?.let { q -> docExtensions.any { q.contains(it) } } == true)
                if (isDocumentQuery) {
                    response.put("permission_note",
                        "Document search may be incomplete. Only media permissions are granted — " +
                        "PDFs and other documents require 'All Files Access'. " +
                        "Ask the user to enable it in the app's Settings > Files & Media > Enable Full Access.")
                }
            }

            result.success(response.toString())
        } catch (e: Exception) {
            result.error("FILE_SEARCH_ERROR", e.message, null)
        }
    }

    /** Walk filesystem, filtering and collecting matching files into a map keyed by path. */
    private fun _walkFilesFiltered(
        root: File,
        out: MutableMap<String, JSONObject>,
        limit: Int,
        spec: SearchSpec,
        mimeMatch: Regex?,
        minSize: Long?, maxSize: Long?,
        dateAfter: String?, dateBefore: String?,
        maxDepth: Int, currentDepth: Int
    ) {
        if (currentDepth > maxDepth || out.size >= limit) return
        val children = root.listFiles() ?: return
        for (f in children) {
            if (f.name.startsWith(".")) continue
            if (f.isFile) {
                if (!matchesSearchSpec(f.name, f.parent.orEmpty(), spec)) continue
                val fMime = guessMimeType(f.name)
                if (mimeMatch != null && !mimeMatch.containsMatchIn(fMime)) continue
                if (minSize != null && f.length() < minSize) continue
                if (maxSize != null && f.length() > maxSize) continue
                val modifiedSeconds = f.lastModified() / 1000
                val afterSeconds = dateAfter?.let { parseToEpochSeconds(it) ?: it.toLongOrNull() }
                val beforeSeconds = dateBefore?.let { parseToEpochSeconds(it) ?: it.toLongOrNull() }
                if (afterSeconds != null && modifiedSeconds < afterSeconds) continue
                if (beforeSeconds != null && modifiedSeconds > beforeSeconds) continue
                val relPath = f.parent?.removePrefix("/storage/emulated/0/")?.plus("/") ?: ""
                addSearchResult(out, JSONObject().apply {
                    put("name", f.name)
                    put("relative_path", relPath)
                    put("path", f.absolutePath)
                    put("size_bytes", f.length())
                    put("size_human", formatSize(f.length()))
                    put("mime_type", fMime)
                    put("date_modified", modifiedSeconds)
                    put("source", "filesystem")
                })
                if (out.size >= limit) return
            } else if (f.isDirectory && f.name != "Android") {
                _walkFilesFiltered(f, out, limit, spec, mimeMatch, minSize, maxSize, dateAfter, dateBefore, maxDepth, currentDepth + 1)
            }
        }
    }

    /** Collect all files from filesystem (for top_files fallback). */
    private fun _collectAllFiles(dir: File, out: MutableList<File>, maxDepth: Int, currentDepth: Int) {
        if (currentDepth > maxDepth) return
        val children = dir.listFiles() ?: return
        for (f in children) {
            if (f.name.startsWith(".")) continue
            if (f.isFile) out.add(f)
            else if (f.isDirectory && f.name != "Android") {
                _collectAllFiles(f, out, maxDepth, currentDepth + 1)
            }
        }
    }

    /** Walk filesystem and count files by MIME category for StorageStats fallback. */
    private fun _countFilesByType(
        dir: File,
        counts: MutableMap<String, Pair<Int, Long>>,
        maxDepth: Int,
        currentDepth: Int
    ) {
        if (currentDepth > maxDepth) return
        val children = dir.listFiles() ?: return
        for (f in children) {
            if (f.name.startsWith(".")) continue
            if (f.isFile) {
                val mime = guessMimeType(f.name)
                val category = when {
                    mime.startsWith("image/") -> "images"
                    mime.startsWith("video/") -> "videos"
                    mime.startsWith("audio/") -> "audio"
                    mime.startsWith("application/") || mime.startsWith("text/") -> "documents"
                    else -> null
                }
                if (category != null) {
                    val (c, s) = counts[category]!!
                    counts[category] = Pair(c + 1, s + f.length())
                }
            } else if (f.isDirectory && f.name != "Android") {
                _countFilesByType(f, counts, maxDepth, currentDepth + 1)
            }
        }
    }

    private fun handleFileRead(call: MethodCall, result: MethodChannel.Result) {
        try {
            val path = call.argument<String>("path") ?: return result.error("MISSING_PATH", "path is required", null)
            val startLine = (call.argument<Int>("offset") ?: 1).coerceAtLeast(1)
            val limit = (call.argument<Int>("limit") ?: 1000).coerceAtLeast(1)
            val file = File(path)

            if (!file.exists()) {
                return result.error("FILE_NOT_FOUND", "File not found: $path", null)
            }

            val mimeType = guessMimeType(path).ifEmpty { "application/octet-stream" }

            when {
                mimeType.startsWith("text/") || isTextFile(path) -> {
                    if (isWorkspacePath(file.absolutePath)) {
                        val requestedOffset = call.argument<Int>("offset")
                        val requestedLimit = call.argument<Int>("limit")
                        val hasExplicitRange = requestedOffset != null || requestedLimit != null

                        if (maybeReturnRecentReadStub(result, file, entry = null, startLine = startLine, limit = limit)) {
                            return
                        }

                        if (!hasExplicitRange && file.length() > maxTextFileSize) {
                            return result.error(
                                "FILE_TOO_LARGE",
                                "Text file is ${formatSize(file.length())} which exceeds the ${formatSize(maxTextFileSize)} limit. " +
                                    "Use offset and limit parameters to read specific portions of the file.",
                                null
                            )
                        }

                        val snapshot = readWorkspaceTextSnapshot(file)
                        val allLines = if (snapshot.normalizedContent.isEmpty()) {
                            emptyList()
                        } else {
                            snapshot.normalizedContent.split('\n')
                        }
                        val contentLines = allLines.drop(startLine - 1).take(limit)
                        val content = contentLines.mapIndexed { index, line ->
                            "${startLine + index}\t${truncateReadLine(line, maxTextLineLength)}"
                        }.joinToString("\n")
                        val charCount = content.length
                        val estimatedTokens = estimateTextTokens(content)
                        if (charCount > maxReadOutputChars || estimatedTokens > maxReadOutputTokens) {
                            val suggestedLimit = suggestReadLimit(
                                totalChars = charCount,
                                lineCount = contentLines.size,
                                maxChars = maxReadOutputChars,
                                maxTokens = maxReadOutputTokens,
                                fallbackLimit = minOf(limit, 500),
                            )
                            return result.error(
                                "CONTENT_TOO_LARGE",
                                oversizedReadMessage(
                                    label = "text range",
                                    charCount = charCount,
                                    estimatedTokens = estimatedTokens,
                                    maxChars = maxReadOutputChars,
                                    maxTokens = maxReadOutputTokens,
                                    suggestedLimit = suggestedLimit,
                                ),
                                null
                            )
                        }

                        val totalLines = allLines.size
                        val isFullRead = startLine == 1 && contentLines.size == totalLines
                        updateWorkspaceReadState(file, snapshot, isPartial = !isFullRead)
                        val response = JSONObject().apply {
                            put("content_type", "text")
                            put("file_name", file.name)
                            put("content", content)
                            put("total_lines", totalLines)
                            put("returned_lines", contentLines.size)
                            put("start_line", startLine)
                            put("size_bytes", file.length())
                        }
                        rememberRecentRead(file, entry = null, startLine = startLine, limit = limit, contentType = "text")
                        result.success(response.toString())
                        return
                    }

                    // Pre-read size check: reject large files unless offset/limit is specified.
                    // When offset > 0 or explicit limit, allow reading a slice of any file.
                    val requestedOffset = call.argument<Int>("offset")
                    val requestedLimit = call.argument<Int>("limit")
                    val hasExplicitRange = requestedOffset != null || requestedLimit != null

                    if (maybeReturnRecentReadStub(result, file, entry = null, startLine = startLine, limit = limit)) {
                        return
                    }

                    if (!hasExplicitRange && file.length() > maxTextFileSize) {
                        return result.error(
                            "FILE_TOO_LARGE",
                            "Text file is ${formatSize(file.length())} which exceeds the ${formatSize(maxTextFileSize)} limit. " +
                            "Use offset and limit parameters to read specific portions of the file, " +
                            "or use FileContentSearch to find specific content.",
                            null
                        )
                    }

                    // Streaming read: only accumulate lines in the requested range.
                    // O(limit) memory instead of O(file_size).
                    // Break early after collecting — estimate totalLines from bytes read.
                    val collected = mutableListOf<String>()
                    var linesScanned = 0
                    var bytesScanned = 0L
                    val fileSize = file.length()
                    var totalLinesExact = true
                    file.bufferedReader().useLines { sequence ->
                        for (rawLine in sequence) {
                            linesScanned++
                            bytesScanned += rawLine.length + 1 // +1 for newline
                            if (linesScanned >= startLine && collected.size < limit) {
                                // Per-line size cap to prevent OOM on pathological files
                                val line = truncateReadLine(rawLine, maxTextLineLength)
                                collected.add("$linesScanned\t$line")
                            }
                            // Break early once we've collected enough — estimate remaining
                            if (linesScanned >= startLine + limit) {
                                totalLinesExact = false
                                break
                            }
                        }
                    }

                    // Estimate total lines if we broke early
                    var totalLines = linesScanned
                    if (!totalLinesExact && linesScanned > 0 && bytesScanned > 0) {
                        val avgBytesPerLine = bytesScanned.toDouble() / linesScanned
                        totalLines = (fileSize / avgBytesPerLine).toInt()
                    }

                    val content = collected.joinToString("\n")
                    val charCount = content.length

                    // Post-read token gate: estimate tokens and reject if too large.
                    val estimatedTokens = estimateTextTokens(content)
                    if (charCount > maxReadOutputChars || estimatedTokens > maxReadOutputTokens) {
                        val suggestedLimit = suggestReadLimit(
                            totalChars = charCount,
                            lineCount = collected.size,
                            maxChars = maxReadOutputChars,
                            maxTokens = maxReadOutputTokens,
                            fallbackLimit = minOf(limit, 500),
                        )
                        return result.error(
                            "CONTENT_TOO_LARGE",
                            oversizedReadMessage(
                                label = "text range",
                                charCount = charCount,
                                estimatedTokens = estimatedTokens,
                                maxChars = maxReadOutputChars,
                                maxTokens = maxReadOutputTokens,
                                suggestedLimit = suggestedLimit,
                            ),
                            null
                        )
                    }

                    val response = JSONObject().apply {
                        put("content_type", "text")
                        put("file_name", file.name)
                        put("content", content)
                        put("total_lines", totalLines)
                        if (!totalLinesExact) put("total_lines_estimated", true)
                        put("returned_lines", collected.size)
                        put("start_line", startLine)
                        put("size_bytes", file.length())
                    }
                    rememberRecentRead(file, entry = null, startLine = startLine, limit = limit, contentType = "text")
                    result.success(response.toString())
                }
                mimeType.startsWith("image/") -> {
                    // Guard against OOM on very large files (API limit ~5MB base64).
                    val maxImageSize = 10L * 1024 * 1024 // 10MB (decode limit)
                    if (file.length() > maxImageSize) {
                        return result.error(
                            "FILE_TOO_LARGE",
                            "Image file is ${formatSize(file.length())} which exceeds the 10MB limit. Use Metadata tool instead.",
                            null
                        )
                    }
                    // Resize+compress to avoid sending raw multi-MB base64 text.
                    val maxDim = 1536
                    val original = android.graphics.BitmapFactory.decodeFile(path)
                    if (original == null) {
                        // Can't decode — fall back to raw bytes (e.g. unsupported format)
                        val bytes = file.readBytes()
                        val base64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                        val response = JSONObject().apply {
                            put("content_type", "image")
                            put("file_name", file.name)
                            put("base64", base64)
                            put("media_type", mimeType)
                            put("original_size_bytes", file.length())
                        }
                        return result.success(response.toString())
                    }
                    val origW = original.width
                    val origH = original.height
                    val ratio = minOf(maxDim.toFloat() / origW, maxDim.toFloat() / origH, 1.0f)
                    val scaled = if (ratio < 1.0f) {
                        android.graphics.Bitmap.createScaledBitmap(
                            original, (origW * ratio).toInt(), (origH * ratio).toInt(), true
                        )
                    } else original
                    val baos = java.io.ByteArrayOutputStream()
                    scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, baos)
                    // If still > 3.75MB raw (5MB base64 API limit), reduce quality further
                    if (baos.size() > 3_750_000) {
                        baos.reset()
                        scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 50, baos)
                    }
                    val base64 = android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP)
                    if (scaled !== original) scaled.recycle()
                    original.recycle()
                    val response = JSONObject().apply {
                        put("content_type", "image")
                        put("file_name", file.name)
                        put("base64", base64)
                        put("media_type", "image/jpeg")
                        put("original_size_bytes", file.length())
                    }
                    result.success(response.toString())
                }
                mimeType == "application/pdf" || path.endsWith(".pdf", ignoreCase = true) -> {
                    // PDF handling:
                    // 1. Small PDFs (< 3MB): send as document block (API reads natively)
                    // 2. Large PDFs or page range: render pages as JPEG via PdfRenderer
                    // No text extraction — Claude's API/vision handles reading.
                    val pagesParam = call.argument<String>("pages")
                    val maxPdfDocSize = 3L * 1024 * 1024 // 3MB
                    val maxPdfSize = 100L * 1024 * 1024 // 100MB

                    if (file.length() > maxPdfSize) {
                        return result.error("FILE_TOO_LARGE", "PDF is ${formatSize(file.length())}, max 100MB", null)
                    }

                    // Validate PDF magic bytes (%PDF-) — reject non-PDFs before they
                    // enter conversation context. An invalid document block makes every
                    // subsequent API call fail with 400 and the session becomes unrecoverable.
                    try {
                        val header = ByteArray(5)
                        java.io.FileInputStream(file).use { it.read(header) }
                        if (!String(header, Charsets.US_ASCII).startsWith("%PDF-")) {
                            return result.error("INVALID_PDF",
                                "File is not a valid PDF (missing %PDF- header): ${file.name}", null)
                        }
                    } catch (_: Exception) {
                        // If we can't read the header, let PdfRenderer handle the error
                    }

                    try {
                        // Get page count via PdfRenderer
                        val pfd = android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                        val renderer: android.graphics.pdf.PdfRenderer
                        try {
                            renderer = android.graphics.pdf.PdfRenderer(pfd)
                        } catch (e: SecurityException) {
                            pfd.close()
                            return result.error("PDF_PROTECTED",
                                "PDF is password-protected. Please provide an unprotected version.", null)
                        }
                        val totalPages = renderer.pageCount

                        // Parse page range
                        var startPage = 1
                        var endPage = minOf(totalPages, 20)
                        if (pagesParam != null) {
                            val parts = pagesParam.split("-")
                            startPage = parts[0].trim().toIntOrNull() ?: 1
                            endPage = if (parts.size > 1) {
                                minOf(parts[1].trim().toIntOrNull() ?: totalPages, startPage + 19)
                            } else {
                                startPage
                            }
                        } else if (totalPages > 20) {
                            renderer.close()
                            pfd.close()
                            val response = JSONObject().apply {
                                put("content_type", "pdf_too_large")
                                put("file_name", file.name)
                                put("total_pages", totalPages)
                                put("size_bytes", file.length())
                                put("message", "This PDF has $totalPages pages. Use the pages parameter to specify a range (max 20 per call). Example: pages=\"1-20\"")
                            }
                            result.success(response.toString())
                            return
                        }
                        startPage = startPage.coerceIn(1, totalPages)
                        endPage = endPage.coerceIn(startPage, totalPages)

                        // Path 1: Small PDF, all pages, no range specified — send as document block
                        if (pagesParam == null && file.length() <= maxPdfDocSize && totalPages <= 20) {
                            renderer.close()
                            pfd.close()
                            val bytes = file.readBytes()
                            val base64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                            val response = JSONObject().apply {
                                put("content_type", "pdf_document")
                                put("file_name", file.name)
                                put("base64", base64)
                                put("media_type", "application/pdf")
                                put("total_pages", totalPages)
                                put("size_bytes", file.length())
                            }
                            result.success(response.toString())
                            return
                        }

                        // Path 2: Render pages as JPEG images
                        val pagesArray = JSONArray()
                        for (pageNum in startPage..endPage) {
                            val pageIndex = pageNum - 1
                            if (pageIndex < 0 || pageIndex >= renderer.pageCount) continue

                            renderer.openPage(pageIndex).use { page ->
                                val scale = 100f / 72f // 100 DPI
                                val width = (page.width * scale).toInt()
                                val height = (page.height * scale).toInt()
                                val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
                                bitmap.eraseColor(android.graphics.Color.WHITE)
                                page.render(bitmap, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                                val baos = java.io.ByteArrayOutputStream()
                                bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, baos)
                                bitmap.recycle()

                                pagesArray.put(JSONObject().apply {
                                    put("page_number", pageNum)
                                    put("image_base64", android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP))
                                    put("media_type", "image/jpeg")
                                    put("width", width)
                                    put("height", height)
                                })
                            }
                        }
                        renderer.close()
                        pfd.close()

                        val response = JSONObject().apply {
                            put("content_type", "pdf_pages")
                            put("file_name", file.name)
                            put("pages", pagesArray)
                            put("total_pages", totalPages)
                            put("returned_pages", endPage - startPage + 1)
                            put("size_bytes", file.length())
                        }
                        result.success(response.toString())
                    } catch (e: Exception) {
                        result.error("PDF_READ_ERROR", "Failed to read PDF: ${e.message}", null)
                    }
                }
                mimeType == "application/epub+zip" || path.endsWith(".epub", ignoreCase = true) -> {
                    val requestedEntry = call.argument<String>("entry")?.trim()?.takeIf { it.isNotEmpty() }
                    try {
                        java.util.zip.ZipFile(file).use { zipFile ->
                            val titleMap = buildEpubTitleMap(zipFile)
                            val contentEntries = listEpubContentEntries(zipFile, titleMap)
                            val maxIndexEntries = 200

                            if (requestedEntry == null) {
                                val entries = JSONArray()
                                contentEntries.take(maxIndexEntries).forEachIndexed { index, entryInfo ->
                                    entries.put(JSONObject().apply {
                                        put("chapter", index + 1)
                                        put("entry", entryInfo.entryName)
                                        if (!entryInfo.title.isNullOrBlank()) put("title", entryInfo.title)
                                    })
                                }

                                val response = JSONObject().apply {
                                    put("content_type", "epub_index")
                                    put("file_name", file.name)
                                    put("entries", entries)
                                    put("total_entries", contentEntries.size)
                                    put("returned_entries", entries.length())
                                    put("size_bytes", file.length())
                                    if (contentEntries.size > maxIndexEntries) {
                                        put("truncated", true)
                                    }
                                    put(
                                        "message",
                                        "Use FileContentSearch to find keywords inside this EPUB, then call FileRead again with the entry parameter plus offset/limit to read a specific section."
                                    )
                                }
                                result.success(response.toString())
                                return
                            }

                            val zipEntry = zipFile.getEntry(requestedEntry)
                                ?: return result.error("EPUB_ENTRY_NOT_FOUND", "EPUB entry not found: $requestedEntry", null)
                            if (zipEntry.isDirectory) {
                                return result.error("EPUB_ENTRY_INVALID", "EPUB entry is a directory: $requestedEntry", null)
                            }
                            if (maybeReturnRecentReadStub(result, file, requestedEntry, startLine, limit)) {
                                return
                            }
                            val lines = readEpubEntryLines(zipFile, zipEntry)
                            val contentLines = lines.drop(startLine - 1).take(limit)
                            val content = contentLines.mapIndexed { index, line ->
                                "${startLine + index}\t$line"
                            }.joinToString("\n")
                            val charCount = content.length
                            val estimatedTokens = estimateTextTokens(content)
                            if (charCount > maxEpubOutputChars || estimatedTokens > maxReadOutputTokens) {
                                val suggestedLimit = suggestReadLimit(
                                    totalChars = charCount,
                                    lineCount = contentLines.size,
                                    maxChars = maxEpubOutputChars,
                                    maxTokens = maxReadOutputTokens,
                                    fallbackLimit = minOf(limit, 200),
                                )
                                return result.error(
                                    "CONTENT_TOO_LARGE",
                                    oversizedReadMessage(
                                        label = "EPUB section",
                                        charCount = charCount,
                                        estimatedTokens = estimatedTokens,
                                        maxChars = maxEpubOutputChars,
                                        maxTokens = maxReadOutputTokens,
                                        suggestedLimit = suggestedLimit,
                                    ),
                                    null
                                )
                            }
                            val entryTitle = titleMap[requestedEntry]
                                ?: guessEpubEntryTitle(requestedEntry, lines.firstOrNull())

                            val response = JSONObject().apply {
                                put("content_type", "epub_entry")
                                put("file_name", file.name)
                                put("entry", requestedEntry)
                                if (!entryTitle.isNullOrBlank()) put("title", entryTitle)
                                put("content", content)
                                put("total_lines", lines.size)
                                put("returned_lines", contentLines.size)
                                put("start_line", startLine)
                                put("size_bytes", file.length())
                                if (contentLines.isEmpty() && lines.isNotEmpty() && startLine > lines.size) {
                                    put("warning", "Requested offset starts after the end of this EPUB entry.")
                                }
                            }
                            rememberRecentRead(file, requestedEntry, startLine, limit, "epub_entry")
                            result.success(response.toString())
                        }
                    } catch (e: Exception) {
                        result.error("EPUB_READ_ERROR", "Failed to read EPUB: ${e.message}", null)
                    }
                }
                mimeType == "application/zip" || mimeType == "application/x-zip-compressed"
                    || path.endsWith(".zip", ignoreCase = true)
                    || path.endsWith(".rar", ignoreCase = true)
                    || path.endsWith(".7z", ignoreCase = true) -> {
                    // List archive contents (don't extract)
                    try {
                        val entries = JSONArray()
                        var totalUncompressed = 0L
                        var entryCount = 0

                        if (path.endsWith(".zip", ignoreCase = true) || mimeType.contains("zip")) {
                            java.util.zip.ZipFile(file).use { zipFile ->
                                val zipEntries = zipFile.entries()
                                while (zipEntries.hasMoreElements() && entryCount < 500) {
                                    val entry = zipEntries.nextElement()
                                    entries.put(JSONObject().apply {
                                        put("name", entry.name)
                                        put("size_bytes", entry.size)
                                        put("size_human", if (entry.size >= 0) formatSize(entry.size) else "unknown")
                                        put("compressed_size", entry.compressedSize)
                                        put("is_directory", entry.isDirectory)
                                    })
                                    if (entry.size > 0) totalUncompressed += entry.size
                                    entryCount++
                                }
                            }
                        } else {
                            // For .rar and .7z, just report we can't list contents without extra libs
                            val response = JSONObject().apply {
                                put("content_type", "archive")
                                put("file_name", file.name)
                                put("size_bytes", file.length())
                                put("size_human", formatSize(file.length()))
                                put("message", "RAR/7z archive listing requires additional libraries. Only ZIP archives can be inspected.")
                            }
                            result.success(response.toString())
                            return
                        }

                        val response = JSONObject().apply {
                            put("content_type", "archive")
                            put("file_name", file.name)
                            put("entries", entries)
                            put("total_entries", entryCount)
                            put("total_uncompressed_bytes", totalUncompressed)
                            put("total_uncompressed_human", formatSize(totalUncompressed))
                            put("archive_size_bytes", file.length())
                            put("archive_size_human", formatSize(file.length()))
                            if (entryCount >= 500) put("truncated", true)
                        }
                        result.success(response.toString())
                    } catch (e: Exception) {
                        result.error("ARCHIVE_READ_ERROR", "Failed to read archive: ${e.message}", null)
                    }
                }
                else -> {
                    val response = JSONObject().apply {
                        put("content_type", "unsupported")
                        put("file_name", file.name)
                        put("mime_type", mimeType)
                        put("size_bytes", file.length())
                        put("message", "This file type ($mimeType) cannot be read as text. Use Metadata tool for file information.")
                    }
                    result.success(response.toString())
                }
            }
        } catch (e: Exception) {
            result.error("FILE_READ_ERROR", e.message, null)
        }
    }

    private fun handleFileWrite(call: MethodCall, result: MethodChannel.Result) {
        if (!hasFullStorageAccess()) {
            return result.error(
                "PERMISSION_DENIED",
                "Full storage access not granted. Enable Full Access in Settings to create files in Download/Clawd-Phone/.",
                null
            )
        }
        try {
            val target = resolveWorkspaceTarget(call.argument<String>("relative_path"))
            val content = call.argument<String>("content")
                ?: return result.error("INVALID_INPUT", "content is required.", null)
            val overwrite = call.argument<Boolean>("overwrite") ?: false

            ensureWorkspaceRoot()
            target.file.parentFile?.let { parent ->
                if (!parent.exists() && !parent.mkdirs() && !parent.exists()) {
                    return result.error("WRITE_ERROR", "Failed to create parent directories.", null)
                }
            }

            val fileExists = target.file.exists()
            var action = "created"
            var lineEnding = detectLineEnding(content)
            var includeBom = target.extension == "csv"

            if (fileExists) {
                if (!overwrite) {
                    return result.error(
                        "FILE_ALREADY_EXISTS",
                        "File already exists. Set overwrite=true to replace it after reading the current file first.",
                        null
                    )
                }

                val priorRead = requireFreshWorkspaceRead(target.file, "overwrite")
                action = "overwritten"
                lineEnding = priorRead.lineEnding
                includeBom = priorRead.hadBom || target.extension == "csv"
            }

            val normalizedContent = normalizeLineEndings(content)
            val encoded = encodeWorkspaceText(
                normalizedContent = normalizedContent,
                lineEnding = lineEnding,
                includeBom = includeBom,
            )
            target.file.writeBytes(encoded)

            updateWorkspaceReadState(
                target.file,
                WorkspaceTextSnapshot(
                    normalizedContent = normalizedContent,
                    hadBom = includeBom,
                    lineEnding = lineEnding,
                ),
                isPartial = false,
            )

            result.success(JSONObject().apply {
                put("action", action)
                put("file_name", target.file.name)
                put("relative_path", target.relativePath)
                put("path", target.file.absolutePath)
                put("bytes_written", encoded.size)
            }.toString())
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_INPUT", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("READ_REQUIRED", e.message, null)
        } catch (e: Exception) {
            result.error("WRITE_ERROR", e.message, null)
        }
    }

    private fun handleFileEdit(call: MethodCall, result: MethodChannel.Result) {
        if (!hasFullStorageAccess()) {
            return result.error(
                "PERMISSION_DENIED",
                "Full storage access not granted. Enable Full Access in Settings to edit files in Download/Clawd-Phone/.",
                null
            )
        }
        try {
            val target = resolveWorkspaceTarget(call.argument<String>("relative_path"))
            val oldString = call.argument<String>("old_string")
                ?: return result.error("INVALID_INPUT", "old_string is required.", null)
            val newString = call.argument<String>("new_string")
                ?: return result.error("INVALID_INPUT", "new_string is required.", null)
            val replaceAll = call.argument<Boolean>("replace_all") ?: false

            if (oldString.isEmpty()) {
                return result.error("INVALID_INPUT", "old_string must not be empty.", null)
            }
            if (oldString == newString) {
                return result.error("INVALID_INPUT", "old_string and new_string are identical.", null)
            }
            if (!target.file.exists()) {
                return result.error("FILE_NOT_FOUND", "File not found: ${target.relativePath}", null)
            }

            requireFreshWorkspaceRead(target.file, "edit")
            val snapshot = readWorkspaceTextSnapshot(target.file)
            val matchCount = countOccurrences(snapshot.normalizedContent, oldString)
            if (matchCount == 0) {
                return result.error(
                    "STRING_NOT_FOUND",
                    "old_string was not found in ${target.relativePath}. Do not include FileRead line numbers.",
                    null
                )
            }
            if (matchCount > 1 && !replaceAll) {
                return result.error(
                    "AMBIGUOUS_EDIT",
                    "Found $matchCount matches. Set replace_all=true or provide a more specific old_string.",
                    null
                )
            }

            val updatedContent = if (replaceAll) {
                snapshot.normalizedContent.replace(oldString, newString)
            } else {
                snapshot.normalizedContent.replaceFirst(oldString, newString)
            }
            val encoded = encodeWorkspaceText(
                normalizedContent = updatedContent,
                lineEnding = snapshot.lineEnding,
                includeBom = snapshot.hadBom || target.extension == "csv",
            )
            target.file.writeBytes(encoded)

            updateWorkspaceReadState(
                target.file,
                WorkspaceTextSnapshot(
                    normalizedContent = updatedContent,
                    hadBom = snapshot.hadBom || target.extension == "csv",
                    lineEnding = snapshot.lineEnding,
                ),
                isPartial = false,
            )

            result.success(JSONObject().apply {
                put("action", "edited")
                put("file_name", target.file.name)
                put("relative_path", target.relativePath)
                put("path", target.file.absolutePath)
                put("match_count", matchCount)
                put("replaced_count", if (replaceAll) matchCount else 1)
                put("bytes_written", encoded.size)
            }.toString())
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_INPUT", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("READ_REQUIRED", e.message, null)
        } catch (e: Exception) {
            result.error("EDIT_ERROR", e.message, null)
        }
    }

    private fun handleImageAnalyze(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("MISSING_PATH", "path required", null)
        val maxDim = call.argument<Int>("max_dimension") ?: 1536
        val file = File(path)
        if (!file.exists()) return result.error("FILE_NOT_FOUND", "Not found: $path", null)
        if (file.length() > 10L * 1024 * 1024) return result.error("FILE_TOO_LARGE", "Image exceeds 10MB decode limit", null)

        val original = BitmapFactory.decodeFile(path) ?: return result.error("DECODE_ERROR", "Cannot decode image", null)
        val originalWidth = original.width
        val originalHeight = original.height
        val ratio = minOf(maxDim.toFloat() / originalWidth, maxDim.toFloat() / originalHeight, 1.0f)
        val scaled = if (ratio < 1.0f) {
            Bitmap.createScaledBitmap(original, (originalWidth * ratio).toInt(), (originalHeight * ratio).toInt(), true)
        } else original

        val baos = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 85, baos)
        // If still > 3.75MB raw (5MB base64 API limit), reduce quality
        if (baos.size() > 3_750_000) {
            baos.reset()
            scaled.compress(Bitmap.CompressFormat.JPEG, 50, baos)
        }
        val base64 = android.util.Base64.encodeToString(baos.toByteArray(), android.util.Base64.NO_WRAP)
        if (scaled !== original) scaled.recycle()
        original.recycle()

        result.success(JSONObject().apply {
            put("content_type", "image")
            put("file_name", file.name)
            put("base64", base64)
            put("media_type", "image/jpeg")
            put("original_size_bytes", file.length())
            put("original_dimensions", JSONObject().apply { put("width", originalWidth); put("height", originalHeight) })
            put("display_dimensions", JSONObject().apply { put("width", (originalWidth * ratio).toInt()); put("height", (originalHeight * ratio).toInt()) })
        }.toString())
    }

    private fun handleMetadata(call: MethodCall, result: MethodChannel.Result) {
        try {
            val path = call.argument<String>("path") ?: return result.error("MISSING_PATH", "path required", null)
            val file = File(path)
            if (!file.exists()) return result.error("FILE_NOT_FOUND", "Not found: $path", null)

            val mimeType = guessMimeType(path)
            val response = JSONObject()

            // Basic info (always)
            response.put("basic", JSONObject().apply {
                put("name", file.name)
                put("path", path)
                put("size_bytes", file.length())
                put("size_human", formatSize(file.length()))
                put("mime_type", mimeType)
                put("date_modified", file.lastModified())
                put("is_hidden", file.isHidden)
                put("parent_directory", file.parent)
            })

            // EXIF for images
            if (mimeType.startsWith("image/")) {
                response.put("file_type", "image")
                try {
                    val exif = ExifInterface(path)
                    val imageExif = JSONObject().apply {
                        put("width", exif.getAttributeInt(ExifInterface.TAG_IMAGE_WIDTH, 0))
                        put("height", exif.getAttributeInt(ExifInterface.TAG_IMAGE_LENGTH, 0))
                        put("date_taken", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
                        put("camera_make", exif.getAttribute(ExifInterface.TAG_MAKE))
                        put("camera_model", exif.getAttribute(ExifInterface.TAG_MODEL))
                        put("focal_length", exif.getAttribute(ExifInterface.TAG_FOCAL_LENGTH))
                        put("aperture", exif.getAttribute(ExifInterface.TAG_APERTURE_VALUE))
                        put("iso", exif.getAttribute(ExifInterface.TAG_ISO_SPEED_RATINGS))
                        put("exposure_time", exif.getAttribute(ExifInterface.TAG_EXPOSURE_TIME))
                        put("flash", exif.getAttribute(ExifInterface.TAG_FLASH))
                        put("software", exif.getAttribute(ExifInterface.TAG_SOFTWARE))
                    }
                    val latLong = FloatArray(2)
                    if (exif.getLatLong(latLong)) {
                        imageExif.put("gps_latitude", latLong[0].toDouble())
                        imageExif.put("gps_longitude", latLong[1].toDouble())
                    }
                    response.put("image_exif", imageExif)
                } catch (_: Exception) {}
            } else if (mimeType.startsWith("video/") || mimeType.startsWith("audio/")) {
                response.put("file_type", if (mimeType.startsWith("video/")) "video" else "audio")
                try {
                    val retriever = android.media.MediaMetadataRetriever()
                    retriever.setDataSource(path)
                    val mediaInfo = JSONObject().apply {
                        put("duration_ms", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull())
                        put("title", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_TITLE))
                        put("artist", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_ARTIST))
                        put("album", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_ALBUM))
                        if (mimeType.startsWith("video/")) {
                            put("width", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull())
                            put("height", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull())
                            put("bitrate", retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull())
                        }
                    }
                    response.put(if (mimeType.startsWith("video/")) "video_info" else "audio_info", mediaInfo)
                    retriever.release()
                } catch (_: Exception) {}
            } else {
                response.put("file_type", "generic")
            }

            result.success(response.toString())
        } catch (e: Exception) {
            result.error("METADATA_ERROR", e.message, null)
        }
    }

    private fun handleStorageStats(call: MethodCall, result: MethodChannel.Result) {
        if (!hasMediaPermission()) {
            return result.error("PERMISSION_DENIED", "Media permission not granted. Please grant storage/media permissions in Settings.", null)
        }
        try {
            val breakdown = call.argument<String>("breakdown") ?: "overview"
            val topN = call.argument<Int>("top_n") ?: 20

            val stat = StatFs(Environment.getExternalStorageDirectory().path)
            val total = stat.totalBytes
            val free = stat.freeBytes
            val used = total - free

            val response = JSONObject().apply {
                put("device_storage", JSONObject().apply {
                    put("total_bytes", total)
                    put("total_human", formatSize(total))
                    put("used_bytes", used)
                    put("used_human", formatSize(used))
                    put("free_bytes", free)
                    put("free_human", formatSize(free))
                    put("used_percent", (used.toDouble() / total * 100).toInt())
                })
            }

            if (breakdown == "overview" || breakdown == "type") {
                // Type breakdown via MediaStore aggregation
                val types = JSONArray()
                for ((label, mime) in listOf(
                    "images" to "image/%",
                    "videos" to "video/%",
                    "audio" to "audio/%",
                    "documents" to "application/%"
                )) {
                    // ContentResolver.query doesn't support SQL aggregates (SUM/COUNT).
                    // Compute manually by iterating rows.
                    val cursor = contentResolver.query(
                        MediaStore.Files.getContentUri("external"),
                        arrayOf(MediaStore.Files.FileColumns.SIZE),
                        "${MediaStore.Files.FileColumns.MIME_TYPE} LIKE ?",
                        arrayOf(mime),
                        null
                    )
                    var totalSize = 0L
                    var count = 0
                    cursor?.use { c ->
                        while (c.moveToNext()) {
                            totalSize += c.getLong(0)
                            count++
                        }
                    }
                    types.put(JSONObject().apply {
                        put("category", label)
                        put("count", count)
                        put("total_bytes", totalSize)
                        put("total_human", formatSize(totalSize))
                    })
                }
                // Fallback: if MediaStore returned all zeros, scan filesystem directly.
                val totalMediaStoreCount = (0 until types.length()).sumOf { types.getJSONObject(it).getInt("count") }
                if (totalMediaStoreCount == 0) {
                    val root = File("/storage/emulated/0")
                    val fsCounts = mutableMapOf(
                        "images" to Pair(0, 0L),
                        "videos" to Pair(0, 0L),
                        "audio" to Pair(0, 0L),
                        "documents" to Pair(0, 0L)
                    )
                    _countFilesByType(root, fsCounts, maxDepth = 5, currentDepth = 0)
                    val fsTypes = JSONArray()
                    for ((label, pair) in fsCounts) {
                        fsTypes.put(JSONObject().apply {
                            put("category", label)
                            put("count", pair.first)
                            put("total_bytes", pair.second)
                            put("total_human", formatSize(pair.second))
                            put("source", "filesystem")
                        })
                    }
                    response.put("by_type", fsTypes)
                } else {
                    response.put("by_type", types)
                }
            }

            // top_n: return the N largest files on the device
            if (topN > 0) {
                val topFiles = JSONArray()
                val cursor = contentResolver.query(
                    MediaStore.Files.getContentUri("external"),
                    arrayOf(
                        MediaStore.Files.FileColumns.DISPLAY_NAME,
                        pathColumn,
                        MediaStore.Files.FileColumns.SIZE,
                        MediaStore.Files.FileColumns.MIME_TYPE
                    ),
                    "${MediaStore.Files.FileColumns.SIZE} > 0",
                    null,
                    "${MediaStore.Files.FileColumns.SIZE} DESC"
                )
                cursor?.use { c ->
                    while (c.moveToNext() && topFiles.length() < topN) {
                        val name = c.getStringOrNull(MediaStore.Files.FileColumns.DISPLAY_NAME) ?: ""
                        val relPath = c.getStringOrNull(pathColumn) ?: ""
                        val size = c.getLongOrNull(MediaStore.Files.FileColumns.SIZE) ?: 0L
                        topFiles.put(JSONObject().apply {
                            put("name", name)
                            put("path", "/storage/emulated/0/$relPath$name")
                            put("size_bytes", size)
                            put("size_human", formatSize(size))
                            put("mime_type", c.getStringOrNull(MediaStore.Files.FileColumns.MIME_TYPE))
                        })
                    }
                }
                // Filesystem fallback for top_files if MediaStore is empty
                if (topFiles.length() == 0) {
                    val allFiles = mutableListOf<File>()
                    _collectAllFiles(File("/storage/emulated/0"), allFiles, maxDepth = 5, currentDepth = 0)
                    allFiles.sortByDescending { it.length() }
                    for (f in allFiles.take(topN)) {
                        val relPath = f.parent?.removePrefix("/storage/emulated/0/")?.plus("/") ?: ""
                        topFiles.put(JSONObject().apply {
                            put("name", f.name)
                            put("path", f.absolutePath)
                            put("size_bytes", f.length())
                            put("size_human", formatSize(f.length()))
                            put("mime_type", guessMimeType(f.name))
                            put("source", "filesystem")
                        })
                    }
                }
                response.put("top_files", topFiles)
            }

            result.success(response.toString())
        } catch (e: Exception) {
            result.error("STORAGE_ERROR", e.message, null)
        }
    }

    private fun handleDirectoryList(call: MethodCall, result: MethodChannel.Result) {
        try {
            val path = call.argument<String>("path") ?: "/storage/emulated/0"
            val showHidden = call.argument<Boolean>("show_hidden") ?: false
            val limit = call.argument<Int>("limit") ?: 100
            val recursive = call.argument<Boolean>("recursive") ?: false
            val maxDepth = call.argument<Int>("max_depth") ?: 3
            val sortBy = call.argument<String>("sort_by") ?: "name"
            val dir = File(path)

            if (!dir.exists() || !dir.isDirectory) {
                return result.error("NOT_DIRECTORY", "$path is not a directory", null)
            }

            val collected = mutableListOf<File>()
            if (recursive) {
                collectFilesRecursive(dir, collected, showHidden, maxDepth, 0)
            } else {
                dir.listFiles()?.filter { showHidden || !it.isHidden }?.let { collected.addAll(it) }
            }

            val sorted = when (sortBy) {
                "size" -> collected.sortedByDescending { if (it.isFile) it.length() else 0L }
                "date", "date_modified" -> collected.sortedByDescending { it.lastModified() }
                else -> collected.sortedBy { it.name.lowercase() }
            }

            val entries = JSONArray()
            for (f in sorted.take(limit)) {
                entries.put(JSONObject().apply {
                    put("name", f.name)
                    put("path", f.absolutePath)
                    put("type", if (f.isDirectory) "directory" else "file")
                    put("size_bytes", if (f.isFile) f.length() else 0)
                    put("size_human", if (f.isFile) formatSize(f.length()) else "")
                    put("date_modified", f.lastModified())
                    if (f.isDirectory) {
                        put("child_count", f.listFiles()?.size ?: 0)
                    }
                })
            }

            val response = JSONObject().apply {
                put("path", path)
                put("entries", entries)
                put("total_entries", entries.length())
                put("recursive", recursive)
                if (recursive) put("max_depth", maxDepth)
                put("sort_by", sortBy)
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("DIR_LIST_ERROR", e.message, null)
        }
    }

    private fun collectFilesRecursive(dir: File, out: MutableList<File>, showHidden: Boolean, maxDepth: Int, currentDepth: Int) {
        if (currentDepth > maxDepth) return
        val children = dir.listFiles()?.filter { showHidden || !it.isHidden } ?: return
        for (child in children) {
            out.add(child)
            if (child.isDirectory && currentDepth < maxDepth) {
                collectFilesRecursive(child, out, showHidden, maxDepth, currentDepth + 1)
            }
        }
    }

    private fun handleLargeFiles(call: MethodCall, result: MethodChannel.Result) {
        if (!hasMediaPermission()) {
            return result.error("PERMISSION_DENIED", "Media permission not granted. Please grant storage/media permissions in Settings.", null)
        }
        try {
            val minSize = (call.argument<Number>("min_size_bytes") ?: 10_485_760L).toLong() // 10MB
            val limit = call.argument<Int>("limit") ?: 25

            val cursor = contentResolver.query(
                MediaStore.Files.getContentUri("external"),
                arrayOf(
                    MediaStore.Files.FileColumns.DISPLAY_NAME,
                    pathColumn,
                    MediaStore.Files.FileColumns.SIZE,
                    MediaStore.Files.FileColumns.MIME_TYPE,
                    MediaStore.Files.FileColumns.DATE_MODIFIED
                ),
                "${MediaStore.Files.FileColumns.SIZE} > ?",
                arrayOf(minSize.toString()),
                "${MediaStore.Files.FileColumns.SIZE} DESC"
            )

            val files = JSONArray()
            cursor?.use { c ->
                while (c.moveToNext() && files.length() < limit) {
                    val name = c.getStringOrNull(MediaStore.Files.FileColumns.DISPLAY_NAME) ?: ""
                    val (relPath, fullPath) = getPathsFromCursor(c, name)
                    val size = c.getLongOrNull(MediaStore.Files.FileColumns.SIZE) ?: 0L
                    files.put(JSONObject().apply {
                        put("name", name)
                        put("path", fullPath)
                        put("size_bytes", size)
                        put("size_human", formatSize(size))
                        put("mime_type", c.getStringOrNull(MediaStore.Files.FileColumns.MIME_TYPE))
                        put("date_modified", c.getLongOrNull(MediaStore.Files.FileColumns.DATE_MODIFIED))
                    })
                }
            }

            result.success(JSONObject().apply {
                put("files", files)
                put("total_found", files.length())
            }.toString())
        } catch (e: Exception) {
            result.error("LARGE_FILES_ERROR", e.message, null)
        }
    }

    private fun handleRecentActivity(call: MethodCall, result: MethodChannel.Result) {
        if (!hasMediaPermission()) {
            return result.error("PERMISSION_DENIED", "Media permission not granted. Please grant storage/media permissions in Settings.", null)
        }
        try {
            val hoursBack = call.argument<Int>("hours_back") ?: 24
            val limit = call.argument<Int>("limit") ?: 30
            val action = call.argument<String>("action") ?: "all"
            val mimeFilter = call.argument<String>("mime_filter")
            val cutoff = System.currentTimeMillis() / 1000 - (hoursBack * 3600)

            // Build selection based on action param
            val selection = StringBuilder()
            val selectionArgs = mutableListOf<String>()

            when (action) {
                "modified" -> {
                    selection.append("${MediaStore.Files.FileColumns.DATE_MODIFIED} > ?")
                    selectionArgs.add(cutoff.toString())
                }
                "added" -> {
                    selection.append("${MediaStore.Files.FileColumns.DATE_ADDED} > ?")
                    selectionArgs.add(cutoff.toString())
                }
                else -> {
                    // "all": files that were either added or modified within the window
                    selection.append("(${MediaStore.Files.FileColumns.DATE_ADDED} > ? OR ${MediaStore.Files.FileColumns.DATE_MODIFIED} > ?)")
                    selectionArgs.add(cutoff.toString())
                    selectionArgs.add(cutoff.toString())
                }
            }

            // Apply MIME type filter if provided
            if (!mimeFilter.isNullOrEmpty()) {
                selection.append(" AND ")
                if (mimeFilter.endsWith("/*")) {
                    selection.append("${MediaStore.Files.FileColumns.MIME_TYPE} LIKE ?")
                    selectionArgs.add(mimeFilter.replace("/*", "/%"))
                } else {
                    selection.append("${MediaStore.Files.FileColumns.MIME_TYPE} = ?")
                    selectionArgs.add(mimeFilter)
                }
            }

            // Sort column matches the action
            val sortColumn = when (action) {
                "modified" -> MediaStore.Files.FileColumns.DATE_MODIFIED
                "added" -> MediaStore.Files.FileColumns.DATE_ADDED
                else -> MediaStore.Files.FileColumns.DATE_MODIFIED
            }

            val cursor = contentResolver.query(
                MediaStore.Files.getContentUri("external"),
                arrayOf(
                    MediaStore.Files.FileColumns.DISPLAY_NAME,
                    pathColumn,
                    MediaStore.Files.FileColumns.SIZE,
                    MediaStore.Files.FileColumns.MIME_TYPE,
                    MediaStore.Files.FileColumns.DATE_MODIFIED,
                    MediaStore.Files.FileColumns.DATE_ADDED
                ),
                selection.toString(),
                selectionArgs.toTypedArray(),
                "$sortColumn DESC"
            )

            val activities = JSONArray()
            cursor?.use { c ->
                while (c.moveToNext() && activities.length() < limit) {
                    val name = c.getStringOrNull(MediaStore.Files.FileColumns.DISPLAY_NAME) ?: ""
                    val (relPath, fullPath) = getPathsFromCursor(c, name)
                    val size = c.getLongOrNull(MediaStore.Files.FileColumns.SIZE) ?: 0L
                    activities.put(JSONObject().apply {
                        put("name", name)
                        put("path", fullPath)
                        put("size_bytes", size)
                        put("size_human", formatSize(size))
                        put("mime_type", c.getStringOrNull(MediaStore.Files.FileColumns.MIME_TYPE))
                        put("date_modified", c.getLongOrNull(MediaStore.Files.FileColumns.DATE_MODIFIED))
                        put("date_added", c.getLongOrNull(MediaStore.Files.FileColumns.DATE_ADDED))
                    })
                }
            }

            result.success(JSONObject().apply {
                put("activities", activities)
                put("total_activities", activities.length())
            }.toString())
        } catch (e: Exception) {
            result.error("RECENT_ERROR", e.message, null)
        }
    }

    // --- FileContentSearch (grep-like search inside files) ---

    private fun handleFileContentSearch(call: MethodCall, result: MethodChannel.Result) {
        if (!hasMediaPermission()) {
            return result.error("PERMISSION_DENIED", "Media permission not granted.", null)
        }
        try {
            val pattern = call.argument<String>("pattern")
                ?: return result.error("INVALID_INPUT", "pattern is required", null)
            val searchPath = call.argument<String>("path") ?: "/storage/emulated/0"
            val filePattern = call.argument<String>("file_pattern") // e.g. "*.txt"
            val caseSensitive = call.argument<Boolean>("case_sensitive") ?: false
            val limit = (call.argument<Int>("limit") ?: 20).coerceIn(1, 100)
            val offset = (call.argument<Int>("offset") ?: 0).coerceAtLeast(0)

            val regex = try {
                if (caseSensitive) Regex(pattern)
                else Regex(pattern, RegexOption.IGNORE_CASE)
            } catch (_: Exception) {
                // If not valid regex, treat as literal
                if (caseSensitive) Regex(Regex.escape(pattern))
                else Regex(Regex.escape(pattern), RegexOption.IGNORE_CASE)
            }

            // Convert glob file_pattern to regex for matching filenames
            val fileRegex = filePattern?.let {
                val escaped = it.replace(".", "\\.").replace("*", ".*").replace("?", ".")
                Regex(escaped, RegexOption.IGNORE_CASE)
            }

            val matchResults = mutableListOf<JSONObject>()
            val root = File(searchPath)
            val maxDepth = 5

            fun buildMatchingLines(lines: List<String>): List<JSONObject> {
                val matchingLines = mutableListOf<JSONObject>()
                for ((index, line) in lines.withIndex()) {
                    if (regex.containsMatchIn(line)) {
                        matchingLines.add(JSONObject().apply {
                            put("line_number", index + 1)
                            put("text", if (line.length > 200) line.substring(0, 200) + "..." else line)
                        })
                        if (matchingLines.size >= 5) break
                    }
                }
                return matchingLines
            }

            fun searchFile(file: File) {
                if (fileRegex != null && !fileRegex.matches(file.name)) return
                try {
                    when {
                        isEpubFile(file.path) -> {
                            java.util.zip.ZipFile(file).use { zipFile ->
                                val titleMap = buildEpubTitleMap(zipFile)
                                listEpubContentEntries(zipFile, titleMap).forEach { entryInfo ->
                                    val zipEntry = zipFile.getEntry(entryInfo.entryName) ?: return@forEach
                                    val matchingLines = buildMatchingLines(readEpubEntryLines(zipFile, zipEntry))
                                    if (matchingLines.isNotEmpty()) {
                                        matchResults.add(JSONObject().apply {
                                            put("file", file.absolutePath)
                                            put("entry", entryInfo.entryName)
                                            if (!entryInfo.title.isNullOrBlank()) put("title", entryInfo.title)
                                            put("size_bytes", file.length())
                                            put("matching_lines", JSONArray(matchingLines))
                                            put("match_count", matchingLines.size)
                                        })
                                    }
                                }
                            }
                        }
                        isTextFile(file.path) -> {
                            // Skip files > 5MB
                            if (file.length() > 5 * 1024 * 1024) return
                            val matchingLines = mutableListOf<JSONObject>()
                            file.bufferedReader().useLines { lines ->
                                var lineNum = 0
                                for (line in lines) {
                                    lineNum++
                                    if (regex.containsMatchIn(line)) {
                                        matchingLines.add(JSONObject().apply {
                                            put("line_number", lineNum)
                                            put("text", if (line.length > 200) line.substring(0, 200) + "..." else line)
                                        })
                                        if (matchingLines.size >= 5) break
                                    }
                                }
                            }
                            if (matchingLines.isNotEmpty()) {
                                matchResults.add(JSONObject().apply {
                                    put("file", file.absolutePath)
                                    put("size_bytes", file.length())
                                    put("matching_lines", JSONArray(matchingLines))
                                    put("match_count", matchingLines.size)
                                })
                            }
                        }
                    }
                } catch (_: Exception) {
                    // Skip unreadable files
                }
            }

            fun searchDir(dir: File, depth: Int) {
                if (depth > maxDepth) return
                val files = dir.listFiles() ?: return
                for (file in files) {
                    if (file.isDirectory) {
                        if (file.name.startsWith(".")) continue
                        searchDir(file, depth + 1)
                    } else if (file.isFile) {
                        searchFile(file)
                    }
                }
            }

            when {
                root.isFile -> searchFile(root)
                root.isDirectory -> searchDir(root, 0)
            }

            val sortedMatches = matchResults.sortedWith(
                compareBy<JSONObject> { it.optString("file") }.thenBy { it.optString("entry") }
            )
            val pagedMatches = JSONArray()
            sortedMatches.drop(offset).take(limit).forEach { pagedMatches.put(it) }
            val totalMatches = sortedMatches.size
            val returned = pagedMatches.length()
            val nextOffset = (offset + returned).takeIf { it < totalMatches }
            val hasMore = nextOffset != null

            result.success(JSONObject().apply {
                put("matches", pagedMatches)
                put("total_files_matched", totalMatches)
                put("total_matches", totalMatches)
                put("returned", returned)
                put("offset", offset)
                put("has_more", hasMore)
                if (nextOffset != null) put("next_offset", nextOffset)
                put("pattern", pattern)
                put("search_path", searchPath)
            }.toString())
        } catch (e: Exception) {
            result.error("SEARCH_ERROR", e.message, null)
        }
    }

    // --- Helpers ---

    /** Column for file path: RELATIVE_PATH on Android 10+, DATA on older */
    private val pathColumn: String
        get() = if (Build.VERSION.SDK_INT >= 29)
            MediaStore.Files.FileColumns.RELATIVE_PATH
        else
            @Suppress("DEPRECATION") MediaStore.Files.FileColumns.DATA

    /** Extract relative path and full path from cursor row */
    private fun getPathsFromCursor(cursor: Cursor, name: String): Pair<String, String> {
        val raw = cursor.getStringOrNull(pathColumn) ?: ""
        return if (Build.VERSION.SDK_INT >= 29) {
            // raw is relative path like "Download/"
            Pair(raw, "/storage/emulated/0/$raw$name")
        } else {
            // raw is full path like "/storage/emulated/0/Download/file.pdf"
            Pair(raw.removePrefix("/storage/emulated/0/").removeSuffix(name), raw)
        }
    }

    private fun hasMediaPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) {
            return true
        }

        return if (Build.VERSION.SDK_INT >= 33) {
            // Android 13+ uses granular media permissions
            ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_MEDIA_AUDIO) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun hasFullStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        // On Android <= 10, READ_EXTERNAL_STORAGE gives full access
        return ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    private fun isEpubFile(path: String): Boolean {
        return path.endsWith(".epub", ignoreCase = true) || guessMimeType(path) == "application/epub+zip"
    }

    private fun isEpubContentEntry(name: String): Boolean {
        val lower = name.lowercase()
        return (lower.endsWith(".xhtml") || lower.endsWith(".html") || lower.endsWith(".htm")) &&
            !isEpubStructureEntry(name)
    }

    private fun isEpubStructureEntry(name: String): Boolean {
        val lower = name.lowercase()
        return lower.contains("toc") || lower.contains("nav")
    }

    private fun listEpubContentEntries(
        zipFile: java.util.zip.ZipFile,
        titleMap: Map<String, String>,
    ): List<EpubContentEntry> {
        val entries = mutableListOf<EpubContentEntry>()
        val enumeration = zipFile.entries()
        while (enumeration.hasMoreElements()) {
            val entry = enumeration.nextElement()
            if (entry.isDirectory || !isEpubContentEntry(entry.name)) continue
            entries.add(
                EpubContentEntry(
                    entryName = entry.name,
                    title = titleMap[entry.name] ?: guessEpubEntryTitle(entry.name, null),
                )
            )
        }
        return entries
    }

    private fun buildEpubTitleMap(zipFile: java.util.zip.ZipFile): Map<String, String> {
        val titles = linkedMapOf<String, String>()
        val navAnchorRegex = Regex(
            """(?is)<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"""
        )
        val ncxNavRegex = Regex(
            """(?is)<navPoint\b.*?<navLabel>\s*<text>(.*?)</text>\s*</navLabel>.*?<content\b[^>]*src\s*=\s*["']([^"']+)["'][^>]*/?>"""
        )

        val enumeration = zipFile.entries()
        while (enumeration.hasMoreElements()) {
            val entry = enumeration.nextElement()
            if (entry.isDirectory || !isEpubStructureEntry(entry.name)) continue
            val raw = readZipEntryText(zipFile, entry)
            for (match in navAnchorRegex.findAll(raw)) {
                val href = resolveEpubEntryPath(entry.name, match.groupValues[1])
                val title = normalizeEpubInlineText(match.groupValues[2])
                if (href.isNotBlank() && title.isNotBlank()) {
                    titles.putIfAbsent(href, title)
                }
            }
            for (match in ncxNavRegex.findAll(raw)) {
                val title = normalizeEpubInlineText(match.groupValues[1])
                val href = resolveEpubEntryPath(entry.name, match.groupValues[2])
                if (href.isNotBlank() && title.isNotBlank()) {
                    titles.putIfAbsent(href, title)
                }
            }
        }
        return titles
    }

    private fun readEpubEntryLines(
        zipFile: java.util.zip.ZipFile,
        entry: java.util.zip.ZipEntry,
    ): List<String> {
        val raw = readZipEntryText(zipFile, entry)
        return normalizeEpubHtmlToLines(raw)
    }

    private fun readZipEntryText(
        zipFile: java.util.zip.ZipFile,
        entry: java.util.zip.ZipEntry,
    ): String {
        return zipFile.getInputStream(entry).bufferedReader().use { it.readText() }
    }

    private fun normalizeEpubHtmlToLines(raw: String): List<String> {
        val withBreaks = raw
            .replace(Regex("(?is)<style[^>]*>.*?</style>"), " ")
            .replace(Regex("(?is)<script[^>]*>.*?</script>"), " ")
            .replace(Regex("(?is)<head[^>]*>.*?</head>"), " ")
            .replace(Regex("(?i)<\\s*hr\\s*/?>"), "\n")
            .replace(Regex("(?i)<\\s*br\\s*/?>"), "\n")
            .replace(Regex("(?i)</\\s*(p|div|h1|h2|h3|h4|h5|h6|li|section|article|blockquote|tr|ul|ol|dl|dt|dd|table|thead|tbody|tfoot|caption|figcaption)\\s*>"), "\n")
            .replace(Regex("(?i)<\\s*(p|div|h1|h2|h3|h4|h5|h6|li|section|article|blockquote|tr|ul|ol|dl|dt|dd|table|thead|tbody|tfoot|caption|figcaption)[^>]*>"), "\n")
            .replace(Regex("(?i)</\\s*(td|th)\\s*>"), " ")
            .replace(Regex("(?i)<\\s*(td|th)[^>]*>"), " ")

        val plain = android.text.Html
            .fromHtml(withBreaks, android.text.Html.FROM_HTML_MODE_LEGACY)
            .toString()
            .replace('\u00A0', ' ')

        return plain
            .lines()
            .map { it.replace(Regex("\\s+"), " ").trim() }
            .filter { it.isNotEmpty() }
            .flatMap { splitEpubSyntheticLine(it, maxEpubSyntheticLineLength) }
            .map { truncateReadLine(it, maxEpubLineLength) }
            .filter { it.isNotEmpty() }
    }

    private fun splitEpubSyntheticLine(line: String, maxChars: Int): List<String> {
        val normalized = line.replace(Regex("\\s+"), " ").trim()
        if (normalized.isEmpty()) return emptyList()
        if (normalized.length <= maxChars) return listOf(normalized)

        val parts = mutableListOf<String>()
        var remaining = normalized
        while (remaining.length > maxChars) {
            val window = remaining.substring(0, maxChars)
            var breakAt = maxOf(
                window.lastIndexOf(". "),
                window.lastIndexOf("! "),
                window.lastIndexOf("? "),
                window.lastIndexOf("; "),
                window.lastIndexOf(": "),
                window.lastIndexOf(", "),
                window.lastIndexOf(" "),
            )

            if (breakAt < maxChars / 2) {
                breakAt = maxChars
            } else if (breakAt < window.length && window[breakAt].isWhitespace()) {
                breakAt += 1
            }

            val chunk = remaining.substring(0, breakAt).trim()
            if (chunk.isNotEmpty()) {
                parts.add(chunk)
            }
            remaining = remaining.substring(breakAt).trimStart()
        }
        if (remaining.isNotBlank()) {
            parts.add(remaining)
        }
        return parts
    }

    private fun normalizeEpubInlineText(raw: String): String {
        return android.text.Html
            .fromHtml(raw, android.text.Html.FROM_HTML_MODE_LEGACY)
            .toString()
            .replace('\u00A0', ' ')
            .replace(Regex("\\s+"), " ")
            .trim()
    }

    private fun resolveEpubEntryPath(baseEntryName: String, href: String): String {
        val cleanHref = android.net.Uri.decode(href.substringBefore("#").trim())
        if (cleanHref.isEmpty()) return ""

        val baseDir = baseEntryName.substringBeforeLast('/', "")
        val combined = if (cleanHref.startsWith("/")) {
            cleanHref.removePrefix("/")
        } else if (baseDir.isEmpty()) {
            cleanHref
        } else {
            "$baseDir/$cleanHref"
        }

        val normalized = mutableListOf<String>()
        combined.split('/').forEach { segment ->
            when {
                segment.isEmpty() || segment == "." -> Unit
                segment == ".." -> if (normalized.isNotEmpty()) normalized.removeAt(normalized.lastIndex)
                else -> normalized.add(segment)
            }
        }
        return normalized.joinToString("/")
    }

    private fun guessEpubEntryTitle(entryName: String, firstLine: String?): String {
        if (!firstLine.isNullOrBlank()) {
            return firstLine.take(80)
        }

        val fileName = entryName.substringAfterLast('/')
        return fileName.substringBeforeLast('.').replace('_', ' ').replace('-', ' ')
    }

    private fun isTextFile(path: String): Boolean {
        val ext = path.substringAfterLast('.', "").lowercase()
        return ext in setOf(
            "txt", "csv", "json", "xml", "md", "log", "yaml", "yml",
            "ini", "conf", "sh", "py", "js", "java", "kt", "html",
            "css", "sql", "env", "properties", "gradle", "toml",
            "rst", "tex", "rtf", "cfg", "tsv", "dart", "swift",
            "rb", "go", "rs", "c", "cpp", "h", "hpp", "r", "m",
            "php", "pl", "lua", "vim", "bat", "ps1", "dockerfile",
            "makefile", "gitignore", "editorconfig"
        )
    }

    /** Guess MIME type using Android's MimeTypeMap (much more complete than
     *  URLConnection.guessContentTypeFromName which misses html, json, csv, etc). */
    private fun guessMimeType(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: java.net.URLConnection.guessContentTypeFromName(path)
            ?: when (ext) {
                // Common types MimeTypeMap may still miss
                "md", "markdown" -> "text/markdown"
                "yaml", "yml" -> "text/yaml"
                "toml" -> "text/toml"
                "csv" -> "text/csv"
                "log" -> "text/plain"
                "sh", "bash", "zsh" -> "text/x-shellscript"
                "kt", "kts" -> "text/x-kotlin"
                "dart" -> "text/x-dart"
                "rs" -> "text/x-rust"
                "go" -> "text/x-go"
                "swift" -> "text/x-swift"
                "ts", "tsx" -> "text/typescript"
                "jsx" -> "text/javascript"
                "vue", "svelte" -> "text/html"
                "sql" -> "text/x-sql"
                "env" -> "text/plain"
                "epub" -> "application/epub+zip"
                else -> ""
            }
    }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1_073_741_824 -> "%.1f GB".format(bytes / 1_073_741_824.0)
        bytes >= 1_048_576 -> "%.1f MB".format(bytes / 1_048_576.0)
        bytes >= 1024 -> "%.1f KB".format(bytes / 1024.0)
        else -> "$bytes B"
    }

    /**
     * Parse a date string to epoch seconds. Accepts plain dates like "2025-07-01"
     * (via LocalDate) as well as full ISO 8601 timestamps like "2025-07-01T00:00:00Z"
     * (via Instant). Returns null if neither format matches.
     */
    private fun parseToEpochSeconds(dateStr: String): Long? {
        return try {
            java.time.LocalDate.parse(dateStr).atStartOfDay(java.time.ZoneId.systemDefault()).toEpochSecond()
        } catch (_: Exception) {
            try {
                java.time.Instant.parse(dateStr).epochSecond
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun buildSearchSpec(query: String?): SearchSpec {
        val raw = query?.trim().orEmpty()
        if (raw.isEmpty()) {
            return SearchSpec(globRegex = null, extensions = emptySet(), terms = emptyList())
        }

        val normalized = raw.lowercase()
        val hasWildcards = raw.contains('*') || raw.contains('?')
        val extensions = linkedSetOf<String>()

        Regex("""(?:^|[\s"'`(])\.([a-z0-9]{1,10})(?=$|[\s"'`),])""")
            .findAll(normalized)
            .forEach { match -> extensions.add(match.groupValues[1]) }

        if (Regex("""(^|[^a-z0-9])pdf([^a-z0-9]|$)""").containsMatchIn(normalized)) {
            extensions.add("pdf")
        }
        if (
            Regex("""(^|[^a-z0-9])md([^a-z0-9]|$)""").containsMatchIn(normalized) ||
            normalized.contains("markdown")
        ) {
            extensions.add("md")
            extensions.add("markdown")
        }

        val ignoredTerms = setOf(
            "a", "an", "any", "are", "browser", "browsers", "chrome", "device",
            "document", "documents", "download", "downloaded", "downloads", "file", "files",
            "find", "for", "from", "in", "is", "look", "markdown", "md", "my", "of",
            "on", "our", "pdf", "phone", "search", "there", "with"
        ) + extensions

        val terms = Regex("""[a-z0-9]+""")
            .findAll(normalized)
            .map { it.value }
            .filter { token -> token.length >= 2 && token !in ignoredTerms }
            .toList()

        return SearchSpec(
            globRegex = if (hasWildcards) globPatternToRegex(raw) else null,
            extensions = extensions,
            terms = terms
        )
    }

    private fun globPatternToRegex(pattern: String): Regex {
        val regex = buildString {
            append("^")
            for (char in pattern) {
                when (char) {
                    '*' -> append(".*")
                    '?' -> append(".")
                    else -> append(Regex.escape(char.toString()))
                }
            }
            append("$")
        }
        return Regex(regex, RegexOption.IGNORE_CASE)
    }

    private fun matchesSearchSpec(name: String, relativePath: String, spec: SearchSpec): Boolean {
        val lowerName = name.lowercase()
        val lowerPath = relativePath.lowercase()
        if (spec.globRegex != null && !spec.globRegex.matches(name)) return false

        val ext = name.substringAfterLast('.', "").lowercase()
        if (spec.extensions.isNotEmpty() && ext !in spec.extensions) return false

        if (spec.terms.isNotEmpty()) {
            val haystack = "$lowerName $lowerPath"
            if (!spec.terms.all { term -> haystack.contains(term) }) return false
        }

        return true
    }

    private fun getSearchRoots(directory: String?): List<File> {
        val explicit = directory?.trim()?.trim('/').orEmpty()
        if (explicit.isNotEmpty()) {
            return listOf(File("/storage/emulated/0/$explicit"))
        }

        val roots = mutableListOf(
            File("/storage/emulated/0/Download"),
            File("/storage/emulated/0/Documents"),
            File("/storage/emulated/0/Pictures"),
            File("/storage/emulated/0/DCIM"),
            File("/storage/emulated/0/Movies"),
            File("/storage/emulated/0/Music"),
        )

        // Include app media directories (WhatsApp, KakaoTalk, Telegram, etc.)
        // so the agent can discover images/files from messaging apps.
        val androidMedia = File("/storage/emulated/0/Android/media")
        if (androidMedia.exists() && androidMedia.isDirectory) {
            androidMedia.listFiles()?.forEach { appDir ->
                if (appDir.isDirectory) roots.add(appDir)
            }
        }

        return roots.filter { it.exists() && it.isDirectory }
    }

    private fun addSearchResult(
        out: MutableMap<String, JSONObject>,
        file: JSONObject
    ) {
        val path = file.optString("path")
        if (path.isBlank()) return
        out.putIfAbsent(path, file)
    }

    private fun Cursor.getStringOrNull(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { getString(it) }

    private fun Cursor.getLongOrNull(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { getLong(it) }
}
