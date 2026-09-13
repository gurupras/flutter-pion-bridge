#include "include/pion_bridge/pion_bridge_plugin.h"

#include <flutter/plugin_registrar_windows.h>

#include "pionbridge_plugin.h"

void PionBridgePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  pion_bridge::PionBridgePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
