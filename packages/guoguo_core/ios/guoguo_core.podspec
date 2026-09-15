Pod::Spec.new do |s|
  s.name = 'guoguo_core'
  s.version = '0.1.0'
  s.summary = 'On-device Guoguo provider bridge'
  s.description = 'Calls the embedded Go provider core without an external server.'
  s.homepage = 'https://github.com/maxduke/guoguo-mobile'
  s.license = { :type => 'Proprietary' }
  s.author = 'maxduke'
  s.source = { :path => '.' }
  s.source_files = 'guoguo_core/Sources/guoguo_core/**/*.swift'
  s.vendored_frameworks = 'Frameworks/GuoguoMobile.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
