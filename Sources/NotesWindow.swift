import AppKit

/// Speaker notes only you see: a small, slightly see-through, always-on-top window.
/// It belongs to Take, and Take's windows are left out of every recording, so it never shows in the video.
@MainActor
final class NotesWindow: NSObject, NSTextViewDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var panel: NSPanel?
    private var textView: NSTextView?
    private static let textKey = "notesText"
    private static let sizeKey = "notesTextSize"
    private static let frameName = "TakeNotes"

    var isShowing: Bool { panel?.isVisible == true }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Notes"
        Overlay.configure(panel)
        panel.alphaValue = 0.94
        panel.minSize = NSSize(width: 200, height: 120)
        panel.delegate = self
        if !panel.setFrameUsingName(Self.frameName), let area = NSScreen.screens.first?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: area.minX + 32, y: area.maxY - 32))   // top-left by default
        }
        panel.setFrameAutosaveName(Self.frameName)

        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let text = scroll.documentView as! NSTextView
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textColor = .white
        text.insertionPointColor = .white
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.string = UserDefaults.standard.string(forKey: Self.textKey)
            ?? "Your notes go here. Only you can see them: they never appear in the recording."
        text.delegate = self
        textView = text

        let smaller = Self.sizeButton("textformat.size.smaller", "Smaller text", action: #selector(smallerText), target: self)
        let bigger = Self.sizeButton("textformat.size.larger", "Larger text", action: #selector(biggerText), target: self)
        let buttons = NSStackView(views: [smaller, bigger])
        buttons.spacing = 2

        let content = NSView()
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -2),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        panel.contentView = content
        applyTextSize()
        return panel
    }

    private static func sizeButton(_ symbol: String, _ label: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.8)
        button.toolTip = label
        return button
    }

    private var textSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: Self.sizeKey) as? Double ?? 18) }
        set { UserDefaults.standard.set(Double(min(max(newValue, 12), 48)), forKey: Self.sizeKey) }
    }

    @objc private func smallerText() { textSize -= 2; applyTextSize() }
    @objc private func biggerText() { textSize += 2; applyTextSize() }

    private func applyTextSize() {
        textView?.font = .systemFont(ofSize: textSize, weight: .medium)
    }

    func textDidChange(_ notification: Notification) {
        UserDefaults.standard.set(textView?.string ?? "", forKey: Self.textKey)
    }

    /// The close button works like switching Notes off.
    func windowWillClose(_ notification: Notification) { onClose?() }
}
