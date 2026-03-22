package io.filemingo.pionbridge

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

class PionBridgePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var serverProcess: Process? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
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
        try {
            val nativeLibDir = context.applicationInfo.nativeLibraryDir
            val binaryPath = "$nativeLibDir/libpionbridge.so"

            val binaryFile = File(binaryPath)
            if (!binaryFile.exists()) {
                result.error("BINARY_NOT_FOUND", "Go binary not found at $binaryPath", null)
                return
            }

            // Kill any existing server before starting a new one
            serverProcess?.destroy()
            serverProcess = null

            val processBuilder = ProcessBuilder(binaryPath)
            processBuilder.redirectErrorStream(false)
            val process = processBuilder.start()
            serverProcess = process

            // Drain stderr in background so it doesn't block the process
            Thread {
                try {
                    process.errorStream.bufferedReader().forEachLine { line ->
                        android.util.Log.w("PionBridge", "server stderr: $line")
                    }
                } catch (_: Exception) {}
            }.also { it.isDaemon = true }.start()

            // Read startup JSON from stdout with a 10-second timeout
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            val startupJson: String? = runWithTimeout(10_000L) { reader.readLine() }

            if (startupJson == null) {
                process.destroy()
                serverProcess = null
                result.error("SERVER_START_FAILED", "No startup output from Go server (timed out)", null)
                return
            }

            val json = org.json.JSONObject(startupJson)
            val port = json.getInt("port")
            val token = json.getString("token")

            result.success(hashMapOf("port" to port, "token" to token))
        } catch (e: Exception) {
            serverProcess?.destroy()
            serverProcess = null
            result.error("SERVER_START_FAILED", e.message ?: "Unknown error", null)
        }
    }

    /**
     * Runs [block] on a background thread and waits up to [timeoutMs] ms for the result.
     * Returns null if the timeout expires.
     */
    private fun <T> runWithTimeout(timeoutMs: Long, block: () -> T): T? {
        var value: T? = null
        val thread = Thread { value = block() }
        thread.isDaemon = true
        thread.start()
        thread.join(timeoutMs)
        return value
    }

    private fun stopServer(result: Result) {
        serverProcess?.destroy()
        serverProcess = null
        result.success(null)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        serverProcess?.destroy()
        serverProcess = null
    }
}
