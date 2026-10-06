@preconcurrency import AVFoundation

/// Writes video frames (screen or camera), the computer's sound and the microphone into one .mov as they arrive.
/// Pausing cuts the gap out: anything captured while paused is dropped, and everything after
/// is pulled back by the time spent paused, so the file plays straight through.
/// Only ever used from one serial queue (the recorder's sample queue).
final class TakeWriter: @unchecked Sendable {
    enum Source { case video, computerAudio, microphone }

    /// Called once, on the sample queue, if the file can't be written any more.
    var onFailure: (() -> Void)?

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let computerAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false
    private var finished = false
    private var failed = false
    private var sessionStart = CMTime.invalid
    private var pauses: [(start: CMTime, end: CMTime)] = []   // in capture time
    private var pausedSince: CMTime?
    private var latest = CMTime.invalid                     // newest capture timestamp seen
    private var onHostClock: Bool?                          // are capture timestamps on the Mac's clock?
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.invalid              // in file time

    init(url: URL, width: Int, height: Int, frameRate: Int = 30, computerAudio: Bool, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // H.264 plays everywhere; beyond 4K (a 5K display, say) it can't, so HEVC.
        let codec: AVVideoCodecType = max(width, height) > 4096 || width * height > 4096 * 2304 ? .hevc : .h264
        // About 0.15 bits per pixel per frame: roughly 18 Mbps for a 2560x1600 screen at 30 fps (37 at 60),
        // 10 Mbps for 1080p. The ceiling rises for 60 fps.
        let ceiling: Double = frameRate > 30 ? 45_000_000 : 30_000_000
        let bitrate = min(max(Double(width * height * frameRate) * 0.15, 10_000_000), ceiling)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,   // a keyframe every 2 s, so scrubbing and Photos edits stay smooth
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        self.computerAudio = computerAudio ? Self.aac(bitrate: 256_000) : nil
        self.microphone = microphone ? Self.aac(bitrate: 256_000) : nil

        for input in [video, self.computerAudio, self.microphone].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? SaveError.nothingRecorded }
    }

    private static func aac(bitrate: Int) -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrate,
        ])
    }

    func append(_ sample: CMSampleBuffer, from source: Source) {
        let time = sample.presentationTimeStamp
        guard time.isValid, !finished, !failed else { return }
        if onHostClock == nil {
            onHostClock = abs((CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds) < 2
        }
        if !latest.isValid || time > latest { latest = time }

        // Captured while paused (including stragglers that arrive just after resuming): leave it out.
        if let since = pausedSince, time >= since { return }
        if pauses.contains(where: { time >= $0.start && time < $0.end }) { return }
        let offset = pausedTotal(before: time)
        let fileTime = time - offset

        if !started {
            guard source == .video else { return }   // the file starts on the first picture
            writer.startSession(atSourceTime: fileTime)
            sessionStart = fileTime
            started = true
        }
        guard fileTime >= sessionStart else { return }

        let input: AVAssetWriterInput? = switch source {
        case .video: video
        case .computerAudio: computerAudio
        case .microphone: microphone
        }
        // Real time: if the encoder is busy, drop this one rather than hold up the capture.
        guard let input, input.isReadyForMoreMediaData, let shifted = sample.shifted(back: offset) else { return }
        if !input.append(shifted) {
            failed = true
            onFailure?()
            return
        }
        if source == .video {
            lastFrame = shifted
            lastFrameTime = fileTime
        }
    }

    func pause() {
        guard pausedSince == nil, now().isValid else { return }
        pausedSince = now()
    }

    func resume() {
        guard let since = pausedSince else { return }
        pauses.append((since, max(now(), since)))
        pausedSince = nil
    }

    /// Finishes the file. `done` gets nil on success.
    func finish(_ done: @escaping @Sendable (Error?) -> Void) {
        finished = true
        guard started else {
            writer.cancelWriting()
            done(SaveError.nothingRecorded)
            return
        }
        let captureEnd = pausedSince ?? now()
        let end = max(captureEnd - pausedTotal(before: captureEnd), lastFrameTime)

        // A still screen sends no new frames, so hold the last picture until the very end.
        if let lastFrame, end - lastFrameTime > CMTime(value: 1, timescale: 30), video.isReadyForMoreMediaData,
           let held = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [
               CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)]) {
            video.append(held)
        }
        lastFrame = nil
        video.markAsFinished()
        computerAudio?.markAsFinished()
        microphone?.markAsFinished()
        writer.endSession(atSourceTime: end)
        nonisolated(unsafe) let writer = writer   // only read again once it has finished
        writer.finishWriting {
            done(writer.status == .completed ? nil : writer.error ?? SaveError.nothingRecorded)
        }
    }

    /// The Mac's clock if the capture timestamps use it (they should), otherwise the newest timestamp seen.
    private func now() -> CMTime {
        onHostClock == true ? CMClockGetTime(CMClockGetHostTimeClock()) : latest
    }

    private func pausedTotal(before time: CMTime) -> CMTime {
        pauses.filter { $0.end <= time }.reduce(.zero) { $0 + ($1.end - $1.start) }
    }
}

private extension CMSampleBuffer {
    /// A copy with every timestamp moved earlier by `offset`.
    func shifted(back offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return self }
        guard var timing = try? sampleTimingInfos() else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        return try? CMSampleBuffer(copying: self, withNewTiming: timing)
    }
}
