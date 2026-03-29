package io.filemingo.pionbridge

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class PionBridgePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "io.filemingo.pionbridge")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startServer" -> startServer(result)
            "stopServer" -> stopServer(result)
            else -> result.notImplemented()
        }
    }

    private fun startServer(result: Result) {
        Thread {
            try {
                mobile.Mobile.stop()
                val startResult = mobile.Mobile.start()
                result.success(hashMapOf(
                    "port" to startResult.port,
                    "token" to startResult.token,
                ))
            } catch (e: Exception) {
                result.error("SERVER_START_FAILED", e.message ?: "Unknown error", null)
            }
        }.also { it.isDaemon = true }.start()
    }

    private fun stopServer(result: Result) {
        Thread {
            try {
                mobile.Mobile.stop()
                result.success(null)
            } catch (e: Exception) {
                result.error("SERVER_STOP_FAILED", e.message ?: "Unknown error", null)
            }
        }.also { it.isDaemon = true }.start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try { mobile.Mobile.stop() } catch (_: Exception) {}
    }
}
