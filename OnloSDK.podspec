onlo_sdk_version = File.read(File.join(__dir__, 'VERSION')).strip
raise 'VERSION must contain one semantic version' unless onlo_sdk_version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)

Pod::Spec.new do |s|
  s.name             = 'OnloSDK'
  s.version          = onlo_sdk_version
  s.summary          = 'Native Onlo support messenger for iOS.'
  s.description      = <<-DESC
The single native iOS Core used by native, React Native, and Flutter hosts.
It owns protected identity, transport, persistence, outbox, and messenger UI.
  DESC
  s.homepage         = 'https://github.com/onlo-ai/onlo-mobile-sdks'
  s.documentation_url = 'https://github.com/onlo-ai/onlo-mobile-sdks/blob/main/packages/ios/README.md'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = {
    :git => 'https://github.com/onlo-ai/onlo-mobile-sdks.git',
    :tag => s.version.to_s,
  }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true
  s.source_files     = 'packages/ios/Sources/OnloSDK/**/*.swift'
  s.preserve_paths   = [
    'packages/ios/Sources/CSQLite/module.modulemap',
    'packages/ios/Sources/CSQLite/shim.h',
  ]
  s.frameworks = 'Security', 'CryptoKit', 'UIKit'
  s.libraries = 'sqlite3'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/packages/ios/Sources/CSQLite',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -Xcc -fmodule-map-file="$(PODS_TARGET_SRCROOT)/packages/ios/Sources/CSQLite/module.modulemap" -Xcc -I"$(PODS_TARGET_SRCROOT)/packages/ios/Sources/CSQLite"',
    'OTHER_CFLAGS' => '$(inherited) -fmodule-map-file="$(PODS_TARGET_SRCROOT)/packages/ios/Sources/CSQLite/module.modulemap" -I"$(PODS_TARGET_SRCROOT)/packages/ios/Sources/CSQLite"',
  }
end
