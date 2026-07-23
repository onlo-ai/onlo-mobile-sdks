Pod::Spec.new do |s|
  s.name             = 'OnloReactNative'
  s.version          = '0.1.0'
  s.summary          = 'Local React Native bridge for the Onlo iOS native core.'
  s.description      = <<-DESC
Unpublished local-development React Native bridge. It depends on the checked-in
OnloSDK pod and never downloads, substitutes, or creates a second runtime.
  DESC
  s.homepage         = 'https://onlo.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true
  s.module_name      = 'OnloReactNative'

  s.source_files = 'ios/Sources/**/*.{h,m,mm,swift}'
  s.dependency 'React-Core'
  s.dependency 'OnloSDK', '0.1.0'
end
