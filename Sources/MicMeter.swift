@preconcurrency import AVFoundation
import Combine

/// A live microphone level for the popover, so you can see you're being picked up before recording.
/// Listens to the same microphone the recording will use, and only while the popover is open.
@MainActor
final class MicMeter: ObservableObject {
    static let shared = MicMeter()
    @Published private(set) var level: Double = 0      // 0 silent ... 1 loud

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var poll: Timer?
    private let sink = SilentSink()
    private let queue = DispatchQueue(label: "com.coordi.take.meter")

    func start() {
        guard session == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,   // never prompts from here
              let device = Microphone.preferred(),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(sink, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.output = output
        queue.async { session.startRunning() }

        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        RunLoop.main.add(poll!, forMode: .common)
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        if let session { queue.async { session.stopRunning() } }
        session = nil
        output = nil
        level = 0
    }

    private func read() {
        let channels = output?.connections.first?.audioChannels ?? []
        guard let loudest = channels.map(\.averagePowerLevel).max() else { return }
        // -50 dB and below reads as silence, 0 dB as full.
        let target = Double(min(max((loudest + 50) / 50, 0), 1))
        level = target > level ? target : level * 0.75 + target * 0.25   // quick up, gentle down
    }
}

/// Audio has to flow somewhere for the levels to update; this just lets it go.
private final class SilentSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {}
