import AppKit
@preconcurrency import AVFoundation
import CoreImage

/// "Camera only" recording: the camera, with Take's look and whatever macOS video effects are on
/// (Portrait, Studio Light, Background...), plus the microphone. No screen and no computer sound.
/// A preview window shows exactly what is being recorded.
@MainActor
final class CameraRecorder: NSObject, NSWindowDelegate {
    var onUnexpectedStop: (() -> Void)?

    private var session: AVCaptureSession?
    private var pipeline: CameraPipeline?
    private var microphoneAdded = false
    private var vertical = false
    private var recording = false
    private var panel: NSPanel?
    private var view: CameraView?
    private var closeButton: NSButton?
    private let queue = DispatchQueue(label: "com.coordi.take.cameraonly")
    private let settings = CameraSettings.shared
    private static let centreKey = "cameraPreviewCentre"

    override init() {
        super.init()
        settings.observe { [weak self] in self?.updateLook() }
    }

    /// Starts the camera and shows the preview (16:9 or 9:16). Does nothing if it's already showing that.
    func preview(vertical: Bool) {
        if session != nil, self.vertical == vertical {
            panel?.orderFrontRegardless()
            return
        }
        endPreview()
        guard let camera = CameraBubble.builtInCamera(),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        let size = vertical ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
        let pipeline = CameraPipeline(size: size)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        CameraFormat.useBest(camera)   // e.g. 1280x720 at 30 fps on a 720p FaceTime HD camera
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(pipeline, queue: queue)
        guard session.canAddOutput(video) else { return }
        session.addOutput(video)
        session.commitConfiguration()

        self.session = session
        self.pipeline = pipeline
        self.vertical = vertical
        microphoneAdded = false
        updateLook()
        showPanel(vertical: vertical)
        pipeline.onFrame = { [weak self] image in self?.view?.show(image) }
        queue.async { session.startRunning() }
    }

    /// Stops the camera and closes the preview.
    func endPreview() {
        guard !recording else { return }
        if let session { queue.async { session.stopRunning() } }
        session = nil
        pipeline = nil
        if let panel {
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.midX, y: panel.frame.midY)), forKey: Self.centreKey)
            panel.orderOut(nil)
        }
        panel = nil
        view = nil
    }

    /// Begins writing. The preview must already be running.
    func start(microphone: Bool, writingTo url: URL) throws {
        guard let session, let pipeline else { throw RecorderError.noCamera }
        if microphone, !microphoneAdded, let mic = Microphone.preferred(), let input = try? AVCaptureDeviceInput(device: mic) {
            // Added to the running session, so the picture carries on while the microphone joins.
            let audio = AVCaptureAudioDataOutput()
            audio.setSampleBufferDelegate(pipeline, queue: queue)
            session.beginConfiguration()
            if session.canAddInput(input), session.canAddOutput(audio) {
                session.addInput(input)
                session.addOutput(audio)
                microphoneAdded = true
            }
            session.commitConfiguration()
        }
        let writer = try TakeWriter(url: url, width: Int(pipeline.size.width), height: Int(pipeline.size.height),
                                    computerAudio: false, microphone: microphone && microphoneAdded)
        writer.onFailure = { [weak self] in Task { @MainActor in self?.onUnexpectedStop?() } }
        queue.async { pipeline.writer = writer }
        recording = true
        closeButton?.isHidden = true
    }

    func pause() {
        let pipeline = pipeline
        queue.async { pipeline?.writer?.pause() }
    }

    func resume() {
        let pipeline = pipeline
        queue.async { pipeline?.writer?.resume() }
    }

    /// Finishes the file, then turns the camera off and closes the preview.
    func stop() async -> Error? {
        guard recording, let pipeline else { return nil }
        let error: Error? = await withCheckedContinuation { continuation in
            queue.async {
                guard let writer = pipeline.writer else { return continuation.resume(returning: nil) }
                pipeline.writer = nil
                writer.finish { continuation.resume(returning: $0) }
            }
        }
        recording = false
        endPreview()
        return error
    }

    private func updateLook() {
        pipeline?.setLook(settings.look, mirrored: settings.mirrored)
    }

    // MARK: The preview window

    private func showPanel(vertical: Bool) {
        let size = vertical ? CGSize(width: 270, height: 480) : CGSize(width: 480, height: 270)
        let area = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var centre = NSPoint(x: area.midX, y: area.minY + 40 + size.height / 2)
        if let saved = UserDefaults.standard.string(forKey: Self.centreKey) {
            let point = NSPointFromString(saved)
            if area.contains(point) { centre = point }
        }
        var frame = NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, area.minX + 8), area.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, area.minY + 8), area.maxY - frame.height - 8)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Overlay.configure(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let clip = NSView(frame: NSRect(origin: .zero, size: size))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        if let view = CameraView.make() {
            view.frame = clip.bounds
            view.autoresizingMask = [.width, .height]
            view.look = Look()            // the frames arrive with the look and mirroring already applied
            view.mirrored = false
            clip.addSubview(view)
            self.view = view
        }
        let grab = NSView(frame: clip.bounds)   // on top, so the whole preview can be dragged
        grab.autoresizingMask = [.width, .height]
        clip.addSubview(grab)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close preview")!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .white.withAlphaComponent(0.85)
        close.toolTip = "Close the preview (turns the camera off)"
        close.frame = NSRect(x: size.width - 30, y: size.height - 30, width: 22, height: 22)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        clip.addSubview(close)
        closeButton = close

        panel.contentView = clip
        panel.orderFrontRegardless()
        self.panel = panel
    }

    @objc private func closeTapped() { endPreview() }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.midX, y: panel.frame.midY)), forKey: Self.centreKey)
    }
}

/// Runs on the capture queue: applies the look to each camera frame, renders it at the recording size,
/// hands it to the preview and (while recording) to the writer along with the microphone.
private final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let size: CGSize
    var writer: TakeWriter?                       // only touched on the capture queue
    var onFrame: ((CIImage) -> Void)?             // set on the main thread before frames flow

    private let lock = NSLock()
    private var look = Look()
    private var mirrored = true
    private var newest: CIImage?
    private var pool: CVPixelBufferPool?
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Take camera recording"])
    private let colourSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    init(size: CGSize) {
        self.size = size
        super.init()
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pool)
    }

    func setLook(_ look: Look, mirrored: Bool) {
        lock.lock()
        self.look = look
        self.mirrored = mirrored
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            writer?.append(sample, from: .microphone)
            return
        }
        guard let camera = CMSampleBufferGetImageBuffer(sample), let pool else { return }
        var rendered: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered)
        guard let rendered else { return }

        lock.lock()
        let look = look, mirrored = mirrored
        lock.unlock()
        let image = look.apply(to: Self.enlarged(CIImage(cvPixelBuffer: camera), to: size, mirrored: mirrored))
        context.render(image, to: rendered, bounds: CGRect(origin: .zero, size: size), colorSpace: colourSpace)
        CVBufferSetAttachment(rendered, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(rendered, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(rendered, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        // The preview gets the newest frame only; if drawing falls behind it skips rather than queues.
        lock.lock()
        let alreadyQueued = newest != nil
        newest = CIImage(cvPixelBuffer: rendered)
        lock.unlock()
        if !alreadyQueued { DispatchQueue.main.async { self.deliver() } }

        if let writer, let frame = Self.sample(rendered, at: sample.presentationTimeStamp) {
            writer.append(frame, from: .video)
        }
    }

    /// Scales the camera picture up to the recording size with Lanczos (inside `filling`), then, if it
    /// was enlarged (720p to 1080p), a light luminance sharpen so it looks clean rather than soft.
    private static func enlarged(_ frame: CIImage, to size: CGSize, mirrored: Bool) -> CIImage {
        let scaled = frame.filling(size, mirrored: mirrored)
        guard max(size.width / frame.extent.width, size.height / frame.extent.height) > 1.05 else { return scaled }
        return scaled.clampedToExtent()
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.3, kCIInputRadiusKey: 1.2])
            .cropped(to: scaled.extent)
    }

    private func deliver() {
        lock.lock()
        let image = newest
        newest = nil
        lock.unlock()
        if let image { onFrame?(image) }
    }

    private static func sample(_ pixels: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}
