import AppKit

/// Takku lives in the menu bar (`LSUIElement`), but while one of its windows is open (Settings,
/// Welcome, Speaker names) it becomes a regular app: icon in the Dock and Cmd-Tab, and in Mission
/// Control under its windows. When the last one closes it goes back to the menu bar only.
@MainActor
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close: during willClose the window is still visible.
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
            })
        }
    }

    private static func update() {
        // Panels (the menu bar menu, Open dialogs) do not count: only real titled windows.
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy can push the window behind the others: bring it back in front.
        if policy == .regular { NSApp.activate() }
    }
}
