import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

enum Prefs {
    static let microphone = "microphone"
    static let cameraBubble = "cameraBubble"
    static let notes = "notes"
    static let cleanScreen = "cleanScreen"
    static let format = "format"
    static let cameraOnlyVertical = "cameraOnlyVertical"
    static let frameRate = "frameRate"
    static let addToPhotos = "addNewRecordingsToPhotos"
}

enum RecordingFormat: String {
    case fullScreen, vertical, cameraOnly
}

/// What the menu can ask the app to do.
struct PopoverActions {
    var record: () -> Void
    var microphone: (Bool) -> Void
    var cameraBubble: (Bool) -> Void
    var notes: (Bool) -> Void
    var format: (RecordingFormat) -> Void
    var cameraShape: () -> Void
    var resized: (CGFloat) -> Void   // the menu content's natural height, whenever it changes
    var quit: () -> Void
}

/// How tall the menu may get: the height of the screen it opens on, less a margin. Set by MenuPanel.
@MainActor
final class PopoverLayout: ObservableObject {
    static let shared = PopoverLayout()
    @Published var maxHeight: CGFloat = 700
}

/// Owns the menu-bar items and walks each recording through countdown, recording, pausing and saving.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private enum Phase { case idle, countingDown, starting, recording, saving }

    private var statusItem: NSStatusItem!
    private var pauseItem: NSStatusItem!          // only visible while recording
    private var menu: MenuPanel!
    private let recorder = Recorder()
    private let bubble = CameraBubble()
    private let notes = NotesWindow()
    private let verticalFrame = FrameOverlay()
    private let cameraRecorder = CameraRecorder()
    private var hotKeys: HotKeys?
    private var recordingCamera = false           // this take is camera only
    private var awake: NSObjectProtocol?          // no App Nap and no idle sleep while recording

    private var phase = Phase.idle
    private var paused = false
    private var attempt = 0                       // bumped on every start so a cancelled countdown can't carry on
    private var startedAt = Date()                // names the file
    private var recordedBefore: TimeInterval = 0  // recorded time up to the latest pause
    private var stretchStart: Date?               // when the current unpaused stretch began
    private var workingFile: URL?
    private var clock: Timer?
    private var flashReset: DispatchWorkItem?

    private var defaults: UserDefaults { .standard }
    private var format: RecordingFormat { RecordingFormat(rawValue: defaults.string(forKey: Prefs.format) ?? "") ?? .fullScreen }
    private var cameraVertical: Bool { defaults.bool(forKey: Prefs.cameraOnlyVertical) }
    /// The bubble is for screen recordings; in camera-only mode the preview window takes its place.
    private var bubbleWanted: Bool { defaults.bool(forKey: Prefs.cameraBubble) && format != .cameraOnly }
    private var cameraAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Prefs.microphone: true, Prefs.cameraBubble: false, Prefs.notes: false,
            Prefs.cleanScreen: true, Prefs.format: RecordingFormat.fullScreen.rawValue, Prefs.frameRate: 30, Prefs.addToPhotos: false,
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeading
        showIdle()

        pauseItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)   // sits just left of the timer
        pauseItem.button?.target = self
        pauseItem.button?.action = #selector(togglePause)
        pauseItem.isVisible = false

        let content = PopoverView(actions: PopoverActions(
            record: { [weak self] in self?.toggleRecording() },
            microphone: { [weak self] on in self?.microphoneSwitched(on) },
            cameraBubble: { [weak self] on in self?.cameraSwitched(on) },
            notes: { [weak self] on in self?.notesSwitched(on) },
            format: { [weak self] format in self?.formatChanged(format) },
            cameraShape: { [weak self] in self?.cameraShapeChanged() },
            resized: { [weak self] height in self?.menu.place(contentHeight: height) },
            quit: { NSApp.terminate(nil) }))
        menu = MenuPanel(content: content, anchor: statusItem.button!)
        menu.onShow = { [weak self] in self?.menuWillShow() }
        menu.onClose = { MicMeter.shared.stop() }

        hotKeys = HotKeys([
            (kVK_ANSI_R, { [weak self] in self?.toggleRecording() }),
            (kVK_ANSI_P, { [weak self] in self?.togglePause() }),
        ])
        recorder.onUnexpectedStop = { [weak self] in self?.recordingEndedOnItsOwn() }
        cameraRecorder.onUnexpectedStop = { [weak self] in self?.recordingEndedOnItsOwn() }
        notes.onClose = { [weak self] in self?.defaults.set(false, forKey: Prefs.notes) }
        if defaults.bool(forKey: Prefs.notes) { notes.show() }
        defaults.removeObject(forKey: "askedForScreenRecording")   // older builds kept this; it skipped the prompt
        Saver.prepareNotifications()
        PhotosSync.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Permissions.shared.refresh()
    }

    // MARK: Clicks, switches and shortcuts

    @objc private func statusItemClicked() {
        switch phase {
        case .idle: menu.toggle()
        case .countingDown, .recording: toggleRecording()   // no menu while recording, a click just stops
        case .starting, .saving: break
        }
    }

    private func menuWillShow() {
        Permissions.shared.refresh()
        Recordings.shared.refresh()
        if defaults.bool(forKey: Prefs.microphone) { MicMeter.shared.start() }
        // Bring back the previews that belong to the current settings. The camera isn't opened at launch,
        // so it never comes on by itself at login.
        if bubbleWanted, cameraAllowed { bubble.show() }
        if format == .vertical { verticalFrame.show() }
        if format == .cameraOnly, cameraAllowed { cameraRecorder.preview(vertical: cameraVertical) }
    }

    /// Switching the microphone on asks for it there and then. If it's refused, the switch stays on
    /// and the set-up card shows the Microphone row with its Open Settings button.
    private func microphoneSwitched(_ on: Bool) {
        guard on else {
            MicMeter.shared.stop()
            return
        }
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                await Permissions.shared.act(on: .microphone)
            }
            Permissions.shared.refresh()
            if menu.isShown, defaults.bool(forKey: Prefs.microphone) { MicMeter.shared.start() }
        }
    }

    /// The bubble follows the switch: on shows it straight away (asking for the camera the first time),
    /// off hides it. It stays up through recordings until switched off.
    private func cameraSwitched(_ on: Bool) {
        guard on else {
            bubble.hide()
            return
        }
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                await Permissions.shared.act(on: .camera)
            }
            Permissions.shared.refresh()   // if refused, the set-up card shows the Camera row
            if cameraAllowed, bubbleWanted { bubble.show() }
        }
    }

    private func notesSwitched(_ on: Bool) {
        if on { notes.show() } else { notes.hide() }
    }

    private func formatChanged(_ format: RecordingFormat) {
        if format == .vertical { verticalFrame.show() } else { verticalFrame.hide() }
        if format == .cameraOnly {
            bubble.hide()
            Task {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { await Permissions.shared.act(on: .camera) }
                Permissions.shared.refresh()
                if cameraAllowed, self.format == .cameraOnly { cameraRecorder.preview(vertical: cameraVertical) }
            }
        } else {
            cameraRecorder.endPreview()
            if bubbleWanted, cameraAllowed { bubble.show() }
        }
    }

    private func cameraShapeChanged() {
        if format == .cameraOnly, cameraAllowed { cameraRecorder.preview(vertical: cameraVertical) }
    }

    func toggleRecording() {
        switch phase {
        case .idle:
            attempt += 1
            phase = .countingDown        // set straight away so a double press can't start two takes
            let thisAttempt = attempt
            Task { await start(thisAttempt) }
        case .countingDown: cancelCountdown()
        case .recording: stopAndSave()
        case .starting, .saving: break
        }
    }

    @objc private func togglePause() {
        guard phase == .recording else { return }
        paused.toggle()
        if paused {
            if recordingCamera { cameraRecorder.pause() } else { recorder.pause() }
            recordedBefore += Date().timeIntervalSince(stretchStart ?? Date())
            stretchStart = nil
        } else {
            if recordingCamera { cameraRecorder.resume() } else { recorder.resume() }
            stretchStart = Date()
        }
        updateClock()
        updatePauseItem()
    }

    // MARK: Recording

    private func start(_ thisAttempt: Int) async {
        menu.close()
        cancelFlash()

        // A switched-on extra without permission stops the take before it starts, rather than
        // quietly recording something he didn't ask for. The in-app prompts come first;
        // screen recording last, as it can mean a trip to System Settings and a restart.
        let microphone = defaults.bool(forKey: Prefs.microphone)
        let cameraOnly = format == .cameraOnly
        let camera = cameraOnly || bubbleWanted
        switch await Permissions.shared.readyToRecord(microphone: microphone, camera: camera, screen: !cameraOnly) {
        case .microphone?: return giveUp(thisAttempt, "Allow the microphone", showSetUp: true)
        case .camera?: return giveUp(thisAttempt, "Allow the camera", showSetUp: true)
        case .screen?: return giveUp(thisAttempt, "Allow screen recording", showSetUp: false)
        default: break
        }
        guard isCurrent(thisAttempt) else { return }

        let vertical = format == .vertical
        if cameraOnly {
            cameraRecorder.preview(vertical: cameraVertical)   // so he can see himself during the countdown
        } else {
            if camera { bubble.show() }
            if vertical { verticalFrame.show() }    // so the countdown shows exactly what will be recorded
        }

        for count in [3, 2, 1] {
            guard isCurrent(thisAttempt) else { return }
            showCountdown(count)
            try? await Task.sleep(for: .seconds(1))
        }
        guard isCurrent(thisAttempt) else { return }

        phase = .starting
        let region = vertical ? verticalFrame.region : nil
        verticalFrame.hide()
        let file = Saver.newWorkingFile()
        do {
            if cameraOnly {
                try cameraRecorder.start(microphone: microphone, writingTo: file)
            } else {
                try await recorder.start(Recorder.Options(microphone: microphone,
                                                          cleanScreen: defaults.bool(forKey: Prefs.cleanScreen),
                                                          region: region,
                                                          keepVisible: bubble.window,
                                                          frameRate: defaults.integer(forKey: Prefs.frameRate) == 60 ? 60 : 30),
                                         writingTo: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            phase = .idle
            showFailure(error)
            return
        }
        workingFile = file
        recordingCamera = cameraOnly
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                                                      reason: "Recording")
        startedAt = Date()
        recordedBefore = 0
        stretchStart = Date()
        paused = false
        phase = .recording
        pauseItem.isVisible = true
        updatePauseItem()
        startClock()
    }

    private func isCurrent(_ id: Int) -> Bool { phase == .countingDown && attempt == id }

    /// Stops before the countdown. With `showSetUp`, the menu opens on the set-up card,
    /// whose row has the button to the exact Settings page.
    private func giveUp(_ id: Int, _ message: String, showSetUp: Bool) {
        guard isCurrent(id) else { return }
        phase = .idle
        flash(message, seconds: 6)
        if showSetUp { menu.show() }
    }

    private func cancelCountdown() {
        phase = .idle
        showIdle()
    }

    private func stopAndSave() {
        phase = .saving
        paused = false
        pauseItem.isVisible = false
        clock?.invalidate()
        clock = nil
        showText("Saving…")
        Task { await finish() }
    }

    private func finish() async {
        let stopError = recordingCamera ? await cameraRecorder.stop() : await recorder.stop()
        recordingCamera = false
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        guard let file = workingFile else { phase = .idle; showIdle(); return }
        workingFile = nil

        do {
            try await Saver.save(file, recordedAt: startedAt)
            phase = .idle
            flash("Saved ✓", seconds: 3)
            Recordings.shared.refresh()
        } catch {
            phase = .idle
            showFailure(stopError ?? error)
        }
    }

    /// The stream can end without us (display unplugged, permission pulled). Keep whatever was recorded.
    private func recordingEndedOnItsOwn() {
        if phase == .recording { stopAndSave() }
    }

    // MARK: Menu-bar display

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Take")
        image?.isTemplate = true
        return image
    }()

    private static func badge(_ symbol: String, _ colour: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private static let recordingBadge = badge("circle.fill", .systemRed)
    private static let pausedBadge = badge("pause.fill", .systemOrange)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                                                 weight: .medium)

    private func showIdle() {
        statusItem.button?.image = Self.icon
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Take: click to record, or press ⌃⌥⌘R"
    }

    private func showText(_ text: String) {
        statusItem.button?.image = nil
        statusItem.button?.title = text
    }

    private func showCountdown(_ count: Int) {
        statusItem.button?.image = Self.icon
        statusItem.button?.attributedTitle = NSAttributedString(string: " \(count)", attributes: [.font: Self.digits])
    }

    private func startClock() {
        updateClock()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func updateClock() {
        let seconds = Int(recordedBefore + (stretchStart.map { Date().timeIntervalSince($0) } ?? 0))
        let time = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        statusItem.button?.image = paused ? Self.pausedBadge : Self.recordingBadge
        statusItem.button?.attributedTitle = NSAttributedString(string: " " + time, attributes: [
            .font: Self.digits,
            .foregroundColor: paused ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        statusItem.button?.toolTip = paused ? "Paused. Click to stop and save (⌃⌥⌘R)" : "Click to stop and save (⌃⌥⌘R)"
    }

    private func updatePauseItem() {
        let symbol = paused ? "play.fill" : "pause.fill"
        pauseItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: paused ? "Resume" : "Pause")
        pauseItem.button?.toolTip = paused ? "Resume (⌃⌥⌘P)" : "Pause (⌃⌥⌘P)"
    }

    private func flash(_ text: String, seconds: Double) {
        cancelFlash()
        showText(text)
        let reset = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.phase == .idle { self?.showIdle() }
            }
        }
        flashReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: reset)
    }

    private func cancelFlash() {
        flashReset?.cancel()
        flashReset = nil
    }

    private func showFailure(_ error: Error) {
        flash("Couldn't record", seconds: 5)
        Saver.notify("Take couldn't finish that recording", error.localizedDescription)
    }
}
