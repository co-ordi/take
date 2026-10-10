@preconcurrency import AVFoundation
import AudioToolbox

/// Apple's Voice Isolation (the AUSoundIsolation effect built into macOS) run over the microphone once a take
/// is saved, so room noise and hum drop away and the voice stays as it was. Only the microphone goes through
/// it: the effect would strip the computer's sound along with the noise.
enum VoiceIsolation {
    private static let sampleRate = 48_000.0
    private static let block: AVAudioFrameCount = 4_800   // frames per render, 0.1 s

    /// The cleaned microphone as a mono .caf in the temporary folder, running from the start of the recording
    /// so it lines up with the picture. The caller deletes it.
    static func clean(_ microphone: AVAssetTrack, in asset: AVAsset) async throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let reader = try AVAssetReader(asset: asset)
        let input = AVAssetReaderAudioMixOutput(audioTracks: [microphone], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(input)
        guard reader.startReading() else { throw reader.error ?? SaveError.nothingRecorded }

        let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
                              kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                              kAudioUnitScope_Global, 0, 100, 0)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        defer { engine.stop() }

        // The voice comes out late by the effect's own latency plus one block (measured on macOS 26:
        // 4440 + 4800 frames). Those first frames are dropped, and as much silence is fed in at
        // the end, so the cleaned voice is exactly as long as the original and stays in sync with the lips.
        let delay = Int((effect.auAudioUnit.latency * sampleRate).rounded()) + Int(block)
        var skip = delay
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-voice-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
        let kept = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!

        func render(_ frames: Int) throws {
            var left = frames
            while left > 0 {
                let n = AVAudioFrameCount(min(left, Int(block)))
                guard try engine.renderOffline(n, to: rendered) == .success else { throw SaveError.nothingRecorded }
                left -= Int(n)
                let dropped = min(skip, Int(rendered.frameLength))
                skip -= dropped
                let count = Int(rendered.frameLength) - dropped
                guard count > 0 else { continue }
                kept.frameLength = AVAudioFrameCount(count)
                kept.floatChannelData![0].update(from: rendered.floatChannelData![0] + dropped, count: count)
                try file.write(from: kept)
            }
        }

        while let sample = input.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            player.scheduleBuffer(buffer, completionHandler: nil)
            try render(frames)
        }
        if reader.status == .failed { throw reader.error ?? SaveError.nothingRecorded }

        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(delay))!
        silence.frameLength = AVAudioFrameCount(delay)
        silence.floatChannelData![0].update(repeating: 0, count: delay)
        player.scheduleBuffer(silence, completionHandler: nil)
        try render(delay)
        return url
    }
}
