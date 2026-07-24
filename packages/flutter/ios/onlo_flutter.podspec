Pod::Spec.new do |s|
  s.name             = 'onlo_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Flutter bridge for the Onlo native mobile SDKs.'
  s.description      = <<-DESC
Typed Flutter bridge that delegates protected state, transport, durable
delivery, and messenger presentation to the Onlo native SDK for the host OS.
  DESC
  s.homepage         = 'https://github.com/onlo-ai/onlo-mobile-sdks'
  s.documentation_url = 'https://github.com/onlo-ai/onlo-mobile-sdks/tree/main/packages/flutter#readme'
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = { 'Onlo' => 'support@onlo.ai' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.10'
  s.static_framework = true

  s.source_files = 'Classes/**/*.{swift,h,m}'
  s.dependency 'Flutter'
  s.dependency 'OnloSDK', '0.1.0'
end
