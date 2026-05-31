import AppIntents
import Foundation

enum SimDeckShortcutAction: String, Sendable {
    case pair
    case scanPairingQR
}

enum SimDeckShortcutActionStore {
    private static let pendingActionKey = "pendingShortcutAction"

    static func request(_ action: SimDeckShortcutAction) {
        UserDefaults.standard.set(action.rawValue, forKey: pendingActionKey)
        NotificationCenter.default.post(name: .simDeckShortcutActionRequested, object: nil)
    }

    static func consumePendingAction() -> SimDeckShortcutAction? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingActionKey),
              let action = SimDeckShortcutAction(rawValue: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingActionKey)
        return action
    }
}

extension Notification.Name {
    static let simDeckShortcutActionRequested = Notification.Name("SimDeckShortcutActionRequested")
}

struct PairSimDeckIntent: AppIntent {
    static var title: LocalizedStringResource = "Pair SimDeck"
    static var description = IntentDescription("Open SimDeck to pair a server.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SimDeckShortcutActionStore.request(.pair)
        return .result()
    }
}

struct ScanSimDeckQRIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan SimDeck QR"
    static var description = IntentDescription("Open SimDeck directly to the pairing QR scanner.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SimDeckShortcutActionStore.request(.scanPairingQR)
        return .result()
    }
}

struct SimDeckAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PairSimDeckIntent(),
            phrases: [
                "Pair \(.applicationName)",
                "Pair SimDeck in \(.applicationName)"
            ],
            shortTitle: "Pair SimDeck",
            systemImageName: "checkmark.seal"
        )

        AppShortcut(
            intent: ScanSimDeckQRIntent(),
            phrases: [
                "Scan \(.applicationName) QR",
                "Scan QR in \(.applicationName)"
            ],
            shortTitle: "Scan SimDeck QR",
            systemImageName: "qrcode.viewfinder"
        )
    }
}
