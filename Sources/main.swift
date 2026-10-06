import AppKit

// Take: a menu-bar screen recorder. Everything starts from AppController.
MainActor.assumeIsolated {
    let controller = AppController()
    let app = NSApplication.shared
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
