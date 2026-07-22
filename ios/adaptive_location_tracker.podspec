Pod::Spec.new do |s|
  s.name             = 'adaptive_location_tracker'
  s.version          = '0.1.3'
  s.summary          = 'Cross-platform live location tracking (Android + iOS).'
  s.description      = <<-DESC
Adaptive speed-based filtering, an Android foreground service, an iOS
kill-survival background service, offline queueing, and degraded-mode
backoff -- with your backend and UI wired in via simple callbacks.
                       DESC
  s.homepage         = 'https://github.com/your-org/adaptive_location_tracker'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Org' => 'engineering@your-org.example' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'

  s.frameworks = 'CoreLocation', 'CoreMotion', 'Network'
  s.libraries = 'sqlite3'
end
