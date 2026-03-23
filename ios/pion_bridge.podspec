Pod::Spec.new do |s|
  s.name             = 'pion_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin wrapping Pion WebRTC via a Go WebSocket sidecar (iOS via gomobile).'
  s.homepage         = 'https://github.com/filemingo/flutter-pion-bridge'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Filemingo' => 'dev@filemingo.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Gomobile-generated xcframework (built by scripts/build_ios.sh)
  s.vendored_frameworks = 'Frameworks/PionBridgeGo.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
