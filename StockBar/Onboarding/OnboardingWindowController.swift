import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    private override init() { super.init() }

    static func isOnboarded(repo: SettingsRepository) -> Bool {
        repo.string(Keys.onboarded) == "1"
    }

    static func markOnboarded(repo: SettingsRepository) {
        try? repo.set(Keys.onboarded, "1")
    }

    enum Keys {
        static let onboarded = "onboarded"
    }

    func show(container: DependencyContainer, onComplete: @escaping () -> Void) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(container: container, onComplete: { [weak self] in
            OnboardingWindowController.markOnboarded(repo: container.settingsRepo)
            self?.close()
            onComplete()
        })
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = L("onboarding.title", comment: "")
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 520, height: 400))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        window?.contentViewController = nil
        window = nil
    }
}
