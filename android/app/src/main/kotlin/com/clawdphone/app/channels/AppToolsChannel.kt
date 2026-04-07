package com.clawdphone.app.channels

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Handles app-inspection tools.
 *
 * AppDetail is intentionally narrower than the original declared spec:
 * list, search, detail, and last_used are implemented; storage-oriented
 * actions return explicit unsupported responses.
 */
class AppToolsChannel(
    private val activity: Activity
) {
    private val packageManager: PackageManager
        get() = activity.packageManager

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "AppDetail" -> handleAppDetail(call, result)
            "UsageStats" -> handleUsageStats(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleAppDetail(call: MethodCall, result: MethodChannel.Result) {
        try {
            val action = call.argument<String>("action") ?: "search"
            val response = when (action) {
                "list" -> listApps(call)
                "search" -> searchApps(call)
                "detail" -> appDetail(call)
                "last_used" -> lastUsed(call)
                else -> unsupportedAction(action)
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("APPDETAIL_ERROR", e.message, null)
        }
    }

    private fun listApps(call: MethodCall): JSONObject {
        val includeSystemApps = call.argument<Boolean>("include_system_apps") ?: false
        val sortBy = call.argument<String>("sort_by") ?: "name"
        val limit = call.argument<Int>("limit") ?: 50

        val visibleApps = loadVisibleApps(includeSystemApps)
        val sortedApps = sortApps(visibleApps, sortBy)
        val limitedApps = sortedApps.take(limit.coerceAtLeast(1))

        return JSONObject().apply {
            put("count", visibleApps.size)
            put("apps", JSONArray().apply {
                limitedApps.forEach { put(appSummaryJson(it)) }
            })
            put("truncated", visibleApps.size > limitedApps.size)
            put("include_system_apps", includeSystemApps)
            put("visible_app_count", visibleApps.size)
        }
    }

    private fun searchApps(call: MethodCall): JSONObject {
        val query = (call.argument<String>("query") ?: "").trim()
        val includeSystemApps = call.argument<Boolean>("include_system_apps") ?: false
        val sortBy = call.argument<String>("sort_by") ?: "name"
        val limit = call.argument<Int>("limit") ?: 50

        if (query.isEmpty()) {
            return JSONObject().apply {
                put("error", "invalid_input")
                put("message", "query is required for search")
            }
        }

        val normalized = query.lowercase(Locale.getDefault())
        val matches = loadVisibleApps(includeSystemApps).filter { app ->
            app.label.lowercase(Locale.getDefault()).contains(normalized) ||
                app.packageName.lowercase(Locale.getDefault()).contains(normalized)
        }

        val sortedApps = sortApps(matches, sortBy)
        val limitedApps = sortedApps.take(limit.coerceAtLeast(1))

        return JSONObject().apply {
            put("query", query)
            put("count", matches.size)
            put("apps", JSONArray().apply {
                limitedApps.forEach { put(appSummaryJson(it)) }
            })
            put("truncated", matches.size > limitedApps.size)
        }
    }

    private fun appDetail(call: MethodCall): JSONObject {
        val packageName = call.argument<String>("package_name")?.trim()
        val query = call.argument<String>("query")?.trim()

        val app = resolveApp(packageName, query)
            ?: return JSONObject().apply {
                put("error", "not_found")
                put("message", "No matching app found.")
            }

        return appDetailJson(app)
    }

    private fun lastUsed(call: MethodCall): JSONObject {
        val packageName = call.argument<String>("package_name")?.trim()
        val query = call.argument<String>("query")?.trim()

        val app = resolveApp(packageName, query)
            ?: return JSONObject().apply {
                put("error", "not_found")
                put("message", "No matching app found.")
            }

        if (!hasUsageStatsPermission()) {
            return JSONObject().apply {
                put("error", "permission_denied")
                put("required_permission", "usage_stats")
                put("message", "Usage Access is required to read last-used app activity. Enable it in Android Settings.")
                put("app_name", app.label)
                put("package_name", app.packageName)
            }
        }

        val usageStatsManager =
            activity.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val oneYearAgo = now - 365L * 24L * 60L * 60L * 1000L
        val usageMap = usageStatsManager.queryAndAggregateUsageStats(oneYearAgo, now)
        val usage = usageMap[app.packageName]
        val lastUsed = usage?.lastTimeUsed ?: 0L

        return JSONObject().apply {
            put("app_name", app.label)
            put("package_name", app.packageName)
            if (lastUsed > 0L) {
                put("last_time_used", isoTime(lastUsed))
                put("last_time_used_relative", relativeTime(lastUsed, now))
                put("usage_data_available", true)
            } else {
                put("last_time_used", JSONObject.NULL)
                put("last_time_used_relative", JSONObject.NULL)
                put("usage_data_available", false)
            }
        }
    }

    // ---- UsageStats ----

    private fun handleUsageStats(call: MethodCall, result: MethodChannel.Result) {
        if (!hasUsageStatsPermission()) {
            result.success(JSONObject().apply {
                put("error", "permission_denied")
                put("required_permission", "usage_stats")
                put("message", "Usage Access is required. Enable it in Android Settings > Apps > Special access > Usage access.")
            }.toString())
            return
        }
        try {
            val action = call.argument<String>("action") ?: "today"
            val response = when (action) {
                "today" -> usageToday(call)
                "range" -> usageRange(call)
                "top_apps" -> usageTopApps(call)
                "app_detail" -> usageAppDetail(call)
                "hourly_breakdown" -> usageHourly(call)
                "summary" -> usageSummary(call)
                else -> JSONObject().apply {
                    put("error", "unsupported_action")
                    put("message", "Supported actions: today, range, top_apps, app_detail, hourly_breakdown, summary")
                }
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("USAGE_STATS_ERROR", e.message, null)
        }
    }

    private fun getUsageStatsManager(): UsageStatsManager {
        return activity.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
    }

    private fun todayStartMillis(): Long {
        return Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    private fun parseDateOrDefault(dateStr: String?, default: Long): Long {
        if (dateStr.isNullOrBlank()) return default
        return try {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(dateStr)?.time ?: default
        } catch (_: Exception) {
            default
        }
    }

    private fun buildAppUsageList(
        stats: Map<String, UsageStats>,
        limit: Int = 50
    ): List<JSONObject> {
        return stats.values
            .filter { it.totalTimeInForeground > 0 }
            .sortedByDescending { it.totalTimeInForeground }
            .take(limit)
            .map { stat ->
                val label = try {
                    val appInfo = packageManager.getApplicationInfo(stat.packageName, 0)
                    packageManager.getApplicationLabel(appInfo).toString()
                } catch (_: Exception) {
                    stat.packageName
                }
                JSONObject().apply {
                    put("app_name", label)
                    put("package_name", stat.packageName)
                    put("foreground_time_ms", stat.totalTimeInForeground)
                    put("foreground_time_human", formatDuration(stat.totalTimeInForeground))
                    put("last_time_used", if (stat.lastTimeUsed > 0) isoTime(stat.lastTimeUsed) else JSONObject.NULL)
                }
            }
    }

    private fun formatDuration(ms: Long): String {
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m ${seconds}s"
            else -> "${seconds}s"
        }
    }

    private fun usageToday(call: MethodCall): JSONObject {
        val usm = getUsageStatsManager()
        val start = todayStartMillis()
        val now = System.currentTimeMillis()
        val stats = usm.queryAndAggregateUsageStats(start, now)
        val limit = call.argument<Int>("limit") ?: 20
        val apps = buildAppUsageList(stats, limit)
        val totalMs = stats.values.sumOf { it.totalTimeInForeground }

        return JSONObject().apply {
            put("date", SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(start)))
            put("total_screen_time_ms", totalMs)
            put("total_screen_time_human", formatDuration(totalMs))
            put("app_count", apps.size)
            put("apps", JSONArray().apply { apps.forEach { put(it) } })
        }
    }

    private fun usageRange(call: MethodCall): JSONObject {
        val usm = getUsageStatsManager()
        val now = System.currentTimeMillis()
        val sevenDaysAgo = now - 7L * 24 * 60 * 60 * 1000
        val start = parseDateOrDefault(call.argument<String>("date_from"), sevenDaysAgo)
        val end = parseDateOrDefault(call.argument<String>("date_to"), now)
        val limit = call.argument<Int>("limit") ?: 20
        val stats = usm.queryAndAggregateUsageStats(start, end)
        val apps = buildAppUsageList(stats, limit)
        val totalMs = stats.values.sumOf { it.totalTimeInForeground }
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)

        return JSONObject().apply {
            put("date_from", fmt.format(Date(start)))
            put("date_to", fmt.format(Date(end)))
            put("total_screen_time_ms", totalMs)
            put("total_screen_time_human", formatDuration(totalMs))
            put("app_count", apps.size)
            put("apps", JSONArray().apply { apps.forEach { put(it) } })
        }
    }

    private fun usageTopApps(call: MethodCall): JSONObject {
        val usm = getUsageStatsManager()
        val now = System.currentTimeMillis()
        val interval = call.argument<String>("interval") ?: "weekly"
        val start = when (interval) {
            "daily" -> todayStartMillis()
            "monthly" -> now - 30L * 24 * 60 * 60 * 1000
            else -> now - 7L * 24 * 60 * 60 * 1000
        }
        val limit = call.argument<Int>("limit") ?: 10
        val stats = usm.queryAndAggregateUsageStats(start, now)
        val apps = buildAppUsageList(stats, limit)

        return JSONObject().apply {
            put("interval", interval)
            put("top_apps", JSONArray().apply { apps.forEach { put(it) } })
            put("count", apps.size)
        }
    }

    private fun usageAppDetail(call: MethodCall): JSONObject {
        val packageName = call.argument<String>("package_name")?.trim()
        val query = call.argument<String>("query")?.trim()
        val app = resolveApp(packageName, query)
            ?: return JSONObject().apply {
                put("error", "not_found")
                put("message", "No matching app found.")
            }

        val usm = getUsageStatsManager()
        val now = System.currentTimeMillis()
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)

        // Today
        val todayStats = usm.queryAndAggregateUsageStats(todayStartMillis(), now)
        val todayMs = todayStats[app.packageName]?.totalTimeInForeground ?: 0L

        // Last 7 days
        val weekStart = now - 7L * 24 * 60 * 60 * 1000
        val weekStats = usm.queryAndAggregateUsageStats(weekStart, now)
        val weekMs = weekStats[app.packageName]?.totalTimeInForeground ?: 0L

        // Last 30 days
        val monthStart = now - 30L * 24 * 60 * 60 * 1000
        val monthStats = usm.queryAndAggregateUsageStats(monthStart, now)
        val monthMs = monthStats[app.packageName]?.totalTimeInForeground ?: 0L
        val lastUsed = monthStats[app.packageName]?.lastTimeUsed ?: 0L

        return JSONObject().apply {
            put("app_name", app.label)
            put("package_name", app.packageName)
            put("today", JSONObject().apply {
                put("foreground_time_ms", todayMs)
                put("foreground_time_human", formatDuration(todayMs))
            })
            put("last_7_days", JSONObject().apply {
                put("foreground_time_ms", weekMs)
                put("foreground_time_human", formatDuration(weekMs))
                put("daily_average_human", formatDuration(weekMs / 7))
            })
            put("last_30_days", JSONObject().apply {
                put("foreground_time_ms", monthMs)
                put("foreground_time_human", formatDuration(monthMs))
                put("daily_average_human", formatDuration(monthMs / 30))
            })
            if (lastUsed > 0L) {
                put("last_time_used", isoTime(lastUsed))
                put("last_time_used_relative", relativeTime(lastUsed, now))
            }
        }
    }

    private fun usageHourly(call: MethodCall): JSONObject {
        val usm = getUsageStatsManager()
        val start = todayStartMillis()
        val now = System.currentTimeMillis()
        val statsList = usm.queryUsageStats(UsageStatsManager.INTERVAL_BEST, start, now)

        // Aggregate by hour
        val hourlyMs = LongArray(24)
        for (stat in statsList) {
            if (stat.totalTimeInForeground <= 0) continue
            val hour = Calendar.getInstance().apply {
                timeInMillis = stat.lastTimeUsed.coerceAtLeast(start)
            }.get(Calendar.HOUR_OF_DAY)
            hourlyMs[hour] += stat.totalTimeInForeground
        }

        val hours = JSONArray()
        for (h in 0..23) {
            hours.put(JSONObject().apply {
                put("hour", h)
                put("label", String.format(Locale.US, "%02d:00-%02d:59", h, h))
                put("foreground_time_ms", hourlyMs[h])
                put("foreground_time_human", formatDuration(hourlyMs[h]))
            })
        }

        return JSONObject().apply {
            put("date", SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(start)))
            put("hours", hours)
            put("total_screen_time_human", formatDuration(hourlyMs.sum()))
        }
    }

    private fun usageSummary(call: MethodCall): JSONObject {
        val usm = getUsageStatsManager()
        val now = System.currentTimeMillis()
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)

        val todayMs = usm.queryAndAggregateUsageStats(todayStartMillis(), now)
            .values.sumOf { it.totalTimeInForeground }
        val weekStart = now - 7L * 24 * 60 * 60 * 1000
        val weekMs = usm.queryAndAggregateUsageStats(weekStart, now)
            .values.sumOf { it.totalTimeInForeground }
        val monthStart = now - 30L * 24 * 60 * 60 * 1000
        val monthStats = usm.queryAndAggregateUsageStats(monthStart, now)
        val monthMs = monthStats.values.sumOf { it.totalTimeInForeground }
        val appsUsedToday = usm.queryAndAggregateUsageStats(todayStartMillis(), now)
            .values.count { it.totalTimeInForeground > 0 }

        // Top 5 apps this week
        val topApps = buildAppUsageList(usm.queryAndAggregateUsageStats(weekStart, now), 5)

        return JSONObject().apply {
            put("today", JSONObject().apply {
                put("screen_time_human", formatDuration(todayMs))
                put("apps_used", appsUsedToday)
            })
            put("last_7_days", JSONObject().apply {
                put("screen_time_human", formatDuration(weekMs))
                put("daily_average_human", formatDuration(weekMs / 7))
            })
            put("last_30_days", JSONObject().apply {
                put("screen_time_human", formatDuration(monthMs))
                put("daily_average_human", formatDuration(monthMs / 30))
            })
            put("top_apps_this_week", JSONArray().apply { topApps.forEach { put(it) } })
        }
    }

    private fun unsupportedAction(action: String): JSONObject {
        return JSONObject().apply {
            put("error", "unsupported_action")
            put("unsupported_action", action)
            put("message", "AppDetail action \"$action\" is not implemented yet on Android. Supported actions: list, search, detail, last_used.")
        }
    }

    private fun resolveApp(packageName: String?, query: String?): AppEntry? {
        if (!packageName.isNullOrBlank()) {
            return try {
                buildAppEntry(packageName)
            } catch (_: Exception) {
                null
            }
        }

        if (query.isNullOrBlank()) {
            return null
        }

        val normalized = query.lowercase(Locale.getDefault())
        val apps = loadVisibleApps(includeSystemApps = true)
        val exactPackageMatch = apps.firstOrNull {
            it.packageName.equals(query, ignoreCase = true)
        }
        if (exactPackageMatch != null) return exactPackageMatch

        val exactLabelMatch = apps.firstOrNull {
            it.label.equals(query, ignoreCase = true)
        }
        if (exactLabelMatch != null) return exactLabelMatch

        val containsMatches = apps.filter {
            it.label.lowercase(Locale.getDefault()).contains(normalized) ||
                it.packageName.lowercase(Locale.getDefault()).contains(normalized)
        }

        return if (containsMatches.size == 1) containsMatches.first() else null
    }

    private fun loadVisibleApps(includeSystemApps: Boolean): List<AppEntry> {
        val installedApps = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getInstalledApplications(
                PackageManager.ApplicationInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledApplications(0)
        }

        return installedApps
            .asSequence()
            .filter { it.packageName != activity.packageName }
            .filter { includeSystemApps || !isSystemApp(it) }
            .filter { shouldIncludeInList(it, includeSystemApps) }
            .mapNotNull { appInfo ->
                runCatching { buildAppEntry(appInfo.packageName, appInfo) }.getOrNull()
            }
            .toList()
    }

    private fun shouldIncludeInList(
        appInfo: ApplicationInfo,
        includeSystemApps: Boolean
    ): Boolean {
        if (includeSystemApps) return true
        return packageManager.getLaunchIntentForPackage(appInfo.packageName) != null
    }

    private fun sortApps(apps: List<AppEntry>, sortBy: String): List<AppEntry> {
        return when (sortBy) {
            "install_date" -> apps.sortedByDescending { it.firstInstallTime }
            "update_date" -> apps.sortedByDescending { it.lastUpdateTime }
            else -> apps.sortedBy { it.label.lowercase(Locale.getDefault()) }
        }
    }

    private fun buildAppEntry(
        packageName: String,
        appInfoHint: ApplicationInfo? = null
    ): AppEntry {
        val packageInfo = getPackageInfo(packageName)
        val appInfo = appInfoHint ?: packageInfo.applicationInfo
            ?: packageManager.getApplicationInfo(packageName, 0)
        val label = packageManager.getApplicationLabel(appInfo)?.toString() ?: packageName
        val versionCode = if (Build.VERSION.SDK_INT >= 28) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }

        return AppEntry(
            label = label,
            packageName = packageName,
            isSystemApp = isSystemApp(appInfo),
            enabled = appInfo.enabled,
            firstInstallTime = packageInfo.firstInstallTime,
            lastUpdateTime = packageInfo.lastUpdateTime,
            versionName = packageInfo.versionName ?: "",
            versionCode = versionCode,
            targetSdk = appInfo.targetSdkVersion,
            minSdk = if (Build.VERSION.SDK_INT >= 24) appInfo.minSdkVersion else null,
            requestedPermissions = packageInfo.requestedPermissions?.toList() ?: emptyList()
        )
    }

    private fun getPackageInfo(packageName: String): PackageInfo {
        return if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
        }
    }

    private fun isSystemApp(appInfo: ApplicationInfo): Boolean {
        return (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
            (appInfo.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
    }

    private fun hasUsageStatsPermission(): Boolean {
        return try {
            val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    android.os.Process.myUid(),
                    activity.packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    android.os.Process.myUid(),
                    activity.packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
    }

    private fun appSummaryJson(app: AppEntry): JSONObject {
        return JSONObject().apply {
            put("app_name", app.label)
            put("package_name", app.packageName)
            put("is_system_app", app.isSystemApp)
            put("enabled", app.enabled)
            put("first_install_time", isoTime(app.firstInstallTime))
            put("last_update_time", isoTime(app.lastUpdateTime))
            put("version_name", app.versionName)
            put("version_code", app.versionCode)
        }
    }

    private fun appDetailJson(app: AppEntry): JSONObject {
        return appSummaryJson(app).apply {
            put("target_sdk", app.targetSdk)
            if (app.minSdk != null) {
                put("min_sdk", app.minSdk)
            }
            put("requested_permissions", JSONArray().apply {
                app.requestedPermissions.sorted().forEach { put(it) }
            })
        }
    }

    private fun isoTime(timestamp: Long): String {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).format(Date(timestamp))
    }

    private fun relativeTime(timestamp: Long, now: Long): String {
        val diffMs = (now - timestamp).coerceAtLeast(0L)
        val minutes = diffMs / 60_000L
        val hours = diffMs / 3_600_000L
        val days = diffMs / 86_400_000L

        return when {
            minutes < 1L -> "just now"
            minutes < 60L -> "$minutes minute${if (minutes == 1L) "" else "s"} ago"
            hours < 24L -> "$hours hour${if (hours == 1L) "" else "s"} ago"
            days < 30L -> "$days day${if (days == 1L) "" else "s"} ago"
            days < 365L -> {
                val months = days / 30L
                "$months month${if (months == 1L) "" else "s"} ago"
            }
            else -> {
                val years = days / 365L
                "$years year${if (years == 1L) "" else "s"} ago"
            }
        }
    }

    private data class AppEntry(
        val label: String,
        val packageName: String,
        val isSystemApp: Boolean,
        val enabled: Boolean,
        val firstInstallTime: Long,
        val lastUpdateTime: Long,
        val versionName: String,
        val versionCode: Long,
        val targetSdk: Int,
        val minSdk: Int?,
        val requestedPermissions: List<String>
    )
}
