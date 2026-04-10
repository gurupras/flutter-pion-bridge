//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <pion_bridge/pionbridge_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) pion_bridge_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "PionbridgePlugin");
  pionbridge_plugin_register_with_registrar(pion_bridge_registrar);
}
