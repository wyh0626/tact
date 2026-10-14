import AppKit
import Sparkle

/// New versions come from the project's GitHub releases through Sparkle. It
/// asks once whether to look by itself, then downloads, checks the update's
/// signature, replaces the app and opens it again. A build without a feed in
/// its Info.plist (`swift run`, tests) has no updater.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// A version a background check found while Tact was out of sight. It
    /// waits for the user, as a dot on the menu bar icon and a row in the
    /// panel, instead of an alert over the chat they are typing in.
    @Published private(set) var waiting: String?
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    var isAvailable: Bool { controller != nil }

    func start(bundle: Bundle = .main) {
        guard controller == nil, bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// Asked for by the user: Sparkle brings Tact forward and shows what it
    /// finds, an update a background check already found included.
    func check() {
        controller?.checkForUpdates(nil)
    }

    func noticed(_ version: String) {
        waiting = version
    }

    func attended() {
        waiting = nil
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Right after launch Sparkle shows its window as usual. Later it would
    /// open behind the app in use, so Tact keeps a reminder instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { noticed(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { attended() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { attended() }
    }
}
