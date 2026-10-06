@preconcurrency import AVFoundation
import ServiceManagement
import SwiftUI

/// The only window Take has: one big Record button, a few remembered switches, extras folded away.
struct PopoverView: View {
    let actions: PopoverActions

    @AppStorage(Prefs.microphone) private var microphone = true
    @AppStorage(Prefs.cameraBubble) private var cameraBubble = false
    @AppStorage(Prefs.notes) private var notes = false
    @AppStorage(Prefs.cleanScreen) private var cleanScreen = true
    @AppStorage(Prefs.format) private var format = RecordingFormat.fullScreen
    @AppStorage("cameraSectionOpen") private var cameraOpen = false
    @AppStorage("moreSectionOpen") private var moreOpen = false
    @AppStorage("recordingsSectionOpen") private var recordingsOpen = false
    @AppStorage(Prefs.cameraOnlyVertical) private var cameraVertical = false
    @AppStorage(Prefs.frameRate) private var frameRate = 30
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var contentHeight: CGFloat = 400
    @ObservedObject private var meter = MicMeter.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var layout = PopoverLayout.shared
    @ObservedObject private var recordings = Recordings.shared

    /// Scrolls rather than growing past the screen, so the popover always stays under its icon.
    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                    actions.resized(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 296, height: min(contentHeight, layout.maxHeight))
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var cameraOnly: Bool { format == .cameraOnly }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if permissions.showsCard {
                SetUpCard(permissions: permissions)
            }

            Button(action: actions.record) {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Picker("Format", selection: $format) {
                Text("Full screen").tag(RecordingFormat.fullScreen)
                Text("Vertical 9:16").tag(RecordingFormat.vertical)
                Text("Camera only").tag(RecordingFormat.cameraOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: format) { _, new in actions.format(new) }

            if !cameraOnly {
                HStack(spacing: 8) {
                    Picker("Frame rate", selection: $frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Text(frameRate == 60 ? "Smoother motion, bigger files." : "Best for most recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if cameraOnly {
                HStack(spacing: 8) {
                    Picker("Camera shape", selection: $cameraVertical) {
                        Text("16:9").tag(false)
                        Text("9:16").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .onChange(of: cameraVertical) { _, _ in actions.cameraShape() }
                    Text("Just you: camera and microphone, no screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("⌃⌥⌘R starts and stops, ⌃⌥⌘P pauses. Or click the timer to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            row("Microphone", isOn: $microphone) {
                if microphone, permissions.status(.microphone) == .allowed { LevelMeter(level: meter.level) }
            }
            .onChange(of: microphone) { _, on in actions.microphone(on) }

            if !cameraOnly {
                row("Camera bubble", isOn: $cameraBubble)
                    .onChange(of: cameraBubble) { _, on in actions.cameraBubble(on) }
            }
            if cameraBubble || cameraOnly {
                DisclosureGroup(cameraOnly ? "Look and effects" : "Size, shape and look", isExpanded: $cameraOpen) {
                    CameraSection(camera: CameraSettings.shared, bubbleControls: !cameraOnly).padding(.top, 6)
                }
                .font(.callout)
                .onChange(of: cameraOpen) { _, open in if open { moreOpen = false; recordingsOpen = false } }   // one section open at a time
            }

            row("Notes", isOn: $notes)
                .onChange(of: notes) { _, on in actions.notes(on) }

            Divider()

            DisclosureGroup("Recordings", isExpanded: $recordingsOpen.onSet { open in
                if open { cameraOpen = false; moreOpen = false }
            }) {
                RecordingsSection(recordings: recordings).padding(.top, 6)
            }
            .font(.callout)

            DisclosureGroup("More", isExpanded: $moreOpen.onSet { open in if open { cameraOpen = false; recordingsOpen = false } }) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Clean screen", isOn: $cleanScreen)
                    Text("Keeps notifications and desktop icons out of the video. Your notes and Take's own controls never appear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    row("Open at login", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, wanted in setOpenAtLogin(wanted) }
                    Button("Permissions") {
                        permissions.refresh()
                        permissions.cardRequested = true
                    }
                    .buttonStyle(.link)
                    Text("Computer sound is always recorded. Recordings save to Movies > Take; add any of them to Photos from Recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Quit Take", action: actions.quit)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 296)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title, isOn: isOn) { EmptyView() }
    }

    private func row<Extra: View>(_ title: String, isOn: Binding<Bool>, @ViewBuilder extra: () -> Extra) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Text(title)
                extra()
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func setOpenAtLogin(_ wanted: Bool) {
        let service = SMAppService.mainApp
        do {
            if wanted, service.status != .enabled { try service.register() }
            if !wanted, service.status == .enabled { try service.unregister() }
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        let enabled = service.status == .enabled
        if openAtLogin != enabled { openAtLogin = enabled }
    }
}

/// One row per permission, each with its status and a single button. Shows by itself when something
/// Take needs is missing, and from More > Permissions any time.
private struct SetUpCard: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(permissions.needsSetUp ? "Set up Take" : "Permissions").font(.headline)
                Spacer()
                if permissions.needsSetUp {
                    Button("Allow all") { Task { await permissions.allowAll() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Done") { permissions.cardRequested = false }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(kind: kind, status: permissions.status(kind)) {
                    Task { await permissions.act(on: kind) }
                }
            }

            if permissions.offerRestart {
                HStack(alignment: .firstTextBaseline) {
                    Text("Switched Take on in Settings? It needs a restart to start recording.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Restart Take") { permissions.restartTake() }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(permissions.needsSetUp ? 0.12 : 0.06)))
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.callout.weight(.medium))
                Spacer(minLength: 6)
                switch status {
                case .allowed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Allowed")
                case .notYet:
                    Button("Allow", action: action).controlSize(.small)
                case .off:
                    Button("Open Settings", action: action).controlSize(.small)
                }
            }
            (Text(status.label).foregroundStyle(colour) + Text("  ") + Text(kind.why).foregroundStyle(.secondary))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colour: Color {
        switch status {
        case .allowed: .green
        case .notYet: .orange
        case .off: .red
        }
    }
}

/// The latest recordings, each with Add to Photos, and a way to the folder.
private struct RecordingsSection: View {
    @ObservedObject var recordings: Recordings
    @AppStorage(Prefs.addToPhotos) private var autoAdd = false

    private static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if recordings.items.isEmpty {
                Text("No recordings yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(recordings.items) { item in
                HStack(spacing: 6) {
                    Button(Self.when.string(from: item.created)) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    .buttonStyle(.plain)
                    .help(item.url.lastPathComponent)
                    Text(item.length.map(Self.length) ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    if item.inPhotos {
                        Text("In Photos ✓").foregroundStyle(.secondary)
                    } else if recordings.adding.contains(item.url) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Add to Photos") { Task { await recordings.addToPhotos(item.url) } }
                            .controlSize(.small)
                    }
                }
                .font(.caption)
            }
            Button("Show all") { NSWorkspace.shared.open(Saver.folder) }
                .buttonStyle(.link)
                .font(.caption)

            Toggle(isOn: $autoAdd) {
                Text("Add new recordings to Photos").frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .padding(.top, 2)
            .onChange(of: autoAdd) { _, on in Task { await recordings.autoAddSwitched(on) } }
            if let note = recordings.photosNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A small bar showing how loud the microphone is right now.
private struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: max(geometry.size.width * level, level > 0.02 ? 4 : 0))
            }
        }
        .frame(width: 44, height: 5)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
    }
}

/// Size, shape and look for the camera bubble. Only shown while the bubble is on.
private struct CameraSection: View {
    @ObservedObject var camera: CameraSettings
    let bubbleControls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if bubbleControls { bubbleShape }

            HStack {
                Toggle("Mirror", isOn: $camera.mirrored)
                Spacer()
                if bubbleControls { Toggle("Border", isOn: $camera.border) }
                Spacer()
            }
            .toggleStyle(.checkbox)

            HStack {
                Text("Look").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { camera.resetLook() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.top, 2)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(LookPreset.allCases) { preset in
                    Button(preset.title) { camera.choose(preset) }
                        .buttonStyle(Chip(selected: camera.preset == preset))
                }
            }

            adjuster("Light", $camera.light)
            adjuster("Warmth", $camera.warmth)
            adjuster("Contrast", $camera.contrast)

            Divider().padding(.vertical, 2)
            Button("Effects and background…") { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
                .controlSize(.small)
            Text(VideoEffects.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    /// Size and shape only matter for the bubble.
    @ViewBuilder private var bubbleShape: some View {
        Slider(value: $camera.size, in: 0...1) {
            Text("Size")
        } minimumValueLabel: {
            Image(systemName: "person.crop.circle").imageScale(.small)
        } maximumValueLabel: {
            Image(systemName: "person.crop.circle").imageScale(.large)
        }
        .labelsHidden()

        Picker("Shape", selection: $camera.shape) {
            ForEach(BubbleShape.allCases) { shape in
                Image(systemName: shape.symbol).help(shape.title).tag(shape)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func adjuster(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: -1...1)
        }
    }
}

/// A small pill button for the look presets.
private struct Chip: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 22)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
    }
}

/// Which macOS video effects are on for Take (set in the system's own Video Effects panel).
enum VideoEffects {
    static var summary: String {
        var on: [String] = []
        if AVCaptureDevice.isPortraitEffectEnabled { on.append("Portrait") }
        if AVCaptureDevice.isStudioLightEnabled { on.append("Studio Light") }
        if AVCaptureDevice.isBackgroundReplacementEnabled { on.append("Background") }
        if AVCaptureDevice.isCenterStageEnabled { on.append("Center Stage") }
        guard !on.isEmpty else { return "No video effects on. Portrait, Studio Light, Background and more live in the macOS panel." }
        let list = on.count == 1 ? on[0] : on.dropLast().joined(separator: ", ") + " and " + on.last!
        return "On: \(list). Applied to the bubble and recordings."
    }
}

private extension Binding {
    /// The same binding, with a side effect whenever it's set.
    func onSet(_ action: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { newValue in
            wrappedValue = newValue
            action(newValue)
        })
    }
}
