import AppKit
@preconcurrency import AVFoundation
import CoreImage
import MetalKit

/// The floating camera window. It's a real window on screen, so whatever it shows ends up in the video.
/// Shown while the Camera bubble switch is on; size, shape, mirror, border and look update live.
@MainActor
final class CameraBubble: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private var feed: CameraFeed?
    private var cameraView: CameraView?
    private var ring: NSView?
    private var awake: NSObjectProtocol?     // keeps App Nap from slowing the camera while the bubble is up
    private let settings = CameraSettings.shared
    private static let centreKey = "cameraBubbleCentre"
    private static let margin: CGFloat = 32

    override init() {
        super.init()
        settings.observe { [weak self] in self?.applySettings() }
    }

    func show() {
        guard window == nil,
              let camera = Self.builtInCamera(),
              let feed = CameraFeed(camera: camera),
              let cameraView = CameraView.make() else { return }

        let size = settings.shape.points(for: settings.size)
        let panel = BubblePanel(contentRect: Self.startingFrame(size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Overlay.configure(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        // A clipping view gives the shape; the camera draws inside it and a thin ring sits on top.
        let clip = NSView(frame: NSRect(origin: .zero, size: size))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.layer?.backgroundColor = NSColor.black.cgColor
        cameraView.frame = clip.bounds
        cameraView.autoresizingMask = [.width, .height]
        clip.addSubview(cameraView)

        let ring = NSView(frame: clip.bounds)   // also what you grab to drag the bubble
        ring.wantsLayer = true
        ring.autoresizingMask = [.width, .height]
        ring.layer?.cornerCurve = .continuous
        ring.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        clip.addSubview(ring)
        panel.contentView = clip
        panel.delegate = self

        feed.onFrame = { [weak cameraView] image in cameraView?.show(image) }
        self.window = panel
        self.feed = feed
        self.cameraView = cameraView
        self.ring = ring
        applySettings()
        panel.orderFrontRegardless()
        feed.start()
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                      reason: "Camera bubble on screen")
    }

    func hide() {
        guard let window else { return }
        saveCentre()
        window.delegate = nil
        window.orderOut(nil)
        feed?.stop()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        self.window = nil
        feed = nil
        cameraView = nil
        ring = nil
    }

    func windowDidMove(_ notification: Notification) { saveCentre() }

    private func applySettings() {
        guard let window, let clip = window.contentView, let cameraView, let ring else { return }
        let size = settings.shape.points(for: settings.size)
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)   // resizing grows from the middle
        let frame = Self.keepOnScreen(NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                             width: size.width, height: size.height))
        if frame != window.frame { window.setFrame(frame, display: true) }

        let radius = settings.shape.cornerRadius(for: size)
        clip.layer?.cornerRadius = radius
        ring.layer?.cornerRadius = radius
        ring.layer?.borderWidth = settings.border ? 1.5 : 0
        window.invalidateShadow()

        cameraView.mirrored = settings.mirrored
        cameraView.look = settings.look
        cameraView.needsDisplay = true
    }

    private func saveCentre() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.midX, y: window.frame.midY)),
                                  forKey: Self.centreKey)
    }

    /// Wherever he last left it, if that's still on the recorded display. Otherwise bottom-right.
    private static func startingFrame(size: CGSize) -> NSRect {
        let area = recordedArea()
        var centre = NSPoint(x: area.maxX - margin - size.width / 2, y: area.minY + margin + size.height / 2)
        if let saved = UserDefaults.standard.string(forKey: centreKey) {
            let point = NSPointFromString(saved)
            if area.contains(point) { centre = point }
        }
        return keepOnScreen(NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                   width: size.width, height: size.height))
    }

    private static func keepOnScreen(_ frame: NSRect) -> NSRect {
        let area = recordedArea().insetBy(dx: 8, dy: 8)
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }

    /// The main display, which is the one Take records.
    private static func recordedArea() -> NSRect {
        NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The Mac's own camera first, so an iPhone nearby (Continuity Camera) doesn't take over.
    static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

/// Picks the camera's sharpest format (its largest up to 1920x1080 that can do 30 fps; 1280x720 on a
/// MacBook's FaceTime HD camera) and holds it at a steady 30 fps, so it doesn't slow down in dim light.
/// Call after adding the camera to a session, inside begin/commitConfiguration.
enum CameraFormat {
    static func useBest(_ camera: AVCaptureDevice) {
        let thirty = CMTime(value: 1, timescale: 30)
        func pixels(_ format: AVCaptureDevice.Format) -> Int32 {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width <= 1920 && size.height <= 1080 ? size.width * size.height : 0
        }
        let candidates = camera.formats.filter { format in
            pixels(format) > 0 && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let best = candidates.max(by: { pixels($0) < pixels($1) }),
              (try? camera.lockForConfiguration()) != nil else { return }
        camera.activeFormat = best
        camera.activeVideoMinFrameDuration = thirty
        camera.activeVideoMaxFrameDuration = thirty
        camera.unlockForConfiguration()
    }
}

/// How Take's floating windows (bubble, notes, 9:16 frame, camera preview) sit on screen: above other
/// apps' windows, on every Space and over full-screen apps, left alone by app switching, Mission Control
/// and the window cycle, and never hidden when another app comes forward.
@MainActor
enum Overlay {
    static func configure(_ panel: NSPanel) {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
    }
}

/// Never takes focus when clicked or dragged, so the app being recorded keeps it.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Camera frames in, one CIImage at a time out on the main thread. If drawing falls behind,
/// it skips to the newest frame rather than queueing old ones.
private final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((CIImage) -> Void)?
    private let session = AVCaptureSession()
    private let frames = DispatchQueue(label: "com.coordi.take.camera.frames")
    private let control = DispatchQueue(label: "com.coordi.take.camera.control")
    private let lock = NSLock()
    private var newest: CIImage?

    init?(camera: AVCaptureDevice) {
        super.init()
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return nil }
        session.beginConfiguration()
        session.addInput(input)
        CameraFormat.useBest(camera)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(output)
        session.commitConfiguration()

        // If something interrupts the camera (another app grabbing it, a hiccup), pick straight back up.
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self, self.running else { return }
                self.control.async { if !self.session.isRunning { self.session.startRunning() } }
            }
        }
    }

    private var running = false

    func start() {
        running = true
        control.async { self.session.startRunning() }
    }

    func stop() {
        running = false
        control.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let alreadyQueued = newest != nil
        newest = CIImage(cvPixelBuffer: pixels)
        lock.unlock()
        if !alreadyQueued { DispatchQueue.main.async { self.deliver() } }
    }

    private func deliver() {
        lock.lock()
        let image = newest
        newest = nil
        lock.unlock()
        if let image { onFrame?(image) }
    }
}

/// Draws each camera frame with the current look, filling the view.
final class CameraView: MTKView, MTKViewDelegate {
    var mirrored = true
    var look = Look()
    private var latest: CIImage?
    private let commands: MTLCommandQueue
    private let context: CIContext

    static func make() -> CameraView? {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { return nil }
        return CameraView(device: device, commands: commands)
    }

    private init(device: MTLDevice, commands: MTLCommandQueue) {
        self.commands = commands
        context = CIContext(mtlCommandQueue: commands, options: [.cacheIntermediates: false, .name: "Take camera"])
        super.init(frame: .zero, device: device)
        framebufferOnly = false                      // Core Image writes straight into the drawable
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true                              // draw when a frame arrives, not on a timer
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func show(_ image: CIImage) {
        latest = image
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = drawableSize
        guard let latest, size.width > 0, size.height > 0,
              let drawable = currentDrawable, let buffer = commands.makeCommandBuffer() else { return }

        let image = look.apply(to: latest.filling(size, mirrored: mirrored))
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: colorPixelFormat, commandBuffer: buffer) { drawable.texture }
        destination.colorSpace = colorspace
        _ = try? context.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero)
        buffer.present(drawable)
        buffer.commit()
    }
}
