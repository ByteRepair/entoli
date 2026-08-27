Pod::Spec.new do |s|
  s.name             = 'ish'
  s.version          = '1.0.0'
  s.summary          = 'The iSH emulator core, built as an in-process shell for Entoli on iOS.'
  s.homepage         = 'https://github.com/ish-app/ish'
  s.license          = { :type => 'GPL-2.0', :file => 'src/LICENSE.md' }
  s.author           = { 'ish-app' => 'https://github.com/ish-app/ish' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '14.0'
  # The XCFramework built by tool/bundle/ish/build.sh. A prebuilt binary
  # rather than source compilation, because the asbestos gadgets are
  # hand-written assembly and the build needs Xcode — the same reason the
  # Android build ships .so files laid out by tool/bundle/build.sh.
  s.vendored_frameworks = 'dist/IshCore.xcframework'
  s.libraries        = 'sqlite3'
  s.frameworks       = 'Foundation'
  s.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => '' }
end
