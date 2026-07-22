Pod::Spec.new do |s|
  s.name             = 'OnloReactNative'
  s.version          = '0.1.0'
  s.summary          = 'Local React Native bridge for the Onlo iOS native core.'
  s.description      = <<-DESC
Unpublished local-development React Native bridge. It compiles the checked-in
Onlo iOS core into this pod and never downloads, substitutes, or creates a
second Onlo runtime.
  DESC
  s.homepage         = 'https://onlo.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true
  s.module_name      = 'OnloReactNative'

  # Keep one native core per host process. The sibling Swift sources are
  # compiled into this local bridge pod; do not add the SwiftPM product to the
  # application target as well.
  s.source_files = [
    'Sources/**/*.{h,m,mm,swift}',
    '../../ios/Sources/OnloSDK/**/*.swift',
  ]
  s.preserve_paths = [
    '../../ios/Sources/CSQLite/module.modulemap',
    '../../ios/Sources/CSQLite/shim.h',
  ]
  s.dependency 'React-Core'
  s.frameworks = 'Security', 'CryptoKit', 'UIKit'
  s.libraries = 'sqlite3'
  # The SwiftPM target imports CSQLite on toolchains which do not expose the
  # platform SQLite3 module. Keep its system-module map available to this
  # local pod without replacing the pod's own module map.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/../../ios/Sources/CSQLite',
    # Keep the quoted path intact when the local checkout has spaces.
    'OTHER_SWIFT_FLAGS' => '$(inherited) -Xcc -fmodule-map-file="$(PODS_TARGET_SRCROOT)/../../ios/Sources/CSQLite/module.modulemap" -Xcc -I"$(PODS_TARGET_SRCROOT)/../../ios/Sources/CSQLite"',
    'OTHER_CFLAGS' => '$(inherited) -fmodule-map-file="$(PODS_TARGET_SRCROOT)/../../ios/Sources/CSQLite/module.modulemap" -I"$(PODS_TARGET_SRCROOT)/../../ios/Sources/CSQLite"',
  }
end
