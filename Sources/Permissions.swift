import AppKit
@preconcurrency import AVFoundation
import Photos
import UserNotifications

enum PermissionKind: CaseIterable, Identifiable {
    case screen, microphone, camera, notifications
    var id: Self { self }

    var title: String {
        switch self {
        case .screen: "Screen & audio recording"
        case .microphone: "Microphone"
        case .camera: "Camera (optional)"
        case .notifications: "Notifications (optional)"
        }
    }

    var why: String {
        switch self {
        case .screen: "Needed to record, including the computer's sound."
        case .microphone: "Your voice."
        case .camera: "Only for the camera bubble."
        case .notifications: "The \"Saved to Photos\" message."
        }
    }

    /// The exact page in System Settings.
    var settings: URL {
        let address = switch self {
        case .screen: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.coordi.take"
        }
        return URL(string: address)!
    }
}

enum PermissionStatus {
    case allowed, notYet, off

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .notYet: "Not yet"
        case .off: "Off in Settings"
        }
    }
}

/// Where each permission stands, and the one action that moves it forward: the system prompt
/// where macOS still allows one, otherwise the exact page in System Settings.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// Set once Take has asked for screen recording in this run. macOS only applies that switch
    /// after a relaunch, so from then on the set-up card offers "Restart Take".
    @Published private(set) var askedForScreen = false
    /// The card was opened from More > Permissions, so show it even with nothing missing.
    @Published var cardRequested = false

    private init() { refresh() }

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notYet }

    /// Something the current switches need is missing, so the set-up card shows by itself.
    /// Optional ones (and a Photos "no" he's already given) never force it open.
    var needsSetUp: Bool {
        let defaults = UserDefaults.standard
        let cameraOnly = defaults.string(forKey: Prefs.format) == RecordingFormat.cameraOnly.rawValue
        return (!cameraOnly && status(.screen) != .allowed)
            || (defaults.bool(forKey: Prefs.microphone) && status(.microphone) != .allowed)
            || ((cameraOnly || defaults.bool(forKey: Prefs.cameraBubble)) && status(.camera) != .allowed)
    }

    var showsCard: Bool { needsSetUp || cardRequested }
    var offerRestart: Bool { askedForScreen && status(.screen) != .allowed }

    func refresh() {
        statuses[.screen] = CGPreflightScreenCaptureAccess() ? .allowed : (askedForScreen ? .off : .notYet)
        statuses[.microphone] = Self.capture(.audio)
        statuses[.camera] = Self.capture(.video)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionStatus = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .notDetermined: .notYet
            default: .off
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Permissions.shared.statuses[.notifications] = status }
            }
        }
    }

    /// The row's button: "Allow" fires the system prompt, "Open Settings" goes to the exact page.
    func act(on kind: PermissionKind) async {
        switch kind {
        case .screen:
            askedForScreen = true
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(kind.settings) }
        case .microphone, .camera:
            let media: AVMediaType = kind == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            } else if status(kind) != .allowed {
                NSWorkspace.shared.open(kind.settings)
            }
        case .notifications:
            if status(kind) == .notYet {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            } else if status(kind) != .allowed {
                NSWorkspace.shared.open(kind.settings)
            }
        }
        refresh()
    }

    /// Steps through everything not yet asked. Screen recording goes last: it can mean a trip to
    /// System Settings and a restart, which would otherwise interrupt the other prompts.
    func allowAll() async {
        let camera = UserDefaults.standard.bool(forKey: Prefs.cameraBubble)
        for kind in [PermissionKind.microphone, .camera, .notifications] where status(kind) == .notYet {
            if kind == .camera && !camera { continue }   // only ask for the camera if the bubble is in use
            await act(on: kind)
        }
        if status(.screen) != .allowed { await act(on: .screen) }
    }

    /// Before a recording: asks for whatever the switches need. Returns the first one still missing.
    /// Camera-only recordings don't need screen recording.
    func readyToRecord(microphone: Bool, camera: Bool, screen: Bool) async -> PermissionKind? {
        if microphone {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { await act(on: .microphone) }
            if Self.capture(.audio) != .allowed { refresh(); return .microphone }
        }
        if camera {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { await act(on: .camera) }
            if Self.capture(.video) != .allowed { refresh(); return .camera }
        }
        if screen, !CGPreflightScreenCaptureAccess() {
            await act(on: .screen)
            return .screen
        }
        refresh()
        return nil
    }

    /// Screen recording only takes effect after Take is reopened.
    func restartTake() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// Photos isn't part of set-up: it's only ever asked for when he chooses to add a recording to
    /// Photos (or switches on "Add new recordings to Photos"). This only reads the status.
    static var canSaveToPhotos: Bool {
        photos() == .allowed || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    private static func capture(_ media: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .allowed
        case .notDetermined: .notYet
        default: .off
        }
    }

    private static func photos() -> PermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .allowed
        case .notDetermined: .notYet
        default: .off
        }
    }
}
