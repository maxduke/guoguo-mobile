package com.maxduke.guoguo_mobile

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var renderingPolicy = "automatic"

    private fun isTelevisionDevice(): Boolean =
        (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)
            ?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION

    @Suppress("DEPRECATION")
    override fun getFlutterShellArgs(): FlutterShellArgs {
        val television = isTelevisionDevice()
        renderingPolicy = if (television) "legacy-opengl" else "automatic"
        return FlutterShellArgs(TelevisionRendererPolicy.arguments(
            super.getFlutterShellArgs().toArray(),
            television,
        ))
    }

    @Suppress("DEPRECATION")
    private fun playbackDeviceInfo(): Map<String, Any> {
        val info = packageManager.getPackageInfo(packageName, 0)
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "androidVersion" to Build.VERSION.RELEASE,
            "apiLevel" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "applicationId" to packageName,
            "version" to (info.versionName ?: ""),
            "build" to if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong(),
            "television" to isTelevisionDevice(),
            "renderingPolicy" to renderingPolicy,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guoguo/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevisionDevice())
                "playbackDeviceInfo" -> result.success(playbackDeviceInfo())
                else -> result.notImplemented()
            }
        }
    }
}
