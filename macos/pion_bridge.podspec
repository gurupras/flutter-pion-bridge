require File.expand_path('../build_support/pion_bridge_binaries', __dir__)

Pod::Spec.new do |s|
  s.name             = 'pion_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for PionBridge WebRTC sidecar (macOS).'
  s.homepage         = 'https://github.com/filemingo/pion_bridge'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Filemingo' => 'dev@filemingo.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  # Apps that only use shared mode with their own library skip the sidecar, as
  # PION_BRIDGE_BUNDLE_BINARIES=OFF does on Linux and Windows: set the variable
  # in the environment `pod install` (flutter build macos) runs in.
  # Local builds (scripts/build_macos.sh) win when present; otherwise (or with
  # PION_BRIDGE_BINARIES_BASE_URL set) this version's release archive supplies
  # both files.
  bundle = ENV['PION_BRIDGE_BUNDLE_BINARIES'] != 'OFF'
  if bundle && (ENV['PION_BRIDGE_BINARIES_BASE_URL'] ||
                !File.exist?(File.join(__dir__, 'Resources', 'pionbridge')))
    downloaded = PionBridgeBinaries.download(__dir__, 'macos')
    s.resources          = ["#{downloaded}/pionbridge"]
    # Shared mode (PionBridgeMode.shared): embedded into the app's Frameworks
    # and loaded with dart:ffi.
    s.vendored_libraries = "#{downloaded}/libpionbridge.dylib"
  else
    s.resources          = ['Resources/pionbridge'] if bundle
    # Shared mode: only present when build_macos.sh produced it.
    s.vendored_libraries = 'Libraries/*.dylib'
  end
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
