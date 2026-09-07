Pod::Spec.new do |s|
  s.name = 'room_capture'
  s.version = '0.1.0'
  s.summary = 'Single-owner ARKit video and room tracking for RoomScope.'
  s.description = s.summary
  s.homepage = 'https://example.invalid/roomscope'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'RoomScope' => 'roomscope@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.frameworks = 'ARKit', 'SceneKit', 'AVFoundation', 'CoreImage'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
