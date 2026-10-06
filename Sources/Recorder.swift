import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Captures the main display (or a 9:16 slice of it), the computer's sound and the microphone
/// with ScreenCaptureKit, and hands everything to TakeWriter.
@MainActor
final class Recorder: NSObject {
    struct Options {
        var microphone: Bool
        var cleanScreen: Bool          // leave notifications and desktop icons out of the video
        var region: CGRect?            // a vertical slice, in screen coordinates; nil records the whole display
        var keepVisible: NSWindow?     // the camera bubble: the one Take window that should be recorded
        var frameRate = 30             // 30 or 60
    }

    var onUnexpectedStop: (() -> Void)?

    private var stream: SCStream?
    private var writer: TakeWriter?
    private var display: SCDisplay?
    private var options: Options?
    private var appliedFilter = ""
    private var filterRefresh: Timer?
    private let output = StreamOutput()
    private let samples = DispatchQueue(label: "com.coordi.take.samples")

    private static let notificationCentre = "com.apple.notificationcenterui"
    private static let finder = "com.apple.finder"

    func start(_ options: Options, writingTo url: URL) async throws {
        self.options = options
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { throw RecorderError.noDisplay }
        let (filter, filterKey) = makeFilter(content, display)

        let config = SCStreamConfiguration()
        var width: Int, height: Int
        if let region = options.region, let screen = NSScreen.screens.first {
            // ScreenCaptureKit measures from the display's top-left; AppKit from the bottom-left.
            config.sourceRect = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                                       width: region.width, height: region.height)
            (width, height) = (1080, 1920)                          // the usual size for Shorts and Reels
        } else {
            let scale = CGFloat(filter.pointPixelScale)             // native Retina pixels
            width = Int(filter.contentRect.width * scale) & ~1
            height = Int(filter.contentRect.height * scale) & ~1
        }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        config.queueDepth = 6
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = true                                  // the computer's own sound, always on
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        if options.microphone { config.microphoneCaptureDeviceID = Microphone.preferred()?.uniqueID }

        let writer = try TakeWriter(url: url, width: width, height: height, frameRate: options.frameRate,
                                    computerAudio: true, microphone: options.microphone)
        writer.onFailure = { [weak self] in Task { @MainActor in self?.onUnexpectedStop?() } }
        output.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: samples)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: samples)
        if options.microphone { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: samples) }
        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        self.display = display
        appliedFilter = filterKey
        if options.cleanScreen { keepFilterCurrent() }
    }

    func pause() {
        let writer = writer
        samples.async { writer?.pause() }
    }

    func resume() {
        let writer = writer
        samples.async { writer?.resume() }
    }

    /// Stops capture and waits until the file is fully written. Returns an error if the recording broke.
    func stop() async -> Error? {
        filterRefresh?.invalidate()
        filterRefresh = nil
        guard let stream, let writer else { return nil }
        self.stream = nil
        self.writer = nil
        try? await stream.stopCapture()
        return await withCheckedContinuation { continuation in
            samples.async { writer.finish { continuation.resume(returning: $0) } }
        }
    }

    // MARK: What's in the picture

    /// Take's own windows (popover, notes, the 9:16 frame) are always left out, except the camera bubble.
    /// With a clean screen, Notification Centre is left out too, and Finder's desktop icons,
    /// but not Finder's ordinary windows.
    private func makeFilter(_ content: SCShareableContent, _ display: SCDisplay) -> (SCContentFilter, String) {
        let me = ProcessInfo.processInfo.processIdentifier
        let clean = options?.cleanScreen == true
        let bubbleID = options?.keepVisible.flatMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }

        let hidden = content.applications.filter {
            $0.processID == me || (clean && [Self.notificationCentre, Self.finder].contains($0.bundleIdentifier))
        }
        let shown = content.windows.filter { window in
            if window.windowID == bubbleID { return true }
            // Desktop icons sit below every normal window (a negative layer); Finder's windows sit at 0 and up.
            return clean && window.owningApplication?.bundleIdentifier == Self.finder && window.windowLayer >= 0
        }
        let key = (hidden.map { "a\($0.processID)" } + shown.map { "w\($0.windowID)" }).sorted().joined(separator: ",")
        return (SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: shown), key)
    }

    /// Finder windows opened mid-recording need adding to the "keep" list, so check every couple of seconds.
    private func keepFilterCurrent() {
        filterRefresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFilter() }
        }
    }

    private func refreshFilter() {
        guard let stream, let display else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  self.stream === stream else { return }
            let (filter, key) = makeFilter(content, display)
            guard key != appliedFilter else { return }
            appliedFilter = key
            try? await stream.updateContentFilter(filter)
        }
    }
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onUnexpectedStop?() }
    }
}

/// Receives ScreenCaptureKit's samples on the sample queue and passes the useful ones to the writer.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    var writer: TakeWriter?     // set before capture starts

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let writer else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit also sends "nothing changed" buffers with no picture. Only whole frames go in.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                                as? [[SCStreamFrameInfo: Any]])?.first,
                  let status = info[.status] as? Int,
                  SCFrameStatus(rawValue: status) == .complete else { return }
            writer.append(sample, from: .video)
        case .audio:
            writer.append(sample, from: .computerAudio)
        case .microphone:
            writer.append(sample, from: .microphone)
        @unknown default:
            break
        }
    }
}

enum Microphone {
    /// The system default input, unless that's a virtual device (BlackHole and friends),
    /// in which case the Mac's own microphone. Never changes any sound settings.
    static func preferred() -> AVCaptureDevice? {
        guard let preferred = AVCaptureDevice.default(for: .audio) else { return nil }
        guard UInt32(bitPattern: preferred.transportType) == kAudioDeviceTransportTypeVirtual else { return preferred }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .first { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn } ?? preferred
    }
}

enum RecorderError: LocalizedError {
    case noDisplay, noCamera
    var errorDescription: String? {
        switch self {
        case .noDisplay: "Take couldn't find a display to record."
        case .noCamera: "Take couldn't start the camera."
        }
    }
}
