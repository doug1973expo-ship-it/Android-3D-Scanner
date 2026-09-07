import Flutter
import UIKit
import ARKit
import SceneKit
import AVFoundation
import simd

public class RoomCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, ARSessionDelegate {
    private let session = ARSession()
    private let queue = DispatchQueue(label: "roomscope.capture")
    private var sink: FlutterEventSink?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var firstVideoTimestamp: Double?
    private var videoFrames = 0
    private var lastMappingTimestamp: Double = -1
    private var paused = true

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RoomCapturePlugin()
        plugin.session.delegate = plugin
        plugin.session.delegateQueue = plugin.queue
        let methods = FlutterMethodChannel(name: "roomscope/capture", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: methods)
        FlutterEventChannel(name: "roomscope/frames", binaryMessenger: registrar.messenger())
            .setStreamHandler(plugin)
        registrar.register(PreviewFactory(session: plugin.session), withId: "roomscope/preview")
    }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    private func emit(_ data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.sink?(data) }
    }
    private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }
    private func start(reset: Bool) throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw CaptureError.unsupported }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw CaptureError.permission }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 })
            .min(by: { $0.imageResolution.width*$0.imageResolution.height < $1.imageResolution.width*$1.imageResolution.height }) {
            configuration.videoFormat = format
        }
        session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        paused = false
        if reset { lastMappingTimestamp = -1 }
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        queue.async {
            do {
                switch call.method {
                case "start":
                    if self.paused { try self.start(reset: false) }
                    self.reply(result, nil)
                case "reset":
                    guard self.recordingURL == nil else { throw CaptureError.busy }
                    try self.start(reset: true); self.reply(result, nil)
                case "pause":
                    self.session.pause(); self.paused = true; self.reply(result, nil)
                case "record":
                    guard !self.paused, self.recordingURL == nil,
                          let args = call.arguments as? [String: Any],
                          let directory = args["directory"] as? String else { throw CaptureError.busy }
                    let folder = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
                    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
                    guard folder.path.hasPrefix(home + "/") else { throw CaptureError.path }
                    let output = folder.appendingPathComponent("capture.mp4")
                    guard !FileManager.default.fileExists(atPath: output.path) else { throw CaptureError.path }
                    self.recordingURL = output
                    self.firstVideoTimestamp = nil
                    self.videoFrames = 0
                    self.reply(result, nil)
                case "stopRecording": self.finish(result)
                case "dispose":
                    self.session.pause(); self.paused = true
                    self.finish(result)
                default: self.reply(result, FlutterMethodNotImplemented)
                }
            } catch {
                self.reply(result, FlutterError(code: "camera", message: String(describing: error), details: nil))
            }
        }
    }

    private func writeVideo(_ frame: ARFrame) throws {
        guard let url = recordingURL else { return }
        if writer == nil {
            let created = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let buffer = frame.capturedImage
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
            ])
            input.expectsMediaDataInRealTime = true
            input.transform = CGAffineTransform(rotationAngle: .pi/2)
            guard created.canAdd(input) else { throw CaptureError.encoder }
            created.add(input)
            let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                                CVPixelBufferGetPixelFormatType(buffer)])
            guard created.startWriting() else { throw created.error ?? CaptureError.encoder }
            created.startSession(atSourceTime: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000))
            writer = created; videoInput = input; adaptor = pixels
            firstVideoTimestamp = frame.timestamp
        }
        guard writer?.status == .writing else { throw writer?.error ?? CaptureError.encoder }
        if videoInput?.isReadyForMoreMediaData == true {
            guard adaptor?.append(frame.capturedImage,
                withPresentationTime: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)) == true
            else { throw writer?.error ?? CaptureError.encoder }
            videoFrames += 1
        }
    }

    private func finish(_ result: @escaping FlutterResult) {
        guard let url = recordingURL else { reply(result, nil); return }
        let activeWriter = writer
        let first = firstVideoTimestamp
        let frames = videoFrames
        recordingURL = nil
        videoInput?.markAsFinished()
        writer = nil; videoInput = nil; adaptor = nil
        guard let activeWriter = activeWriter, frames > 0 else {
            reply(result, FlutterError(code: "empty_video", message: "No video frames were captured.", details: nil))
            return
        }
        activeWriter.finishWriting {
            if activeWriter.status == .completed {
                self.reply(result, ["path": url.path, "videoStartTimestamp": first ?? 0,
                    "videoFrameCount": frames, "timeline": "video PTS = ARFrame timestamp - videoStartTimestamp"])
            } else {
                self.reply(result, FlutterError(code: "encode_failed", message: "Video could not be finalised.", details: nil))
            }
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !paused else { return }
        do { try writeVideo(frame) }
        catch { emit(["error": "Video recording was interrupted. Finish this capture and retry."]) }
        guard frame.timestamp-lastMappingTimestamp >= 0.25 else { return }
        lastMappingTimestamp = frame.timestamp
        let camera = frame.camera
        let tracking: Bool
        if case .normal = camera.trackingState { tracking = true } else { tracking = false }
        let matrix = camera.transform
        let pose = (0..<4).flatMap { col in (0..<4).map { row in Double(matrix[col][row]) } }
        let intr = camera.intrinsics
        let resolution = camera.imageResolution
        let k = [Double(intr[0][0])*256/Double(resolution.width),
                 Double(intr[1][1])*256/Double(resolution.height),
                 Double(intr[2][0])*256/Double(resolution.width),
                 Double(intr[2][1])*256/Double(resolution.height)]
        let inverse = simd_inverse(matrix)
        var points: [Double] = []
        var anchors: [Double] = []
        if let features = frame.rawFeaturePoints {
            for point in features.points.prefix(2000) {
                points.append(contentsOf: [Double(point.x),Double(point.y),Double(point.z)])
                let local = inverse * SIMD4<Float>(point.x,point.y,point.z,1)
                let depth = -Double(local.z)
                if depth >= 0.25 && depth <= 8 {
                    let u = k[0]*Double(local.x)/depth+k[2]
                    let v = k[1]*(-Double(local.y))/depth+k[3]
                    if u >= 0 && u < 256 && v >= 0 && v < 256 {
                        anchors.append(contentsOf: [u,v,depth])
                    }
                }
            }
        }
        var event: [String: Any] = ["timestamp": frame.timestamp, "tracking": tracking,
            "pose": pose, "intrinsics": k, "points": points, "anchors": anchors]
        if let rgb = rgb256(frame.capturedImage) { event["rgb"] = FlutterStandardTypedData(bytes: rgb) }
        emit(event)
    }
    public func session(_ session: ARSession, didFailWithError error: Error) {
        emit(["error": "Camera tracking failed. Check camera access and retry."])
    }
    public func sessionWasInterrupted(_ session: ARSession) {
        emit(["error": "Camera tracking was interrupted. Finish this capture and retry."])
    }
    private func rgb256(_ buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer,0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer,1) else { return nil }
        let yy = yBase.assumingMemoryBound(to: UInt8.self)
        let uv = uvBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer,1)
        let fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var bytes = [UInt8](repeating: 0, count: 256*256*3)
        func byte(_ x: Double) -> UInt8 { UInt8(max(0,min(255,x.rounded()))) }
        for v in 0..<256 { for u in 0..<256 {
            let x = u*width/256, y = v*height/256
            let rawY = Double(yy[y*yStride+x])
            let luma = fullRange ? rawY : (rawY-16)*255/219
            let offset = (y/2)*uvStride+(x/2)*2
            let cb = Double(uv[offset])-128, cr = Double(uv[offset+1])-128
            let target = (v*256+u)*3
            bytes[target] = byte(luma+1.402*cr)
            bytes[target+1] = byte(luma-0.344136*cb-0.714136*cr)
            bytes[target+2] = byte(luma+1.772*cb)
        }}
        return Data(bytes)
    }
}

private enum CaptureError: Error {
    case unsupported, permission, busy, path, encoder
}
private class PreviewFactory: NSObject, FlutterPlatformViewFactory {
    let session: ARSession
    init(session: ARSession) { self.session = session }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        Preview(frame: frame, session: session)
    }
}
private class Preview: NSObject, FlutterPlatformView {
    let scene: ARSCNView
    init(frame: CGRect, session: ARSession) {
        scene = ARSCNView(frame: frame)
        scene.session = session
        scene.scene = SCNScene()
        scene.automaticallyUpdatesLighting = true
        super.init()
    }
    func view() -> UIView { scene }
}
