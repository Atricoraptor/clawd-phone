package com.clawdphone.app.channels

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * Handles clipboard image detection and retrieval for the paste feature.
 */
class ClipboardChannel private constructor(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.clawdphone.app/clipboard"

        fun register(engine: FlutterEngine, activity: Activity) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler(ClipboardChannel(activity))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "clipboardHasImage" -> checkClipboardImage(result)
            "getClipboardImage" -> getClipboardImage(result)
            else -> result.notImplemented()
        }
    }

    private fun checkClipboardImage(result: MethodChannel.Result) {
        try {
            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            if (clip == null || clip.itemCount == 0) {
                result.success(false)
                return
            }

            val item = clip.getItemAt(0)
            val uri = item.uri
            if (uri != null) {
                val type = activity.contentResolver.getType(uri)
                result.success(type?.startsWith("image/") == true)
            } else {
                result.success(false)
            }
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun getClipboardImage(result: MethodChannel.Result) {
        try {
            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            if (clip == null || clip.itemCount == 0) {
                result.error("NO_IMAGE", "No image in clipboard", null)
                return
            }

            val uri = clip.getItemAt(0).uri
            if (uri == null) {
                result.error("NO_IMAGE", "No image URI in clipboard", null)
                return
            }

            val inputStream = activity.contentResolver.openInputStream(uri)
            if (inputStream == null) {
                result.error("NO_IMAGE", "Cannot open clipboard image", null)
                return
            }

            val imageBytes = inputStream.readBytes()
            inputStream.close()

            val decoded = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)

            if (decoded == null) {
                result.error("DECODE_ERROR", "Cannot decode clipboard image", null)
                return
            }

            val bitmap = applyExifOrientation(imageBytes, decoded)

            // Resize if too large
            val maxDim = 1536
            val scaled = if (bitmap.width > maxDim || bitmap.height > maxDim) {
                val ratio = minOf(maxDim.toFloat() / bitmap.width, maxDim.toFloat() / bitmap.height)
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * ratio).toInt(),
                    (bitmap.height * ratio).toInt(),
                    true
                )
            } else {
                bitmap
            }

            val baos = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 90, baos)
            if (scaled !== bitmap) bitmap.recycle()
            if (bitmap !== decoded) decoded.recycle()
            result.success(baos.toByteArray())
        } catch (e: Exception) {
            result.error("CLIPBOARD_ERROR", e.message, null)
        }
    }

    private fun applyExifOrientation(imageBytes: ByteArray, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(imageBytes)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.preScale(-1f, 1f)
                matrix.postRotate(270f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.preScale(-1f, 1f)
                matrix.postRotate(90f)
            }
            else -> return bitmap
        }

        return Bitmap.createBitmap(
            bitmap,
            0,
            0,
            bitmap.width,
            bitmap.height,
            matrix,
            true
        )
    }
}
