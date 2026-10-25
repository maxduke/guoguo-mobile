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
    private class Session {
        val executor = Executors.newFixedThreadPool(3)
        @Volatile var active = true
        @Volatile var client: Client? = null
    }
    private var session: Session? = null
    private val main = Handler(Looper.getMainLooper())
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        session = Session()
        channel = MethodChannel(binding.binaryMessenger, "guoguo/core")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = session ?: return
        owner.executor.execute {
            if (!owner.active) return@execute
            try {
                val value: Any? = when (call.method) {
                    "initialize" -> {
                        synchronized(owner) {
                            if (!owner.active) return@execute
                            if (owner.client == null) owner.client = Mobile.newClient(call.argument<String>("directory") ?: error("缺少数据目录"))
                        }
                        null
                    }
                    "call" -> (owner.client ?: error("站源尚未初始化")).call(call.arguments as String)
                    else -> { main.post { if (owner.active) result.notImplemented() }; return@execute }
                }
                main.post { if (owner.active) result.success(value) }
            } catch (error: Exception) {
                main.post { if (owner.active) result.error("provider", error.message ?: "站源暂不可用", null) }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val retired = session ?: return
        session = null
        retired.active = false
        retired.executor.shutdownNow()
        Thread({
            val closing = synchronized(retired) { retired.client.also { retired.client = null } }
            closing?.close()
        }, "guoguo-core-close").start()
    }
}
