#ifndef FLUTTER_PLUGIN_PION_BRIDGE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_PION_BRIDGE_PLUGIN_C_API_H_

// The C entry point Flutter's generated plugin registrant calls on Windows. Its
// location (include/<package>/<package>_plugin.h) and name follow the pubspec's
// pluginClass, so the registrant can find it.
#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void PionBridgePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_PION_BRIDGE_PLUGIN_C_API_H_
