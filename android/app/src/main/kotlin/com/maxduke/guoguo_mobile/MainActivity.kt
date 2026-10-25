package com.maxduke.guoguo_mobile

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guoguo/device").setMethodCallHandler { call, result ->
            if (call.method == "isTelevision") {
                val mode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                result.success(mode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
            } else {
                result.notImplemented()
            }
        }
    }
}
