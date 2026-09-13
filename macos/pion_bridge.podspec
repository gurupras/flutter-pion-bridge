Pod::Spec.new do |s|
  s.name             = 'pion_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for PionBridge WebRTC sidecar (macOS).'
  s.homepage         = 'https://github.com/filemingo/pion_bridge'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Filemingo' => 'dev@filemingo.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.resources        = ['Resources/pionbridge']
  # Shared mode (PionBridgeMode.shared): embedded into the app's Frameworks and
  # loaded with dart:ffi. Only present when build_macos.sh produced it.
  s.vendored_libraries = 'Libraries/*.dylib'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
