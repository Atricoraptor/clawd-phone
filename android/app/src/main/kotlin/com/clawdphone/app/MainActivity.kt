package com.clawdphone.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.clawdphone.app.channels.FileToolsChannel
import com.clawdphone.app.channels.ClipboardChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register tool platform channels
        // FileToolsChannel is the unified handler for all tools on "com.clawdphone.app/tools"
        // including DeviceInfo and Battery (delegated to DeviceToolsChannel internally)
        FileToolsChannel.register(flutterEngine, this)
        ClipboardChannel.register(flutterEngine, this)

        // TODO: Register additional channels as tools are implemented:
        // PersonalToolsChannel.register(flutterEngine, this)
        // IntelligenceToolsChannel.register(flutterEngine, this)
        // AdvancedToolsChannel.register(flutterEngine, this)
    }
}
