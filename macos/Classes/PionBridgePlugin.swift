import Cocoa
import FlutterMacOS

public class PionBridgePlugin: NSObject, FlutterPlugin {
    private var serverProcess: Process?
    private var serverStderr: FileHandle?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "io.pion_bridge.bridge",
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
        serverStderr?.readabilityHandler = nil
        serverStderr = nil

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
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let line = String(data: handle.availableData, encoding: .utf8) ?? ""
            if !line.isEmpty {
                NSLog("[PionBridge] stderr: %@", line)
            }
        }

        // Tear down the stderr reader once the process exits so the handler
        // (and its backing file descriptor) don't leak across restarts.
        // Foundation invokes this on an arbitrary queue; hop to main before
        // touching serverStderr, which is otherwise mutated on the platform
        // thread (startServer/stopServer/deinit).
        process.terminationHandler = { [weak self] _ in
            stderrHandle.readabilityHandler = nil
            DispatchQueue.main.async {
                if self?.serverStderr === stderrHandle {
                    self?.serverStderr = nil
                }
            }
        }

        do {
            try process.run()
        } catch {
            stderrHandle.readabilityHandler = nil
            result(FlutterError(
                code: "SERVER_START_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
            return
        }

        serverProcess = process
        serverStderr = stderrHandle

        // Read startup JSON on a background thread with a 10s timeout
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(10)
            var startupJson: String?

            // Accumulate bytes until we see a newline, then parse that line.
            // The Go server may deliver its startup JSON in more than one chunk,
            // so treating the first chunk as a complete line can truncate it.
            var buffer = Data()
            let fileHandle = stdoutPipe.fileHandleForReading
            while Date() < deadline {
                let data = fileHandle.availableData
                if data.isEmpty {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                buffer.append(data)
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    startupJson = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            DispatchQueue.main.async {
                guard let json = startupJson,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = obj["port"] as? Int,
                      let token = obj["token"] as? String else {
                    process.terminate()
                    // Only drop tracking if a newer startServer hasn't already
                    // replaced serverProcess — nilling unconditionally would
                    // orphan (leak) the newer, healthy child.
                    if self.serverProcess === process {
                        self.serverProcess = nil
                    }
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
        serverStderr?.readabilityHandler = nil
        serverStderr = nil
        result(nil)
    }

    deinit {
        serverProcess?.terminate()
        serverStderr?.readabilityHandler = nil
        serverStderr = nil
    }
}
