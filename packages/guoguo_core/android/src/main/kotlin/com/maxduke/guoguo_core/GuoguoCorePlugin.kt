package com.maxduke.guoguo_core

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import mobile.Client
import mobile.Mobile
import org.json.JSONObject

class GuoguoCorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private class Session {
        val dispatcher = ProviderCallDispatcher()
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
        val envelope = call.arguments as? Map<*, *>
        val raw = if (call.method == "call") {
            (envelope?.get("request") ?: call.arguments) as? String
        } else null
        val legacy = try {
            if (call.method == "call" && envelope == null) JSONObject(raw ?: "") else null
        } catch (_: Exception) {
            result.error("provider", "请求格式错误", null)
            return
        }
        val configured = (envelope?.get("timeoutMs") as? Number)?.toInt() ?: legacy?.optInt("timeoutMs", 0) ?: 0
        if (configured < 0 || configured > 75000) {
            result.error("provider", "请求时限无效", null)
            return
        }
        val budget = if (configured == 0) 75000 else maxOf(100, configured)
        val method = envelope?.get("method") as? String ?: legacy?.optString("method")
        val control = method in setOf(
            "cancelResolve", "cancelSearch", "cancelCatalog", "cancelPrefetch",
            "release", "requestDiagnostic", "searchProgress", "coreInfo"
        )
        owner.dispatcher.execute(control, budget, { remaining ->
            if (!owner.active) return@execute null
            when (call.method) {
                "initialize" -> {
                    synchronized(owner) {
                        if (!owner.active) return@execute null
                        if (owner.client == null) owner.client = Mobile.newClient(call.argument<String>("directory") ?: error("缺少数据目录"))
                    }
                    mapOf("dispatchEnvelope" to 1)
                }
                "call" -> {
                    // Large provider payloads are parsed on a worker. The small
                    // envelope lets cancellation bypass IO without UI parsing.
                    val request = JSONObject(raw ?: error("请求格式错误"))
                    if (request.optString("method") != method) error("请求方法不匹配")
                    (owner.client ?: error("站源尚未初始化")).call(request.put("timeoutMs", remaining).toString())
                }
                else -> { main.post { if (owner.active) result.notImplemented() }; return@execute null }
            }
        }, object : ProviderCallDispatcher.Result {
            override fun success(value: Any?) {
                if (call.method == "initialize" || call.method == "call") {
                    main.post { if (owner.active) result.success(value) }
                }
            }
            override fun failure(error: Exception) {
                main.post { if (owner.active) result.error("provider", error.message ?: "站源暂不可用", null) }
            }
        })
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val retired = session ?: return
        session = null
        retired.active = false
        retired.dispatcher.close()
        Thread({
            val closing = synchronized(retired) { retired.client.also { retired.client = null } }
            closing?.close()
        }, "guoguo-core-close").start()
    }
}
