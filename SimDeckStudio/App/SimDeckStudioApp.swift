import SwiftUI
import UIKit
import CoreSpotlight

@discardableResult
private func handleSimDeckShortcutType(_ type: String) -> Bool {
    switch type {
    case "org.nativescript.simdeck.pair":
        SimDeckShortcutActionStore.request(.pair)
        return true
    case "org.nativescript.simdeck.scan-qr":
        SimDeckShortcutActionStore.request(.scanPairingQR)
        return true
    default:
        return false
    }
}

final class SimDeckSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcut = connectionOptions.shortcutItem {
            handleSimDeckShortcutType(shortcut.type)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = handleSimDeckShortcutType(shortcutItem.type)
        completionHandler(handled)
    }
}

final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SimDeckSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            handleSimDeckShortcutType(shortcut.type)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = handleSimDeckShortcutType(shortcutItem.type)
        completionHandler(handled)
    }
}

enum AppOrientationPolicy {
    @MainActor
    static func apply(_ orientations: UIInterfaceOrientationMask) {
        guard AppOrientationDelegate.supportedOrientations != orientations else { return }
        AppOrientationDelegate.supportedOrientations = orientations

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else {
            return
        }

        if #available(iOS 16.0, *) {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        }
        windowScene.windows
            .compactMap(\.rootViewController)
            .forEach { $0.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }
}

@main
struct SimDeckStudioApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var orientationDelegate
    @State private var model = AppModel()
    @State private var handledDebugLaunchURL = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if CommandLine.arguments.contains("--simdeck-touch-input-test") {
            StreamTouchInputDebugHarness()
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    private var mainContent: some View {
        ContentView(model: model)
            .onOpenURL { url in
                model.handle(url: url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                model.handle(userActivity: activity)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                model.handle(userActivity: activity)
            }
            .onChange(of: scenePhase) { _, phase in
                model.handleScenePhase(phase)
            }
            .task {
                handleDebugLaunchURLIfNeeded()
            }
    }

    private func handleDebugLaunchURLIfNeeded() {
        #if DEBUG
        guard !handledDebugLaunchURL, let url = Self.debugLaunchURL else { return }
        handledDebugLaunchURL = true
        model.handle(url: url)
        #endif
    }

    #if DEBUG
    private static var debugLaunchURL: URL? {
        let arguments = CommandLine.arguments
        for argument in arguments {
            if argument.hasPrefix("--simdeck-open-url=") {
                return URL(string: String(argument.dropFirst("--simdeck-open-url=".count)))
            }
        }
        if let index = arguments.firstIndex(of: "--simdeck-open-url"),
           arguments.indices.contains(index + 1) {
            return URL(string: arguments[index + 1])
        }
        return nil
    }
    #endif
}
