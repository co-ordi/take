@preconcurrency import AVFoundation
import Foundation

/// The latest few recordings in ~/Movies/Take, for the menu's Recordings section.
@MainActor
final class Recordings: ObservableObject {
    static let shared = Recordings()

    struct Item: Identifiable, Equatable {
        let url: URL
        let created: Date
        var length: TimeInterval?
        var inPhotos: Bool
        var id: URL { url }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var adding: Set<URL> = []
    @Published var photosNote: String?   // shown under the toggle if Photos access was refused
    private var lengths: [URL: TimeInterval] = [:]
    private static let shown = 5

    /// Re-reads the folder (newest first) and which files are in Photos.
    func refresh() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Saver.folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let inPhotos = PhotosSync.shared.filesInPhotos()
        items = files
            .filter { $0.pathExtension.lowercased() == "mov" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return Item(url: url, created: created, length: lengths[url], inPhotos: inPhotos.contains(url.lastPathComponent))
            }
            .sorted { $0.created > $1.created }
            .prefix(Self.shown)
            .map { $0 }
        for item in items where item.length == nil { measure(item.url) }
    }

    /// Switching on "Add new recordings to Photos" is when Photos access is asked for. If it's
    /// refused, the switch goes back off with a short note.
    func autoAddSwitched(_ on: Bool) async {
        photosNote = nil
        guard on else { return }
        if await !Saver.askForPhotos() {
            UserDefaults.standard.set(false, forKey: Prefs.addToPhotos)
            photosNote = "Photos access is off, so it's switched back off. Allow Take in System Settings > Privacy & Security > Photos."
        }
    }

    func addToPhotos(_ url: URL) async {
        guard !adding.contains(url) else { return }
        adding.insert(url)
        _ = await Saver.addToPhotos(url)
        adding.remove(url)
        refresh()
    }

    private func measure(_ url: URL) {
        Task {
            guard let length = try? await AVURLAsset(url: url).load(.duration).seconds, length.isFinite else { return }
            lengths[url] = length
            if let index = items.firstIndex(where: { $0.url == url }) { items[index].length = length }
        }
    }
}
