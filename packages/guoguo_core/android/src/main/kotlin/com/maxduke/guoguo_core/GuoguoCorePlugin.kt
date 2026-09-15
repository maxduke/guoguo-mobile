package com.maxduke.guoguo_core

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import mobile.Client
import mobile.Mobile
import java.util.concurrent.Executors

class GuoguoCorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var client: Client? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "guoguo/core")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val value: Any? = when (call.method) {
                    "initialize" -> {
                        synchronized(this) {
                            if (client == null) client = Mobile.newClient(call.argument<String>("directory") ?: error("缺少数据目录"))
                        }
                        null
                    }
                    "call" -> (client ?: error("站源尚未初始化")).call(call.arguments as String)
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { result.error("provider", error.message ?: "站源暂不可用", null) }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
        client?.close()
        client = null
    }
}
