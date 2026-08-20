import Foundation
import Sparkle

/// App-facing adapter around Sparkle. Sparkle owns feed parsing, EdDSA
/// verification, download, installation, and user dialogs.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != controller.updater.automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
