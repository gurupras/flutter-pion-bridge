#ifndef FLUTTER_PLUGIN_PIONBRIDGE_PLUGIN_H_
#define FLUTTER_PLUGIN_PIONBRIDGE_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

namespace pion_bridge {

class PionBridgePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  PionBridgePlugin();
  ~PionBridgePlugin() override;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartServer(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopServer(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HANDLE process_handle_ = INVALID_HANDLE_VALUE;
  HANDLE stdout_read_ = INVALID_HANDLE_VALUE;
};

}  // namespace pion_bridge

#endif  // FLUTTER_PLUGIN_PIONBRIDGE_PLUGIN_H_
