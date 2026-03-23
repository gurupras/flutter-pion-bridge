import Cocoa
import FlutterMacOS

public class PionBridgePlugin: NSObject, FlutterPlugin {
    private var serverProcess: Process?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "io.filemingo.pionbridge",
            binaryMessenger: registrar.messenger
        )
        let instance = PionBridgePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startServer":
            startServer(result: result)
        case "stopServer":
            stopServer(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startServer(result: @escaping FlutterResult) {
        // Kill any running server before starting a new one
        serverProcess?.terminate()
        serverProcess = nil

        // Locate the bundled binary in the plugin's Resources
        guard let binaryPath = Bundle(for: type(of: self))
            .path(forResource: "pionbridge", ofType: nil) else {
            result(FlutterError(
                code: "BINARY_NOT_FOUND",
                message: "pionbridge binary not found in plugin bundle",
                details: nil
            ))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stderr asynchronously to prevent blocking
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let line = String(data: handle.availableData, encoding: .utf8) ?? ""
            if !line.isEmpty {
                NSLog("[PionBridge] stderr: %@", line)
            }
        }

        do {
            try process.run()
        } catch {
            result(FlutterError(
                code: "SERVER_START_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
            return
        }

        serverProcess = process

        // Read startup JSON on a background thread with a 10s timeout
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(10)
            var startupJson: String?

            // Read line by line until we get the first non-empty line or timeout
            let fileHandle = stdoutPipe.fileHandleForReading
            while Date() < deadline {
                let data = fileHandle.availableData
                if !data.isEmpty, let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty {
                    startupJson = line
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            DispatchQueue.main.async {
                guard let json = startupJson,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = obj["port"] as? Int,
                      let token = obj["token"] as? String else {
                    process.terminate()
                    self.serverProcess = nil
                    result(FlutterError(
                        code: "SERVER_START_FAILED",
                        message: "No valid startup JSON from Go server",
                        details: nil
                    ))
                    return
                }
                result(["port": port, "token": token])
            }
        }
    }

    private func stopServer(result: @escaping FlutterResult) {
        serverProcess?.terminate()
        serverProcess = nil
        result(nil)
    }

    deinit {
        serverProcess?.terminate()
    }
}
