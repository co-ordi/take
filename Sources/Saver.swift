import AppKit
@preconcurrency import AVFoundation
import Photos
import UserNotifications

/// Everything after the stop: one clean file in ~/Movies/Take and a notification. Photos is on demand:
/// "Add to Photos" in the menu's Recordings list or on the notification.
@MainActor
enum Saver {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Take", isDirectory: true)

    /// Where the recorder writes while recording. Hidden, and in the same folder so the final move is instant.
    static func newWorkingFile() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".recording-\(UUID().uuidString).mov")
    }

    /// Finishes the file in ~/Movies/Take and says so. Returns where it is.
    @discardableResult
    static func save(_ working: URL, recordedAt date: Date, cleanVoice: Bool = false) async throws -> URL {
        guard FileManager.default.fileExists(atPath: working.path) else { throw SaveError.nothingRecorded }
        let final = finalURL(for: date)
        do {
            try await AudioMixdown.run(working, to: final, cleanVoice: cleanVoice)
            try? FileManager.default.removeItem(at: working)
        } catch {
            // Mixdown is a nicety. If it can't run, keep the original file as it is.
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: working, to: final)
        }
        let name = final.deletingPathExtension().lastPathComponent
        if UserDefaults.standard.bool(forKey: Prefs.addToPhotos), await addToPhotos(final) {
            notify("Saved to Photos", "\(name) is in Photos and in Movies > Take.", opens: final.path)
        } else {
            notify("Saved", "\(name) is in Movies > Take.", opens: final.path, offerPhotosFor: final)
        }
        return final
    }

    /// Asks for Photos access, but only if macOS hasn't asked before. Called only when he has chosen
    /// Photos: Add to Photos, or switching on "Add new recordings to Photos". True if Take may add.
    static func askForPhotos() async -> Bool {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return Permissions.canSaveToPhotos
    }

    /// Copies a recording into Photos (asking for access the first time) and remembers which Photos
    /// video it became, so deleting the file later removes it from Photos too.
    static func addToPhotos(_ file: URL) async -> Bool {
        guard await askForPhotos() else {
            notify("Photos access is off", "Turn it on in System Settings > Privacy & Security > Photos.")
            return false
        }
        do {
            let created = CreatedAsset()
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.lastPathComponent
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: file, options: options)
                created.identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
            if let identifier = created.identifier { PhotosSync.shared.remember(file: file, asset: identifier) }
            return true
        } catch {
            notify("Photos wouldn't take that one", error.localizedDescription)
            return false
        }
    }

    /// "Take 2026-10-05 at 14.03.22.mov", like the system's own screen recordings.
    private static func finalURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Take \(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(base).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).mov")
            n += 1
        }
        return url
    }

    // MARK: Notifications

    private static let notificationDelegate = NotificationDelegate()
    fileprivate static let addToPhotosAction = "addToPhotos"
    private static let savedCategory = "saved"

    static func prepareNotifications() {
        let centre = UNUserNotificationCenter.current()
        centre.delegate = notificationDelegate
        let add = UNNotificationAction(identifier: addToPhotosAction, title: "Add to Photos", options: [])
        centre.setNotificationCategories([UNNotificationCategory(identifier: savedCategory, actions: [add],
                                                                 intentIdentifiers: [], options: [])])
        centre.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// `opens` is a file path to reveal in Finder when the notification is clicked. With `offerPhotosFor`,
    /// the notification carries an "Add to Photos" button for that file.
    static func notify(_ title: String, _ body: String, opens: String? = nil, offerPhotosFor file: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var info: [String: String] = [:]
        if let opens { info["opens"] = opens }
        if let file {
            info["file"] = file.path
            content.categoryIdentifier = savedCategory
        }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    fileprivate static func respond(action: String, info: [AnyHashable: Any]) {
        if action == addToPhotosAction, let path = info["file"] as? String {
            Task { await Recordings.shared.addToPhotos(URL(fileURLWithPath: path)) }
        } else if let path = info["opens"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Saver.respond(action: action, info: info) }
            completionHandler()
        }
    }
}

/// Carries the new video's Photos identifier out of the change block.
private final class CreatedAsset: @unchecked Sendable {
    var identifier: String?
}

enum SaveError: LocalizedError {
    case nothingRecorded
    var errorDescription: String? { "Nothing was recorded." }
}

/// ScreenCaptureKit writes the computer's sound and the microphone as two separate audio tracks.
/// Some players and editors only play or keep the first one, so this copies the video untouched
/// and folds every audio track into a single one that works everywhere. With cleanVoice, the microphone
/// (always the last audio track TakeWriter adds) goes through voice isolation first.
enum AudioMixdown {
    static func run(_ source: URL, to destination: URL, cleanVoice: Bool = false) async throws {
        let asset = AVURLAsset(url: source)
        var audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw SaveError.nothingRecorded }
        var audioAsset: AVAsset = asset
        var voice: URL?
        defer { if let voice { try? FileManager.default.removeItem(at: voice) } }
        if cleanVoice, let microphone = audioTracks.last {
            do {
                let cleaned = try await VoiceIsolation.clean(microphone, in: asset)
                voice = cleaned
                let mix = AVMutableComposition()
                for track in audioTracks.dropLast() {
                    let range = try await track.load(.timeRange)
                    try mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                        .insertTimeRange(range, of: track, at: range.start)
                }
                let cleanedAsset = AVURLAsset(url: cleaned)
                guard let cleanedTrack = try await cleanedAsset.loadTracks(withMediaType: .audio).first else {
                    throw SaveError.nothingRecorded
                }
                let length = min(try await cleanedAsset.load(.duration), try await asset.load(.duration))
                try mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                    .insertTimeRange(CMTimeRange(start: .zero, duration: length), of: cleanedTrack, at: .zero)
                audioAsset = mix
                audioTracks = try await mix.loadTracks(withMediaType: .audio)
            } catch {
                // Voice isolation is a nicety too: if it can't run, the take keeps its own microphone.
            }
        }
        guard audioTracks.count > 1 || audioAsset !== asset else {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }

        let reader = try AVAssetReader(asset: asset)
        let audioReader = audioAsset === asset ? reader : try AVAssetReader(asset: audioAsset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(videoOut)
        audioReader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                         sourceFormatHint: try await video.load(.formatDescriptions).first)
        videoIn.transform = try await video.load(.preferredTransform)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading(), audioReader === reader || audioReader.startReading(), writer.startWriting() else {
            throw reader.error ?? audioReader.error ?? writer.error ?? SaveError.nothingRecorded
        }
        writer.startSession(atSourceTime: .zero)

        async let videoDone: Void = copy(videoOut, into: videoIn, on: DispatchQueue(label: "com.coordi.take.mix.video"))
        async let audioDone: Void = copy(audioOut, into: audioIn, on: DispatchQueue(label: "com.coordi.take.mix.audio"))
        _ = await (videoDone, audioDone)

        if reader.status == .failed || audioReader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? audioReader.error ?? writer.error ?? SaveError.nothingRecorded
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? SaveError.nothingRecorded }
    }

    private static func copy(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, on queue: DispatchQueue) async {
        nonisolated(unsafe) let output = output, input = input   // only ever touched on `queue`
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                while !done && input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        done = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
