import AppKit
import SwiftUI

/// Take's menu: a rounded panel hanging just under the menu-bar icon. Take places it itself rather
/// than using NSPopover, which kept moving to wherever it thought fitted best whenever its content
/// changed. Its top edge stays pinned under the icon and it only ever grows downwards; past the
/// screen's height its content scrolls. It never activates Take, so the app being recorded keeps focus.
///
/// It closes on exactly three things: a click in another app, Esc, or the menu-bar icon. Take's own
/// windows (bubble, camera preview, notes, 9:16 frame) appearing, moving or being clicked leave it open,
/// and so does it losing key status.
@MainActor
final class MenuPanel: NSObject {
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    private let panel: MenuWindow
    private let hosting: SizingHostingView
    private weak var anchor: NSView?      // the menu-bar icon
    private var left: CGFloat?            // set when opened; afterwards it only moves to stay on screen
    private var contentHeight: CGFloat?   // as reported by the content itself
    private var monitors: [Any] = []
    private static let width: CGFloat = 296
    private static let gap: CGFloat = 4   // between the menu bar and the panel
    private static let margin: CGFloat = 24

    var isShown: Bool { panel.isVisible }

    init(content: some View, anchor: NSView) {
        self.anchor = anchor
        // Take is never the active app, so SwiftUI treats every click in the menu as a click that
        // "activates" the window, and by default its own buttons ignore those. This lets them through.
        hosting = SizingHostingView(rootView: AnyView(content.allowsWindowActivationEvents(true)))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel = MenuWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu                     // above the bubble, notes and frame
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        // The same frosted, rounded look as a popover, with a hairline edge.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 12)
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        let edge = PassThroughView()   // drawn on top, but clicks go straight through to the controls
        edge.wantsLayer = true
        edge.layer?.cornerRadius = 12
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0.5
        edge.layer?.borderColor = NSColor.separatorColor.cgColor
        edge.autoresizingMask = [.width, .height]
        background.addSubview(edge)
        panel.contentView = background

        hosting.onSizeChange = { [weak self] in self?.place() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.left = nil   // the display changed: line up under the icon again
                self.place()
            }
        }
    }

    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard !isShown else { return }
        onShow?()
        left = nil
        hosting.layoutSubtreeIfNeeded()   // settle the content's height before the first placement
        place()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()                   // key for clicks and Esc, but non-activating: Take stays in the background
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        watchForDismissal()
    }

    func close() {
        guard isShown else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
        onClose?()
    }

    /// Pins the top edge just under the icon, sizes to the content (never taller than the screen
    /// allows) and keeps it on screen. Horizontally it stays where it opened unless the screen demands.
    /// The content reports its own height whenever it changes; that number is used as it arrives,
    /// since asking SwiftUI for its size mid-update can return the previous one.
    func place(contentHeight reported: CGFloat? = nil) {
        if let reported { contentHeight = reported }
        guard let view = anchor, let window = view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let icon = window.convertToScreen(view.convert(view.bounds, to: nil))
        let area = screen.visibleFrame
        let maxHeight = max(area.height - Self.margin, 240)
        if PopoverLayout.shared.maxHeight != maxHeight { PopoverLayout.shared.maxHeight = maxHeight }

        let height = min(contentHeight ?? hosting.fittingSize.height, maxHeight)
        let top = min(window.frame.minY, icon.minY, area.maxY) - Self.gap   // just below the menu bar
        var x = left ?? (icon.midX - Self.width / 2)                        // centred on the icon when it opens
        x = min(max(x, area.minX + 8), area.maxX - Self.width - 8)
        left = x
        let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
        if frame != panel.frame { panel.setFrame(frame, display: true, animate: false) }
    }

    /// A click in another app closes it (a global monitor only ever sees other apps' events), and so
    /// does Esc. Clicks in any of Take's own windows are never treated as outside. The menu-bar icon
    /// toggles the panel through its own action.
    private func watchForDismissal() {
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                           handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(outside)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isShown else { return false }
                self.close()
                return true
            }
            return closed ? nil : event
        }) {
            monitors.append(escape)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless panels can't normally become key; this one can, so it gets Esc. Take is never the
/// active app, so the panel can lose key status (say after you click back into the app you're working in).
/// AppKit would then spend the next click just making it key again; making it key first lets that
/// click reach the control straight away.
private final class MenuWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// Draws without ever taking a click.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tells the panel whenever the SwiftUI content wants a different size, and takes the first click
/// even when the panel isn't key.
private final class SizingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onSizeChange?() }
        }
    }
}
