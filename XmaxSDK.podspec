Pod::Spec.new do |spec|
  spec.name = 'XmaxSDK'
  spec.version = '1.0.1'
  spec.summary = 'Xmax realtime generation SDK for macOS.'
  spec.description = <<-DESC
    XmaxSDK provides native macOS APIs for camera-based realtime generation.
    Supports Swift Package Manager and CocoaPods with the same SDK sources.
  DESC

  spec.homepage = 'https://xmax.ai'
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.author = { 'XMAX.AI PTE. LTD.' => 'sdk@xmax.ai' }
  spec.source = {
    git: 'https://github.com/Xmax-AI/XmaxSDK-MacOS.git',
    tag: spec.version.to_s
  }

  spec.platform = :osx, '13.0'
  spec.swift_version = '6.0'
  spec.module_name = 'XmaxSDK'
  spec.static_framework = true
  spec.source_files = 'Sources/XmaxSDK/**/*.swift'

  spec.dependency 'AgoraRtcEngine_macOS/RtcBasic', '4.6.2'
  spec.dependency 'QCloudCOSXML/Transfer', '6.5.7'

  spec.test_spec 'Tests' do |tests|
    tests.source_files = 'Tests/XmaxSDKTests/**/*.swift'
  end
end
