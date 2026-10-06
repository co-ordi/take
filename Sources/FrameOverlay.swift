import AppKit

/// The 9:16 frame for vertical recordings. Shown before recording so you can drag it into place
/// (and resize it from the corner); hidden once recording starts. Never part of the video itself.
@MainActor
final class FrameOverlay: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private static let frameKey = "verticalFrame"

    /// Where the vertical recording will be taken from, in screen coordinates.
    var region: CGRect { panel?.frame ?? Self.savedFrame() }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: Self.savedFrame(), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        Overlay.configure(panel)
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = FrameView(onClose: { [weak self] in self?.hide() },
                                      onResize: { [weak self] height in self?.resize(toHeight: height) })
        return panel
    }

    private func resize(toHeight height: CGFloat) {
        guard let panel else { return }
        let area = Self.area()
        let h = min(max(height, 360), area.height)
        var frame = panel.frame
        frame.origin.y = frame.maxY - h           // keep the top edge where it is
        frame.size = CGSize(width: (h * 9 / 16).rounded(), height: h)
        panel.setFrame(Self.keepOnScreen(frame), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        let fitted = Self.keepOnScreen(panel.frame)
        if fitted != panel.frame { panel.setFrame(fitted, display: true) }
        UserDefaults.standard.set(NSStringFromRect(fitted), forKey: Self.frameKey)
    }

    func windowDidResize(_ notification: Notification) { windowDidMove(notification) }

    // MARK: Geometry

    /// The recorded (main) display, below the menu bar.
    private static func area() -> CGRect {
        NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func savedFrame() -> CGRect {
        let area = area()
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let frame = NSRectFromString(saved)
            if frame.height >= 360, area.contains(frame) { return frame }
        }
        let height = area.height
        let width = (height * 9 / 16).rounded()
        return CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: height)   // centred, full height
    }

    private static func keepOnScreen(_ frame: CGRect) -> CGRect {
        let area = area()
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }
}

/// Draws the frame: a bright outline, a label tab to drag by, a close button and a corner grip.
/// The inside is see-through and lets clicks through to the apps underneath.
private final class FrameView: NSView {
    private let onClose: () -> Void
    private let onResize: (CGFloat) -> Void
    private var dragStart: (point: NSPoint, height: CGFloat)?
    private static let tint = NSColor.systemOrange
    private static let tabHeight: CGFloat = 26
    private static let grip: CGFloat = 22

    init(onClose: @escaping () -> Void, onResize: @escaping (CGFloat) -> Void) {
        self.onClose = onClose
        self.onResize = onResize
        super.init(frame: .zero)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide frame")!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .white
        close.toolTip = "Hide the frame (vertical recording stays on)"
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closeTapped() { onClose() }

    override func draw(_ dirtyRect: NSRect) {
        // A faint band just inside the edge, so the outline is easy to grab. The middle stays fully clear.
        NSColor.black.withAlphaComponent(0.04).setFill()
        let band = NSBezierPath(rect: bounds)
        band.append(NSBezierPath(rect: bounds.insetBy(dx: 10, dy: 10)).reversed)
        band.fill()

        Self.tint.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        outline.lineWidth = 3
        outline.stroke()

        // The tab along the top, to drag by.
        let tab = NSRect(x: 0, y: bounds.maxY - Self.tabHeight, width: bounds.width, height: Self.tabHeight)
        Self.tint.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: tab, xRadius: 6, yRadius: 6).fill()
        let label = NSAttributedString(string: "Vertical 9:16  ·  drag to place", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        label.draw(at: NSPoint(x: tab.minX + 10, y: tab.midY - label.size().height / 2))

        // The resize grip in the bottom-right corner.
        let grip = gripRect
        Self.tint.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: grip.maxX, y: grip.minY))
        triangle.line(to: NSPoint(x: grip.maxX, y: grip.maxY))
        triangle.line(to: NSPoint(x: grip.minX, y: grip.minY))
        triangle.close()
        triangle.fill()
    }

    private var gripRect: NSRect { NSRect(x: bounds.maxX - Self.grip, y: 0, width: Self.grip, height: Self.grip) }

    override var mouseDownCanMoveWindow: Bool { true }

    // Dragging the corner grip resizes (keeping 9:16); anywhere else on the outline or tab moves the frame.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if gripRect.contains(point), let window {
            dragStart = (NSEvent.mouseLocation, window.frame.height)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onResize(start.height + (start.point.y - NSEvent.mouseLocation.y))   // dragging down makes it taller
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func resetCursorRects() {
        addCursorRect(gripRect, cursor: .crosshair)
    }
}
