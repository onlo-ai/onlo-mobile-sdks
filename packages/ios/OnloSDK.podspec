Pod::Spec.new do |s|
  s.name             = 'OnloSDK'
  s.version          = '0.1.0'
  s.summary          = 'Onlo native iOS Core.'
  s.description      = <<-DESC
The single native iOS Core used by native, React Native, and Flutter hosts.
It owns protected identity, transport, persistence, outbox, and messenger UI.
  DESC
  s.homepage         = 'https://onlo.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true
  s.source_files     = 'Sources/OnloSDK/**/*.swift'
  s.preserve_paths   = [
    'Sources/CSQLite/module.modulemap',
    'Sources/CSQLite/shim.h',
  ]
  s.frameworks = 'Security', 'CryptoKit', 'UIKit'
  s.libraries = 'sqlite3'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Sources/CSQLite',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -Xcc -fmodule-map-file="$(PODS_TARGET_SRCROOT)/Sources/CSQLite/module.modulemap" -Xcc -I"$(PODS_TARGET_SRCROOT)/Sources/CSQLite"',
    'OTHER_CFLAGS' => '$(inherited) -fmodule-map-file="$(PODS_TARGET_SRCROOT)/Sources/CSQLite/module.modulemap" -I"$(PODS_TARGET_SRCROOT)/Sources/CSQLite"',
  }
end
