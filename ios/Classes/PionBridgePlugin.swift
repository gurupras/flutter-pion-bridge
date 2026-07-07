import Flutter
import UIKit
import PionBridgeGo

public class PionBridgePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "io.pion_bridge.bridge",
            binaryMessenger: registrar.messenger()
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
        DispatchQueue.global(qos: .userInitiated).async {
            // Stop any running server first so hot restart works — Go's
            // MobileStart returns "server already running" otherwise.
            MobileStop(nil)

            var error: NSError?
            guard let startResult = MobileStart(&error) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "START_FAILED",
                        message: error?.localizedDescription ?? "Unknown error",
                        details: nil
                    ))
                }
                return
            }

            DispatchQueue.main.async {
                result([
                    "port": startResult.port,
                    "token": startResult.token
                ])
            }
        }
    }

    private func stopServer(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            MobileStop(nil)
            DispatchQueue.main.async {
                result(nil)
            }
        }
    }
}
