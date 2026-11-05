Pod::Spec.new do |s|
  s.name         = "Feedpulse"
  s.version      = "0.1.1"
  s.summary      = "Feedpulse iOS SDK（該当箇所ピッカー）"
  s.homepage     = "https://github.com/lv-kit/feedpulse-ios"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.authors      = "lv-kit"
  s.source       = { :git => "https://github.com/lv-kit/feedpulse-ios.git", :tag => s.version.to_s }
  s.platforms    = { :ios => "15.0" }
  s.swift_version = "5.9"
  s.source_files = "Sources/Feedpulse/**/*.swift"
end
