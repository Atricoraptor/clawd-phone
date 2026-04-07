package com.clawdphone.app.channels

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import android.os.Environment
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Handles device-related tools: DeviceInfo, Battery.
 *
 * This class is NOT registered as its own channel. Instead, FileToolsChannel
 * delegates DeviceInfo and Battery method calls to this handler, since both
 * share the same "com.clawdphone.app/tools" channel.
 */
class DeviceToolsChannel(
    private val activity: Activity
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "DeviceInfo" -> handleDeviceInfo(call, result)
            "Battery" -> handleBattery(result)
            else -> result.notImplemented()
        }
    }

    private fun handleDeviceInfo(call: MethodCall, result: MethodChannel.Result) {
        try {
            val sections = call.argument<List<String>>("sections") ?: listOf("all")
            val includeAll = sections.contains("all")

            val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            am.getMemoryInfo(memInfo)

            val wm = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)

            val pm = activity.packageManager
            val response = JSONObject().apply {
                if (includeAll || sections.contains("hardware")) {
                    put("hardware", JSONObject().apply {
                        put("manufacturer", Build.MANUFACTURER)
                        put("brand", Build.BRAND)
                        put("model", Build.MODEL)
                        put("device_name", Build.DEVICE)
                        put("board", Build.BOARD)
                        put("cpu_architecture", Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
                        put("cpu_cores", Runtime.getRuntime().availableProcessors())
                        put("supported_abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
                        put("total_ram_bytes", memInfo.totalMem)
                        put("total_ram_human", formatSize(memInfo.totalMem))
                        put("available_ram_bytes", memInfo.availMem)
                        put("available_ram_human", formatSize(memInfo.availMem))
                        put("is_low_ram_device", am.isLowRamDevice)
                    })
                }
                if (includeAll || sections.contains("software")) {
                    put("software", JSONObject().apply {
                        put("android_version", Build.VERSION.RELEASE)
                        put("api_level", Build.VERSION.SDK_INT)
                        put("security_patch", if (Build.VERSION.SDK_INT >= 23) Build.VERSION.SECURITY_PATCH else "unknown")
                        put("build_number", Build.DISPLAY)
                        put("build_type", Build.TYPE)
                        put("bootloader", Build.BOOTLOADER)
                        put("system_language", java.util.Locale.getDefault().displayLanguage)
                        put("timezone", java.util.TimeZone.getDefault().id)
                        put("uptime_ms", android.os.SystemClock.elapsedRealtime())
                    })
                }
                if (includeAll || sections.contains("display")) {
                    put("display", JSONObject().apply {
                        put("resolution", "${metrics.widthPixels}x${metrics.heightPixels}")
                        put("density_dpi", metrics.densityDpi)
                        put("density_bucket", when {
                            metrics.densityDpi <= 120 -> "ldpi"
                            metrics.densityDpi <= 160 -> "mdpi"
                            metrics.densityDpi <= 240 -> "hdpi"
                            metrics.densityDpi <= 320 -> "xhdpi"
                            metrics.densityDpi <= 480 -> "xxhdpi"
                            else -> "xxxhdpi"
                        })
                    })
                }
                if (includeAll || sections.contains("features")) {
                    put("features", JSONObject().apply {
                        put("has_nfc", pm.hasSystemFeature("android.hardware.nfc"))
                        put("has_bluetooth", pm.hasSystemFeature("android.hardware.bluetooth"))
                        put("has_fingerprint", pm.hasSystemFeature("android.hardware.fingerprint"))
                        put("has_telephony", pm.hasSystemFeature("android.hardware.telephony"))
                        put("has_wifi", pm.hasSystemFeature("android.hardware.wifi"))
                        put("has_gps", pm.hasSystemFeature("android.hardware.location.gps"))
                        put("has_camera_front", pm.hasSystemFeature("android.hardware.camera.front"))
                        put("has_camera_back", pm.hasSystemFeature("android.hardware.camera"))
                        put("has_accelerometer", pm.hasSystemFeature("android.hardware.sensor.accelerometer"))
                        put("has_gyroscope", pm.hasSystemFeature("android.hardware.sensor.gyroscope"))
                        put("has_barometer", pm.hasSystemFeature("android.hardware.sensor.barometer"))
                    })
                }
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("DEVICE_INFO_ERROR", e.message, null)
        }
    }

    private fun handleBattery(result: MethodChannel.Result) {
        try {
            val intentFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            val batteryIntent = if (Build.VERSION.SDK_INT >= 34) {
                activity.registerReceiver(null, intentFilter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                activity.registerReceiver(null, intentFilter)
            }

            val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
            val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val health = batteryIntent?.getIntExtra(BatteryManager.EXTRA_HEALTH, -1) ?: -1
            val temp = (batteryIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1) / 10.0
            val voltage = batteryIntent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1
            val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
            val technology = batteryIntent?.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY) ?: "unknown"

            val response = JSONObject().apply {
                put("level_percent", percent)
                put("status", when (status) {
                    BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                    BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                    BatteryManager.BATTERY_STATUS_FULL -> "full"
                    BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
                    else -> "unknown"
                })
                put("health", when (health) {
                    BatteryManager.BATTERY_HEALTH_GOOD -> "good"
                    BatteryManager.BATTERY_HEALTH_OVERHEAT -> "overheat"
                    BatteryManager.BATTERY_HEALTH_DEAD -> "dead"
                    BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "over_voltage"
                    BatteryManager.BATTERY_HEALTH_COLD -> "cold"
                    else -> "unknown"
                })
                put("temperature_celsius", temp)
                put("voltage_mv", voltage)
                put("technology", technology)
                put("plugged", when (plugged) {
                    BatteryManager.BATTERY_PLUGGED_AC -> "ac"
                    BatteryManager.BATTERY_PLUGGED_USB -> "usb"
                    BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
                    else -> "none"
                })
                put("is_charging", status == BatteryManager.BATTERY_STATUS_CHARGING)
            }

            result.success(response.toString())
        } catch (e: Exception) {
            result.error("BATTERY_ERROR", e.message, null)
        }
    }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1_073_741_824 -> "%.1f GB".format(bytes / 1_073_741_824.0)
        bytes >= 1_048_576 -> "%.1f MB".format(bytes / 1_048_576.0)
        bytes >= 1024 -> "%.1f KB".format(bytes / 1024.0)
        else -> "$bytes B"
    }
}
