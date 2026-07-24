Pod::Spec.new do |s|
  s.name             = 'OnloReactNative'
  s.version          = '0.1.0'
  s.summary          = 'React Native bridge for the Onlo native mobile SDKs.'
  s.description      = <<-DESC
Typed React Native bridge that delegates protected state, transport, durable
delivery, and messenger presentation to the Onlo native SDK for the host OS.
  DESC
  s.homepage         = 'https://github.com/onlo-ai/onlo-mobile-sdks'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = {
    :git => 'https://github.com/onlo-ai/onlo-mobile-sdks.git',
    :tag => s.version.to_s,
  }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true
  s.module_name      = 'OnloReactNative'

  s.source_files = 'ios/Sources/**/*.{h,m,mm,swift}'
  s.dependency 'React-Core'
  s.dependency 'OnloSDK', '0.1.0'
end
