import Foundation
import Photos

/// Keeps Photos in step with ~/Movies/Take: when a recording file is deleted or moved to the Bin,
/// the video Take put into Photos for it is deleted too. Only videos Take itself added (listed in
/// its own small record) are ever touched. macOS always asks before Photos deletes anything.
@MainActor
final class PhotosSync {
    static let shared = PhotosSync()

    private struct Link: Codable {
        var file: String        // the file's name in ~/Movies/Take, for reading the record by eye
        var asset: String       // Photos' identifier for the video Take created
        var bookmark: Data      // follows the file through renames and moves
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?

    /// ~/Library/Application Support/Take/photos.json
    private static let record: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Take", isDirectory: true).appendingPathComponent("photos.json")
    }()

    /// Called after a video is saved to Photos.
    func remember(file: URL, asset: String) {
        guard let bookmark = try? file.bookmarkData() else { return }
        var links = load()
        links.append(Link(file: file.lastPathComponent, asset: asset, bookmark: bookmark))
        save(links)
    }

    /// Names of the recordings currently in Photos, from the record. If a video has since been
    /// deleted in Photos itself, its entry is dropped, so it shows as not in Photos again.
    func filesInPhotos() -> Set<String> {
        var links = load()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if !links.isEmpty, status == .authorized || status == .limited {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: links.map(\.asset), options: nil)
            var present = Set<String>()
            assets.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            let kept = links.filter { present.contains($0.asset) }
            if kept.count != links.count {
                links = kept
                save(links)
            }
        }
        return Set(links.map(\.file))
    }

    /// Watches the folder from launch. Also checks once shortly after launch, for files deleted while Take was closed.
    func start() {
        watch()
        scheduleCheck(after: 5)
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.createDirectory(at: Saver.folder, withIntermediateDirectories: true)
        let descriptor = open(Saver.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.watcher else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    // The folder itself went away or was renamed: start again on a fresh one.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self.watch() } }
                    return
                }
                self.scheduleCheck(after: 1.5)   // let Finder finish moving things first
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scheduleCheck(after seconds: Double) {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in await PhotosSync.shared.check() } }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func check() async {
        let links = load()
        defer { Recordings.shared.refresh() }   // the folder changed, so the menu's list may have too
        // Only with something to look after and Photos access he has already given. Never asks.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !links.isEmpty, status == .authorized || status == .limited,
              FileManager.default.fileExists(atPath: Saver.folder.path) else { return }
        var kept: [Link] = [], gone: [Link] = []
        for var link in links {
            if let current = Self.locate(link) {
                link.file = current.lastPathComponent
                kept.append(link)
            } else {
                gone.append(link)
            }
        }
        guard !gone.isEmpty else {
            save(kept)
            return
        }
        // Forget them first, so a "Don't Allow" isn't asked again on the next change.
        save(kept)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: gone.map(\.asset), options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }

    /// Where the recording is now, or nil if it has been deleted or is in the Bin.
    /// Moved somewhere else on the Mac still counts as kept.
    private static func locate(_ link: Link) -> URL? {
        let original = Saver.folder.appendingPathComponent(link.file)
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: link.bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path),
              !url.path.contains("/.Trash/") else {
            // Belt and braces: a file still sitting under its old name is never treated as deleted.
            return FileManager.default.fileExists(atPath: original.path) ? original : nil
        }
        return url
    }

    private func load() -> [Link] {
        guard let data = try? Data(contentsOf: Self.record) else { return [] }
        return (try? JSONDecoder().decode([Link].self, from: data)) ?? []
    }

    private func save(_ links: [Link]) {
        try? FileManager.default.createDirectory(at: Self.record.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(links).write(to: Self.record, options: .atomic)
    }
}
