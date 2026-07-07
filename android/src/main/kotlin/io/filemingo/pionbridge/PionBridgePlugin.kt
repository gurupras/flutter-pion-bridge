package io.filemingo.pionbridge

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class PionBridgePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serverLock = Any()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "io.pion_bridge.bridge")
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
                // Serialize stop+start so a concurrent double startServer can't
                // race Go's mobile.Start ("server already running").
                val startResult = synchronized(serverLock) {
                    mobile.Mobile.stop()
                    mobile.Mobile.start()
                }
                val reply = hashMapOf(
                    "port" to startResult.port,
                    "token" to startResult.token,
                )
                mainHandler.post { result.success(reply) }
            } catch (e: Exception) {
                val message = e.message ?: "Unknown error"
                mainHandler.post { result.error("SERVER_START_FAILED", message, null) }
            }
        }.also { it.isDaemon = true }.start()
    }

    private fun stopServer(result: Result) {
        Thread {
            try {
                synchronized(serverLock) {
                    mobile.Mobile.stop()
                }
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                val message = e.message ?: "Unknown error"
                mainHandler.post { result.error("SERVER_STOP_FAILED", message, null) }
            }
        }.also { it.isDaemon = true }.start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try { mobile.Mobile.stop() } catch (_: Exception) {}
    }
}
