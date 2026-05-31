import Foundation
import CoreSpotlight
import CryptoKit
import Observation
import SwiftUI
import UIKit
@preconcurrency import WebRTC

enum StreamState: String {
    case idle = "Idle"
    case connecting = "Connecting"
    case connected = "Connected"
    case disconnected = "Disconnected"
    case failed = "Failed"
}

enum HardwareButtonPhase: String {
    case down
    case up
}

private struct HardwareButtonControlPayload: Encodable {
    let button: String
    let durationMs: Int?
    let phase: String?
    let usagePage: Int?
    let usage: Int?
}

private struct KeyControlPayload: Encodable {
    let keyCode: Int
    let modifiers: Int
}

private struct CrownControlPayload: Encodable {
    let delta: Double
}

private struct TouchControlPayload: Encodable {
    let x: Double
    let y: Double
    let phase: String
}

private struct EdgeTouchControlPayload: Encodable {
    let x: Double
    let y: Double
    let phase: String
    let edge: String
}

private struct MultiTouchControlPayload: Encodable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double
    let phase: String
}

private struct EmptyControlPayload: Encodable {}

private enum SimulatorInputControl {
    case touch(TouchControlPayload)
    case edgeTouch(EdgeTouchControlPayload)
    case multiTouch(MultiTouchControlPayload)

    @discardableResult
    func send(using client: WebRTCClient) -> Bool {
        switch self {
        case .touch(let payload):
            client.sendTouch(x: payload.x, y: payload.y, phase: payload.phase)
        case .edgeTouch(let payload):
            client.sendEdgeTouch(
                x: payload.x,
                y: payload.y,
                phase: payload.phase,
                edge: payload.edge
            )
        case .multiTouch(let payload):
            client.sendMultiTouch(
                x1: payload.x1,
                y1: payload.y1,
                x2: payload.x2,
                y2: payload.y2,
                phase: payload.phase
            )
        }
    }
}

private struct ChromeAssets {
    var profile: ChromeProfile?
    var image: UIImage?
    var screenMask: UIImage?
    var buttonImages: [String: ChromeButtonImages] = [:]

    var isEmpty: Bool {
        profile == nil && image == nil && screenMask == nil && buttonImages.isEmpty
    }
}

struct ChromeButtonImages: @unchecked Sendable {
    var normal: UIImage?
    var pressed: UIImage?
}

private enum ConnectionAttemptResult: Sendable {
    case connected(candidate: SimDeckEndpoint, health: HealthResponse, simulatorsResponse: SimulatorsResponse)
    case pairingRequired(candidate: SimDeckEndpoint, health: HealthResponse?)
    case failed(String)
}

private enum ConnectionResolution: Sendable {
    case connected(endpoint: SimDeckEndpoint, simulatorsResponse: SimulatorsResponse)
    case pairingRequired(SimDeckEndpoint)
    case failed(String?)
}

private enum CISessionUnlockError: Error {
    case invalidCipher
    case invalidPlaintext
}

@MainActor
@Observable
final class AppModel {
    let discovery = SimDeckDiscovery()
    private static let savedEndpointsKey = "savedEndpoints"
    private static let legacyRecentEndpointsKey = "recentEndpoints"
    private static let selectedEndpointKey = "selectedEndpoint"
    private static let streamConfigKey = "streamConfig"
    private static let hapticsEnabledKey = "hapticsEnabled"
    private static let touchOverlayVisibleKey = "touchOverlayVisible"
    private static let telemetryEnabledKey = "telemetryEnabled"
    private static let didRequestReviewKey = "didRequestReview"
    private static let chromeCacheDirectoryName = "ChromeAssets"
    private static let lastFrameCacheDirectoryName = "LastStreamFrames"

    var endpoint: SimDeckEndpoint?
    var savedEndpoints: [SimDeckEndpoint] = []
    var simulators: [SimulatorMetadata] = []
    var selectedSimulatorID: String?
    var manualAddress = ""
    var manualToken = ""
    var pairingCode = ""
    var authEndpoint: SimDeckEndpoint?
    var status = "Ready"
    var serverStatusMessage: String?
    var serverProxyStatus: String?
    var isBusy = false
    var streamState: StreamState = .idle
    var videoSize: CGSize = .zero
    var chromeProfile: ChromeProfile?
    var chromeImage: UIImage?
    var chromeScreenMask: UIImage?
    var chromeButtonImages: [String: ChromeButtonImages] = [:]
    var streamDiagnostics = StreamDiagnostics()
    var streamReconnects = 0
    var streamReconnectReason = ""
    var bootingSimulatorID: String?
    var simulatorLifecycleID: String?
    var streamDisplayToken = 0
    var hasCurrentStreamFrame = false
    var lastStreamFrame: UIImage?
    var streamConfig = AppModel.loadStreamConfig()
    var hapticsEnabled = AppModel.loadHapticsEnabled() {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsEnabledKey)
        }
    }
    var touchOverlayVisible = AppModel.loadTouchOverlayVisible() {
        didSet {
            UserDefaults.standard.set(touchOverlayVisible, forKey: Self.touchOverlayVisibleKey)
        }
    }
    var telemetryEnabled = AppModel.loadTelemetryEnabled() {
        didSet {
            Metrics.setEnabled(telemetryEnabled)
        }
    }
    var presentationRequest: AppPresentationRequest?
    var pendingCISession: CIProxySession?
    var reviewRequestPending = false
    var pairingSheetPresented = false
    var pairingScannerPresented = false

    @ObservationIgnored private var streamClient: WebRTCClient?
    @ObservationIgnored private var hasAutoConnected = false
    @ObservationIgnored private var isAutoConnecting = false
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var streamRequestGeneration = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var proxyReadinessTask: Task<Void, Never>?
    @ObservationIgnored private var lastReconnectStartedAt = Date.distantPast
    @ObservationIgnored private var chromeCache: [String: ChromeAssets] = [:]
    @ObservationIgnored private var chromeCacheOrder: [String] = []
    @ObservationIgnored private var lastStreamFrameKey: String?
    @ObservationIgnored private var lastSimulatorRefreshAt = Date.distantPast
    @ObservationIgnored private var shortcutObserver: NSObjectProtocol?
    @ObservationIgnored private var sustainedConnectionTask: Task<Void, Never>?
    private static let chromeCacheLimit = 24

    init() {
        discovery.onEndpoint = { [weak self] endpoint in
            Task { @MainActor in
                await self?.autoConnectIfNeeded(endpoint)
            }
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .simDeckShortcutActionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.consumePendingShortcutAction()
            }
        }
    }

    deinit {
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
    }

    var selectedSimulator: SimulatorMetadata? {
        simulators.first { $0.udid == selectedSimulatorID }
    }

    var currentStreamClient: WebRTCClient? { streamClient }

    var isSelectedSimulatorBooting: Bool {
        bootingSimulatorID == selectedSimulatorID
    }

    var isSelectedSimulatorLifecycleBusy: Bool {
        simulatorLifecycleID == selectedSimulatorID || bootingSimulatorID == selectedSimulatorID
    }

    func isSimulatorLifecycleBusy(_ simulator: SimulatorMetadata) -> Bool {
        simulatorLifecycleID == simulator.udid || bootingSimulatorID == simulator.udid
    }

    var availableEndpoints: [SimDeckEndpoint] {
        savedEndpoints + automaticEndpoints
    }

    var automaticEndpoints: [SimDeckEndpoint] {
        var endpoints = discovery.endpoints.filter { discovered in
            !savedEndpoints.contains { endpointsRepresentSameServer($0, discovered) }
        }
        if let endpoint,
           !savedEndpoints.contains(where: { endpointsRepresentSameServer($0, endpoint) }),
           !endpoints.contains(where: { endpointsRepresentSameServer($0, endpoint) }) {
            endpoints.insert(endpoint, at: 0)
        }
        return endpoints
    }

    var selectedEndpointTitle: String {
        endpoint?.displayName ?? "Select Server"
    }

    var selectedEndpointSubtitle: String {
        if let serverStatusMessage,
           endpoint != nil,
           simulators.isEmpty {
            return serverStatusMessage
        }
        return endpoint?.listSubtitle ?? "No SimDeck connected"
    }

    var streamNavigationSubtitle: String {
        endpoint?.displayName ?? "No SimDeck connected"
    }

    func start() {
        Metrics.track(.appLaunched)
        consumePendingShortcutAction()
        loadSavedEndpoints()
        SpotlightIndexer.indexServers(savedEndpoints)
        if let lastSelectedEndpoint = loadSelectedEndpoint() {
            isAutoConnecting = true
            discovery.upsert(lastSelectedEndpoint)
            Task {
                let connected = await connect(
                    lastSelectedEndpoint,
                    autoStart: false,
                    saveEndpoint: false,
                    presentPairingOnAuth: false
                )
                isAutoConnecting = false
                if connected {
                    hasAutoConnected = true
                } else {
                    await autoConnectToAvailableEndpointIfNeeded()
                }
            }
        }
        discovery.start()
    }

    @discardableResult
    func connectManual() async -> Bool {
        guard let endpoint = StudioLinkResolver.endpointFromAddress(manualAddress, token: manualToken) else {
            status = "Enter a SimDeck URL or host."
            return false
        }
        return await connect(endpoint, autoStart: false, saveEndpoint: true)
    }

    func handle(url: URL) {
        if handleSpotlightURL(url) {
            return
        }
        if handleAppActionURL(url) {
            return
        }
        guard let route = StudioLinkResolver.route(for: url) else {
            status = "Unsupported link."
            return
        }
        hasAutoConnected = true
        isAutoConnecting = false
        switch route {
        case let .endpoint(endpoint, autoStart):
            Task { await connect(endpoint, autoStart: autoStart, saveEndpoint: true) }
        case let .pairing(link, autoStart):
            Task { await pair(link, autoStart: autoStart) }
        case let .ciSession(session, autoStart):
            handle(ciSession: session, autoStart: autoStart)
        }
    }

    func handle(userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            handle(url: url)
            return
        }
        if userActivity.activityType == CSSearchableItemActionType,
           let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let url = URL(string: identifier) {
            handle(url: url)
        }
    }

    func consumePresentationRequest() {
        presentationRequest = nil
    }

    func openPairingSheet() {
        pairingScannerPresented = false
        pairingSheetPresented = true
    }

    func openPairingScanner() {
        pairingSheetPresented = false
        pairingScannerPresented = true
    }

    @discardableResult
    func unlockPendingCISession(password: String) async -> Bool {
        guard let session = pendingCISession,
              let cipher = session.tokenCipher else {
            status = "No CI session is waiting for a password."
            hapticWarning()
            return false
        }
        do {
            let token = try Self.decryptCISessionToken(cipher, password: password)
            pendingCISession = nil
            hapticSuccess()
            return await connect(session.endpoint(token: token), autoStart: session.device?.nilIfBlank != nil, saveEndpoint: true)
        } catch {
            status = "That password did not unlock this CI session."
            hapticWarning()
            return false
        }
    }

    private func handle(ciSession: CIProxySession, autoStart: Bool) {
        if ciSession.requiresPassword {
            pendingCISession = ciSession
            status = "Enter the SimDeck CI session password."
            hapticSelection()
            requestPresentation(.ciSessionPassword)
            return
        }
        guard ciSession.token?.nilIfBlank != nil else {
            status = "This CI link is missing its SimDeck access token."
            hapticWarning()
            return
        }
        Task {
            await connect(ciSession.endpoint(), autoStart: autoStart, saveEndpoint: true)
        }
    }

    private func handleAppActionURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "simdeck" else { return false }
        let action = url.host(percentEncoded: false)?.lowercased()
        switch action {
        case "pair", "pairing":
            guard !urlHasEndpointParameters(url) else { return false }
            if let code = queryValue("code", in: url) ?? queryValue("pairingCode", in: url) ?? queryValue("c", in: url) {
                pairingCode = code
            }
            openPairingSheet()
            return true
        case "scan", "scan-qr", "qr":
            openPairingScanner()
            return true
        default:
            return false
        }
    }

    private func requestPresentation(_ request: AppPresentationRequest) {
        presentationRequest = request
    }

    private func consumePendingShortcutAction() {
        guard let action = SimDeckShortcutActionStore.consumePendingAction() else { return }
        switch action {
        case .pair:
            openPairingSheet()
        case .scanPairingQR:
            openPairingScanner()
        }
    }

    private func urlHasEndpointParameters(_ url: URL) -> Bool {
        queryValue("url", in: url) != nil
            || queryValue("u", in: url) != nil
            || queryValue("host", in: url) != nil
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value?
            .nilIfBlank
    }

    private static func decryptCISessionToken(_ cipher: CIProxyTokenCipher, password: String) throws -> String {
        guard cipher.algorithm == "SHA256-SALTED+A256GCM",
              let encryptedData = cipher.ciphertext.base64URLDecodedData,
              let ivData = cipher.iv.base64URLDecodedData,
              let saltData = cipher.salt.base64URLDecodedData,
              encryptedData.count > 16 else {
            throw CISessionUnlockError.invalidCipher
        }
        var material = Data(password.utf8)
        material.append(0)
        material.append(saltData)
        let digest = SHA256.hash(data: material)
        let key = SymmetricKey(data: Data(digest))
        let ciphertext = Data(encryptedData.dropLast(16))
        let tag = Data(encryptedData.suffix(16))
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: ivData),
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let token = String(data: plaintext, encoding: .utf8)?.nilIfBlank else {
            throw CISessionUnlockError.invalidPlaintext
        }
        return token
    }

    private func handleSpotlightURL(_ url: URL) -> Bool {
        guard url.scheme == "simdeck",
              url.host(percentEncoded: false) == "spotlight",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverID = components.queryItems?.first(where: { $0.name == "server" })?.value?.nilIfBlank else {
            return false
        }
        if savedEndpoints.isEmpty {
            loadSavedEndpoints()
        }
        let candidates = savedEndpoints + [endpoint].compactMap(\.self)
        guard var spotlightEndpoint = candidates.first(where: { $0.id == serverID }) else {
            status = "Saved server not found."
            hapticWarning()
            return true
        }
        let simulatorID = components.queryItems?.first(where: { $0.name == "udid" })?.value?.nilIfBlank
        if let simulatorID {
            spotlightEndpoint.preferredSimulatorID = simulatorID
        }
        Task {
            await connect(spotlightEndpoint, autoStart: simulatorID != nil, saveEndpoint: false)
        }
        return true
    }

    @discardableResult
    func connect(
        _ endpoint: SimDeckEndpoint,
        autoStart: Bool,
        saveEndpoint: Bool = false,
        presentPairingOnAuth: Bool = true
    ) async -> Bool {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        cancelProxyReadinessPolling()
        let connectionEndpoint = endpointWithReusableToken(endpoint)
        isBusy = true
        status = "Connecting to \(connectionEndpoint.displayName)"
        defer {
            if generation == connectionGeneration {
                isBusy = false
            }
        }

        guard generation == connectionGeneration else { return false }

        switch await resolveConnection(for: connectionEndpoint) {
        case let .connected(resolvedCandidate, simulatorsResponse):
            guard generation == connectionGeneration else { return false }
            let simulators = simulatorsResponse.simulators
            stopStream()
            self.endpoint = resolvedCandidate
            self.authEndpoint = nil
            self.simulators = simulators
            SpotlightIndexer.indexSimulators(simulators, for: resolvedCandidate)
            applyServerStatus(simulatorsResponse)
            selectedSimulatorID = autoStart
                ? resolvedCandidate.preferredSimulatorID
                    ?? simulators.first(where: \.isBooted)?.udid
                    ?? simulators.first?.udid
                : nil
            if saveEndpoint {
                saveUserEndpoint(resolvedCandidate)
            }
            saveSelectedEndpoint(resolvedCandidate)
            status = simulators.isEmpty
                ? serverStatusMessage ?? "Connected. No simulators found."
                : "Connected."
            Metrics.track(.serverConnected, properties: Metrics.endpointProperties(resolvedCandidate).merging([
                "simulator_count": simulators.count,
                "auto_start": autoStart,
                "saved_endpoint": saveEndpoint
            ]) { current, _ in current })
            hapticSuccess()
            if shouldContinuePollingProxy(simulatorsResponse) {
                startProxyReadinessPolling(autoStart: autoStart)
            } else if autoStart, selectedSimulatorID != nil {
                await prepareSelectedSimulator()
            }
            return true

        case let .pairingRequired(pendingAuthEndpoint):
            guard presentPairingOnAuth else {
                status = "Ready"
                return false
            }
            status = "Pairing required."
            Metrics.track(.serverPairingRequired, properties: Metrics.endpointProperties(pendingAuthEndpoint))
            hapticWarning()
            presentPairing(for: pendingAuthEndpoint)
            return false

        case let .failed(message):
            status = message ?? "Unable to connect."
            Metrics.track(.serverConnectionFailed, properties: Metrics.endpointProperties(connectionEndpoint))
            hapticWarning()
            return false
        }

    }

    private func resolveConnection(for endpoint: SimDeckEndpoint) async -> ConnectionResolution {
        await withTaskGroup(of: ConnectionAttemptResult.self, returning: ConnectionResolution.self) { group in
            let candidates = connectionCandidates(for: endpoint)
            for candidate in candidates {
                group.addTask {
                    await Self.connectionAttempt(for: candidate)
                }
            }

            var pendingAuthEndpoint: SimDeckEndpoint?
            var lastErrorMessage: String?
            for await result in group {
                switch result {
                case let .connected(candidate, health, simulatorsResponse):
                    group.cancelAll()
                    var resolvedCandidate = endpointByApplyingHealth(candidate, health)
                    resolvedCandidate.alternateBaseURLs = uniquedURLs(
                        resolvedCandidate.alternateBaseURLs + alternateURLs(
                            from: health,
                            fallbackPort: normalizedPort(for: resolvedCandidate.baseURL)
                        )
                    )
                    .filter { $0 != resolvedCandidate.baseURL }
                    return .connected(endpoint: resolvedCandidate, simulatorsResponse: simulatorsResponse)

                case let .pairingRequired(candidate, health):
                    var pendingEndpoint = endpointByApplyingHealth(candidate, health)
                    pendingEndpoint.requiresPairing = true
                    pendingEndpoint.token = nil
                    discovery.upsert(pendingEndpoint)
                    pendingAuthEndpoint = pendingAuthEndpoint.map { mergedEndpoint($0, pendingEndpoint) } ?? pendingEndpoint
                    lastErrorMessage = SimDeckAPIError.authRequired.localizedDescription

                case let .failed(message):
                    lastErrorMessage = message
                }
            }

            if let pendingAuthEndpoint {
                return .pairingRequired(pendingAuthEndpoint)
            }
            return .failed(lastErrorMessage)
        }
    }

    nonisolated private static func connectionAttempt(for candidate: SimDeckEndpoint) async -> ConnectionAttemptResult {
        do {
            let api = SimDeckAPI(endpoint: candidate)
            let (health, requiresPairing) = try await api.healthStatus(timeout: 2.5)
            if requiresPairing {
                return .pairingRequired(candidate: candidate, health: health)
            }
            guard let health else {
                throw SimDeckAPIError.invalidResponse
            }
            let resolvedCandidate = resolvedEndpointByApplyingHealth(candidate, health)
            let simulatorsResponse = try await SimDeckAPI(endpoint: resolvedCandidate).simulatorsResponse()
            return .connected(candidate: candidate, health: health, simulatorsResponse: simulatorsResponse)
        } catch SimDeckAPIError.authRequired {
            return .pairingRequired(candidate: candidate, health: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated private static func resolvedEndpointByApplyingHealth(_ endpoint: SimDeckEndpoint, _ health: HealthResponse?) -> SimDeckEndpoint {
        guard let health else { return endpoint }
        var updated = endpoint
        updated.serverID = health.serverId ?? updated.serverID
        updated.hostID = health.hostId ?? updated.hostID
        updated.hostName = health.hostName ?? updated.hostName
        updated.serverKind = health.serverKind ?? updated.serverKind
        if let hostName = updated.hostName?.nilIfBlank {
            updated.name = hostName
        }
        updated.alternateBaseURLs = uniquedURLsForConnection(
            updated.alternateBaseURLs + alternateURLsForConnection(from: health, fallbackPort: normalizedPortForConnection(updated.baseURL))
        )
        .filter { $0 != updated.baseURL }
        return updated
    }

    nonisolated private static func uniquedURLsForConnection(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls.map({ $0.normalizedSimDeckBaseURL() }) where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    nonisolated private static func alternateURLsForConnection(from health: HealthResponse, fallbackPort: Int) -> [URL] {
        guard let advertiseHost = health.advertiseHost?.nilIfBlank else { return [] }
        var components = URLComponents()
        components.scheme = "http"
        components.host = advertiseHost
        components.port = health.httpPort ?? fallbackPort
        return components.url.map { [$0] } ?? []
    }

    nonisolated private static func normalizedPortForConnection(_ url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private func endpointByApplyingHealth(_ endpoint: SimDeckEndpoint, _ health: HealthResponse?) -> SimDeckEndpoint {
        guard let health else { return endpoint }
        var updated = endpoint
        updated.serverID = health.serverId ?? updated.serverID
        updated.hostID = health.hostId ?? updated.hostID
        updated.hostName = health.hostName ?? updated.hostName
        updated.serverKind = health.serverKind ?? updated.serverKind
        if let hostName = updated.hostName?.nilIfBlank {
            updated.name = hostName
        }
        updated.alternateBaseURLs = uniquedURLs(
            updated.alternateBaseURLs + alternateURLs(from: health, fallbackPort: normalizedPort(for: updated.baseURL))
        )
        .filter { $0 != updated.baseURL }
        return updated
    }

    private func applyServerStatus(_ response: SimulatorsResponse) {
        serverProxyStatus = response.proxyStatus?.nilIfBlank
        serverStatusMessage = response.statusMessage?.nilIfBlank
        if response.proxyStatus == nil && response.statusMessage == nil {
            serverProxyStatus = nil
            serverStatusMessage = nil
        }
    }

    private func presentPairing(for endpoint: SimDeckEndpoint) {
        var pendingEndpoint = endpoint
        pendingEndpoint.requiresPairing = true
        pendingEndpoint.token = nil
        if let existing = savedEndpoints.first(where: { endpointsRepresentSameServer($0, pendingEndpoint) }) {
            pendingEndpoint = mergedEndpoint(existing, pendingEndpoint)
            pendingEndpoint.requiresPairing = true
            pendingEndpoint.token = nil
            savedEndpoints.removeAll { endpointsRepresentSameServer($0, pendingEndpoint) }
            savedEndpoints.insert(pendingEndpoint, at: 0)
            savedEndpoints = Array(uniqued(savedEndpoints).prefix(12))
            persistSavedEndpoints()
        }
        discovery.upsert(pendingEndpoint)
        self.endpoint = pendingEndpoint
        self.authEndpoint = pendingEndpoint
        self.simulators = []
        self.selectedSimulatorID = nil
        manualAddress = pendingEndpoint.baseURL.absoluteString
        manualToken = ""
        saveSelectedEndpoint(pendingEndpoint)
    }

    @discardableResult
    func pair() async -> Bool {
        guard let authEndpoint else { return false }
        return await pair(endpoint: authEndpoint, code: pairingCode, alternateEndpoints: [], autoStart: false)
    }

    @discardableResult
    func pair(_ link: SimDeckPairingLink, autoStart: Bool) async -> Bool {
        let candidates = uniquedByBaseURL([link.endpoint] + link.alternateEndpoints)
        if let token = link.endpoint.token?.nilIfBlank {
            var pairedEndpoint = link.endpoint
            pairedEndpoint.token = token
            pairedEndpoint.alternateBaseURLs = uniquedURLs(
                pairedEndpoint.alternateBaseURLs + link.alternateEndpoints.flatMap { [$0.baseURL] + $0.alternateBaseURLs }
            )
            .filter { $0 != pairedEndpoint.baseURL }
            savePairedEndpoints(primary: pairedEndpoint, alternates: link.alternateEndpoints, token: token)
            let connected = await connect(pairedEndpoint, autoStart: autoStart, saveEndpoint: true)
            if connected {
                Metrics.track(.serverPaired, properties: Metrics.endpointProperties(pairedEndpoint).merging([
                    "pairing_method": "token_link"
                ]) { current, _ in current })
            }
            return connected
        }
        guard let code = link.pairingCode?.nilIfBlank else {
            var pendingEndpoint = link.endpoint
            pendingEndpoint.alternateBaseURLs = uniquedURLs(
                [pendingEndpoint.baseURL]
                    + pendingEndpoint.alternateBaseURLs
                    + link.alternateEndpoints.flatMap { [$0.baseURL] + $0.alternateBaseURLs }
            )
            .filter { $0 != pendingEndpoint.baseURL }
            presentPairing(for: pendingEndpoint)
            pairingCode = ""
            status = "Pairing code missing."
            hapticWarning()
            return false
        }
        for candidate in candidates {
            let alternates = candidates.filter { $0.baseURL != candidate.baseURL }
            if await pair(endpoint: candidate, code: code, alternateEndpoints: alternates, autoStart: autoStart) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func pair(
        endpoint authEndpoint: SimDeckEndpoint,
        code: String,
        alternateEndpoints: [SimDeckEndpoint],
        autoStart: Bool
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let token = try await SimDeckAPI(endpoint: authEndpoint).pair(code: code)
            var pairedEndpoint = authEndpoint
            if let token {
                pairedEndpoint.token = token
                manualToken = token
                savePairedEndpoints(primary: pairedEndpoint, alternates: alternateEndpoints, token: token)
            }
            pairingCode = ""
            let connected = await connect(pairedEndpoint, autoStart: autoStart, saveEndpoint: true)
            if connected {
                Metrics.track(.serverPaired, properties: Metrics.endpointProperties(pairedEndpoint).merging([
                    "pairing_method": "pairing_code"
                ]) { current, _ in current })
                hapticSuccess()
            }
            return connected
        } catch {
            status = error.localizedDescription
            Metrics.track(.serverPairFailed, properties: Metrics.endpointProperties(authEndpoint).merging([
                "pairing_method": "pairing_code",
                "error_kind": Metrics.errorKind(error)
            ]) { current, _ in current })
            hapticWarning()
            return false
        }
    }

    @discardableResult
    func useToken() async -> Bool {
        guard var authEndpoint else { return false }
        authEndpoint.token = manualToken.nilIfBlank
        let connected = await connect(authEndpoint, autoStart: false, saveEndpoint: true)
        if connected {
            Metrics.track(.serverPaired, properties: Metrics.endpointProperties(authEndpoint).merging([
                "pairing_method": "manual_token"
            ]) { current, _ in current })
            hapticSuccess()
        }
        return connected
    }

    @discardableResult
    func handleScannedPairingPayload(_ value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let route = StudioLinkResolver.route(for: url) {
            switch route {
            case let .pairing(link, autoStart):
                return await pair(link, autoStart: autoStart)
            case let .endpoint(endpoint, autoStart):
                return await connect(endpoint, autoStart: autoStart, saveEndpoint: true)
            case let .ciSession(session, autoStart):
                if session.requiresPassword {
                    pendingCISession = session
                    status = "Enter the SimDeck CI session password."
                    hapticSelection()
                    requestPresentation(.ciSessionPassword)
                    return false
                }
                guard session.token?.nilIfBlank != nil else {
                    status = "This CI link is missing its SimDeck access token."
                    hapticWarning()
                    return false
                }
                return await connect(session.endpoint(), autoStart: autoStart, saveEndpoint: true)
            }
        }
        let digits = trimmed.filter(\.isNumber)
        if !digits.isEmpty {
            pairingCode = String(digits.prefix(6))
            hapticSelection()
        } else {
            status = "That QR code is not a SimDeck pairing link."
            hapticWarning()
        }
        return false
    }

    func refreshSimulators(silent: Bool = false, activity: RequestActivity = .active) async {
        guard let endpoint else { return }
        let previousSelectedID = selectedSimulatorID
        let wasSelectedBooted = selectedSimulator?.isBooted == true
        do {
            let simulatorsResponse = try await SimDeckAPI(endpoint: endpoint).simulatorsResponse(activity: activity)
            let refreshedSimulators = simulatorsResponse.simulators
            applyServerStatus(simulatorsResponse)
            guard shouldApplySimulatorList(simulatorsResponse) else {
                lastSimulatorRefreshAt = .distantPast
                if !silent {
                    status = serverStatusMessage ?? "Updating simulator list."
                    hapticSelection()
                    startProxyReadinessPolling(autoStart: selectedSimulatorID != nil)
                }
                return
            }
            lastSimulatorRefreshAt = Date()
            simulators = refreshedSimulators
            SpotlightIndexer.indexSimulators(refreshedSimulators, for: endpoint)
            if let previousSelectedID,
               !refreshedSimulators.contains(where: { $0.udid == previousSelectedID }) {
                selectedSimulatorID = nil
                stopCurrentStream(resetState: true)
                streamState = .idle
            } else if previousSelectedID != nil {
                let isSelectedBooted = selectedSimulator?.isBooted == true
                if wasSelectedBooted && !isSelectedBooted {
                    stopCurrentStream(resetState: true)
                    streamState = .idle
                } else if !wasSelectedBooted && isSelectedBooted && streamClient == nil {
                    _ = await startStream(automaticReconnect: true)
                }
            }
            if !silent {
                status = serverStatusMessage ?? "Updated."
                hapticSelection()
            }
        } catch {
            lastSimulatorRefreshAt = .distantPast
            if !silent {
                status = error.localizedDescription
                hapticWarning()
            }
        }
    }

    func refreshSimulatorsIfStale(
        maxAge: TimeInterval = 5,
        silent: Bool = true,
        activity: RequestActivity = .active
    ) async {
        guard endpoint != nil else { return }
        guard Date().timeIntervalSince(lastSimulatorRefreshAt) >= maxAge else { return }
        await refreshSimulators(silent: silent, activity: activity)
    }

    private func shouldApplySimulatorList(_ response: SimulatorsResponse) -> Bool {
        guard let proxyStatus = response.proxyStatus?.nilIfBlank?.lowercased() else {
            return true
        }
        return proxyStatus == "ready" || !response.simulators.isEmpty
    }

    private func shouldContinuePollingProxy(_ response: SimulatorsResponse) -> Bool {
        guard endpoint?.usesCloudProxy == true else { return false }
        let proxyStatus = response.proxyStatus?.nilIfBlank?.lowercased()
        return proxyStatus != nil && (proxyStatus != "ready" || response.simulators.isEmpty)
    }

    func selectSimulator(_ udid: String?) {
        guard selectedSimulatorID != udid else { return }
        hapticSelection()
        selectedSimulatorID = udid
        resetStreamPresentation()
        Metrics.track(.simulatorSelected, properties: Metrics.endpointProperties(endpoint).merging(
            Metrics.simulatorProperties(selectedSimulator)
        ) { current, _ in current })
        guard endpoint != nil, udid != nil else {
            stopStream()
            return
        }
        Task { await prepareSelectedSimulator() }
    }

    func prepareSelectedSimulator() async {
        guard let selectedSimulator else { return }
        if selectedSimulator.isBooted {
            await startStream()
        } else {
            await loadSelectedSimulatorChrome()
        }
    }

    @discardableResult
    func startStream(automaticReconnect: Bool = false) async -> Bool {
        guard let endpoint, let selectedSimulatorID else { return false }
        guard selectedSimulator?.isBooted == true else {
            await loadSelectedSimulatorChrome()
            return false
        }
        streamRequestGeneration += 1
        let generation = streamRequestGeneration
        stopCurrentStream(resetState: false)
        resetStreamPresentation()
        streamState = .connecting
        status = automaticReconnect ? "Reconnecting WebRTC." : "Starting WebRTC."
        do {
            let api = SimDeckAPI(endpoint: endpoint)
            async let health = try api.health(timeout: 8)
            let client = WebRTCClient()
            client.onConnectionState = { [weak self] state in
                Task { @MainActor in
                    guard let self,
                          self.isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) else { return }
                    let newState = StreamState(peerState: state)
                    self.streamState = newState
                    self.handleReviewPromptOpportunity(for: newState)
                }
            }
            client.onVideoSize = { [weak self] size in
                Task { @MainActor in
                    guard self?.isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) == true else { return }
                    if self?.videoSize != size {
                        self?.videoSize = size
                    }
                }
            }
            client.onDiagnostics = { [weak self] diagnostics in
                Task { @MainActor in
                    guard self?.isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) == true else { return }
                    self?.streamDiagnostics = diagnostics
                }
            }
            let clientToken = ObjectIdentifier(client)
            client.onReconnectNeeded = { [weak self] reason in
                Task { @MainActor in
                    guard let self,
                          let activeClient = self.streamClient,
                          self.isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID),
                          ObjectIdentifier(activeClient) == clientToken else { return }
                    self.scheduleStreamReconnect(reason: reason)
                }
            }
            let loadedChromeAssets = await chromeAssets(api: api, endpoint: endpoint, simulatorID: selectedSimulatorID, forceRefresh: true)
            guard isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) else {
                client.disconnect()
                return false
            }
            applyChromeAssets(loadedChromeAssets)
            let loadedHealth = try await health
            guard isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) else {
                client.disconnect()
                return false
            }
            let effectiveStreamConfig = endpoint.usesCloudProxy ? streamConfig.cloudProxyDefault : streamConfig
            let answer = try await client.connect(
                api: api,
                simulatorID: selectedSimulatorID,
                health: loadedHealth,
                streamConfig: effectiveStreamConfig
            )
            guard isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) else {
                client.disconnect()
                return false
            }
            streamClient = client
            if let video = answer.video, video.width > 0, video.height > 0 {
                videoSize = CGSize(width: video.width, height: video.height)
            }
            status = "WebRTC connected."
            Metrics.track(.streamConnected, properties: Metrics.endpointProperties(endpoint).merging(
                Metrics.simulatorProperties(selectedSimulator)
            ) { current, _ in current }.merging([
                "automatic_reconnect": automaticReconnect,
                "stream_encoder": effectiveStreamConfig.encoder.rawValue,
                "stream_fps": effectiveStreamConfig.fps,
                "stream_quality": effectiveStreamConfig.quality.rawValue
            ]) { current, _ in current })
            if !automaticReconnect {
                hapticSuccess()
            }
            return true
        } catch {
            guard streamRequestGeneration == generation else { return false }
            streamState = .failed
            status = error.localizedDescription
            Metrics.track(.streamConnectFailed, properties: Metrics.endpointProperties(endpoint).merging(
                Metrics.simulatorProperties(selectedSimulator)
            ) { current, _ in current }.merging([
                "automatic_reconnect": automaticReconnect,
                "error_kind": Metrics.errorKind(error)
            ]) { current, _ in current })
            if !automaticReconnect {
                hapticWarning()
                scheduleStreamReconnect(reason: "connect-failed")
            }
            stopCurrentStream(resetState: false)
            return false
        }
    }

    func loadSelectedSimulatorChrome() async {
        guard let endpoint, let selectedSimulatorID else { return }
        streamRequestGeneration += 1
        let generation = streamRequestGeneration
        stopCurrentStream(resetState: false)
        resetStreamPresentation()
        streamState = .idle
        status = "Loading device chrome."

        let api = SimDeckAPI(endpoint: endpoint)
        let loadedChromeAssets = await chromeAssets(api: api, endpoint: endpoint, simulatorID: selectedSimulatorID, forceRefresh: true)
        guard isCurrentStreamRequest(generation, simulatorID: selectedSimulatorID) else { return }
        applyChromeAssets(loadedChromeAssets)
        status = selectedSimulator?.isBooted == true ? "Ready." : "Ready to start."
    }

    func bootSelectedSimulator() async {
        guard let selectedSimulator else { return }
        guard !selectedSimulator.isBooted else {
            await startStream()
            return
        }
        await startSimulator(selectedSimulator, autoStreamIfSelected: true)
    }

    func shutdownSelectedSimulator() async {
        guard let selectedSimulator else { return }
        await stopSimulator(selectedSimulator)
    }

    func toggleSimulatorLifecycle(_ simulator: SimulatorMetadata) async {
        if simulator.isBooted {
            await stopSimulator(simulator)
        } else {
            await startSimulator(simulator, autoStreamIfSelected: simulator.udid == selectedSimulatorID)
        }
    }

    func startSimulator(_ simulator: SimulatorMetadata, autoStreamIfSelected: Bool = false) async {
        guard let endpoint else { return }
        guard !simulator.isBooted else {
            if autoStreamIfSelected, simulator.udid == selectedSimulatorID {
                await startStream()
            }
            return
        }
        simulatorLifecycleID = simulator.udid
        if simulator.udid == selectedSimulatorID {
            bootingSimulatorID = simulator.udid
            streamState = .connecting
        }
        status = "Starting \(simulator.name)."
        Metrics.track(.simulatorBootRequested, properties: Metrics.endpointProperties(endpoint).merging(
            Metrics.simulatorProperties(simulator)
        ) { current, _ in current })
        hapticSelection()
        do {
            let api = SimDeckAPI(endpoint: endpoint)
            let bootError = await requestSimulatorBoot(api: api, udid: simulator.udid)
            let refreshedSimulators = try await waitForBootedSimulator(api: api, udid: simulator.udid, bootError: bootError)
            simulators = refreshedSimulators
            SpotlightIndexer.indexSimulators(refreshedSimulators, for: endpoint)
            lastSimulatorRefreshAt = Date()
            status = "Started."
            simulatorLifecycleID = nil
            bootingSimulatorID = nil
            Metrics.track(.simulatorBooted, properties: Metrics.endpointProperties(endpoint).merging(
                Metrics.simulatorProperties(refreshedSimulators.first { $0.udid == simulator.udid } ?? simulator)
            ) { current, _ in current })
            hapticSuccess()
            if autoStreamIfSelected, simulator.udid == selectedSimulatorID {
                await startStream()
            }
        } catch {
            streamState = simulator.udid == selectedSimulatorID ? .failed : streamState
            status = error.localizedDescription
            simulatorLifecycleID = nil
            bootingSimulatorID = nil
            Metrics.track(.simulatorBootFailed, properties: Metrics.endpointProperties(endpoint).merging(
                Metrics.simulatorProperties(simulator)
            ) { current, _ in current }.merging([
                "error_kind": Metrics.errorKind(error)
            ]) { current, _ in current })
            hapticWarning()
        }
    }

    private func requestSimulatorBoot(api: SimDeckAPI, udid: String) async -> Error? {
        do {
            try await api.bootSimulator(udid: udid, timeout: 45)
            return nil
        } catch {
            return error
        }
    }

    private func waitForBootedSimulator(
        api: SimDeckAPI,
        udid: String,
        bootError: Error?,
        timeoutSeconds: TimeInterval = 300
    ) async throws -> [SimulatorMetadata] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError = bootError
        while Date() < deadline {
            do {
                let refreshedSimulators = try await api.simulators()
                if refreshedSimulators.contains(where: { $0.udid == udid && $0.isBooted }) {
                    return refreshedSimulators
                }
                lastError = nil
            } catch {
                lastError = error
            }
            status = "Starting simulator..."
            try await Task.sleep(for: .seconds(3))
        }
        if let lastError {
            throw lastError
        }
        throw SimDeckAPIError.requestFailed(408, "Timed out waiting for simulator to boot.")
    }

    func stopSimulator(_ simulator: SimulatorMetadata) async {
        guard let endpoint else { return }
        guard simulator.isBooted else { return }
        simulatorLifecycleID = simulator.udid
        status = "Stopping \(simulator.name)."
        hapticSelection()
        if simulator.udid == selectedSimulatorID {
            stopStream()
        }
        do {
            let api = SimDeckAPI(endpoint: endpoint)
            try await api.shutdownSimulator(udid: simulator.udid)
            simulators = try await api.simulators()
            SpotlightIndexer.indexSimulators(simulators, for: endpoint)
            lastSimulatorRefreshAt = Date()
            status = "Stopped."
            simulatorLifecycleID = nil
            hapticSuccess()
            if simulator.udid == selectedSimulatorID {
                await loadSelectedSimulatorChrome()
            }
        } catch {
            status = error.localizedDescription
            simulatorLifecycleID = nil
            hapticWarning()
        }
    }

    func stopStream() {
        streamRequestGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        bootingSimulatorID = nil
        stopCurrentStream(resetState: true)
        hapticSelection()
    }

    @discardableResult
    func createSimulator(_ request: CreateSimulatorRequest) async -> Bool {
        guard let endpoint else {
            status = "Select a SimDeck server first."
            hapticWarning()
            return false
        }
        isBusy = true
        status = "Creating simulator."
        defer { isBusy = false }
        do {
            let api = SimDeckAPI(endpoint: endpoint)
            let response = try await api.createSimulator(request)
            let refreshed = (try? await api.simulators()) ?? []
            if refreshed.isEmpty {
                upsertSimulator(response.simulator)
                if let pairedWatchSimulator = response.pairedWatchSimulator {
                    upsertSimulator(pairedWatchSimulator)
                }
            } else {
                simulators = refreshed
            }
            SpotlightIndexer.indexSimulators(simulators, for: endpoint)
            selectedSimulatorID = response.simulator.udid
            resetStreamPresentation()
            status = "Created \(response.simulator.name)."
            Metrics.track(.simulatorCreated, properties: Metrics.endpointProperties(endpoint).merging(
                Metrics.simulatorProperties(response.simulator)
            ) { current, _ in current }.merging([
                "paired_watch_requested": request.pairedWatch != nil
            ]) { current, _ in current })
            hapticSuccess()
            await prepareSelectedSimulator()
            return true
        } catch {
            status = error.localizedDescription
            Metrics.track(.simulatorCreateFailed, properties: Metrics.endpointProperties(endpoint).merging([
                "error_kind": Metrics.errorKind(error)
            ]) { current, _ in current })
            hapticWarning()
            return false
        }
    }

    private func stopCurrentStream(resetState: Bool) {
        streamClient?.disconnect()
        streamClient = nil
        if resetState {
            streamState = .idle
            resetStreamPresentation()
        }
    }

    func sendTouch(location: CGPoint, in screenFrame: CGRect, phase: String) {
        guard let point = normalizedTouchPoint(location: location, in: screenFrame) else { return }
        sendTouch(x: Double(point.x), y: Double(point.y), phase: phase)
    }

    func sendEdgeTouch(location: CGPoint, in screenFrame: CGRect, phase: String, edge: String) {
        guard let point = normalizedTouchPoint(location: location, in: screenFrame) else { return }
        sendEdgeTouch(x: Double(point.x), y: Double(point.y), phase: phase, edge: edge)
    }

    func sendEdgeTouch(x: Double, y: Double, phase: String, edge: String) {
        sendInputControl(
            .edgeTouch(EdgeTouchControlPayload(x: x, y: y, phase: phase, edge: edge))
        )
    }

    func normalizedTouchPoint(location: CGPoint, in screenFrame: CGRect) -> CGPoint? {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let x = ((location.x - screenFrame.minX) / screenFrame.width).clamped(to: 0...1)
        let y = ((location.y - screenFrame.minY) / screenFrame.height).clamped(to: 0...1)
        return CGPoint(x: x, y: y)
    }

    func markStreamFrameRendered(displayToken: Int) {
        guard displayToken == streamDisplayToken else { return }
        hasCurrentStreamFrame = true
    }

    func updateLastStreamFrame(_ image: UIImage, displayToken: Int) {
        guard displayToken == streamDisplayToken,
              let endpoint,
              let selectedSimulatorID else {
            return
        }
        lastStreamFrameKey = lastFrameCacheKey(endpoint: endpoint, simulatorID: selectedSimulatorID)
        lastStreamFrame = image
        if videoSize == .zero {
            videoSize = image.size
        }
        persistLastStreamFrame(image, endpoint: endpoint, simulatorID: selectedSimulatorID)
    }

    func sendTouch(x: Double, y: Double, phase: String) {
        sendInputControl(.touch(TouchControlPayload(x: x, y: y, phase: phase)))
    }

    func sendMultiTouch(x1: Double, y1: Double, x2: Double, y2: Double, phase: String) {
        sendInputControl(
            .multiTouch(MultiTouchControlPayload(x1: x1, y1: y1, x2: x2, y2: y2, phase: phase))
        )
    }

    func sendKeyboardText(_ text: String) {
        for character in text {
            guard let key = Self.keyControl(for: character) else {
                status = "Unsupported keyboard input."
                hapticWarning()
                continue
            }
            sendKey(keyCode: key.keyCode, modifiers: key.modifiers)
        }
    }

    func sendKeyboardBackspace() {
        sendKey(keyCode: 42, modifiers: 0)
    }

    func dismissSimulatorKeyboard() {
        let sent = streamClient?.dismissSimulatorKeyboard() ?? false
        guard !sent else { return }
        Task {
            await postDismissKeyboard()
        }
    }

    func toggleSimulatorSoftwareKeyboard() {
        guard selectedSimulatorID != nil else { return }
        hapticSelection()
        Metrics.track(.softwareKeyboardToggled, properties: Metrics.endpointProperties(endpoint).merging(
            Metrics.simulatorProperties(selectedSimulator)
        ) { current, _ in current })
        let sent = streamClient?.toggleSimulatorSoftwareKeyboard() ?? false
        guard !sent else { return }
        Task {
            await postSoftwareKeyboardButton()
        }
    }

    @discardableResult
    func sendKey(keyCode: Int, modifiers: Int = 0) -> Bool {
        guard selectedSimulatorID != nil, (0...65_535).contains(keyCode) else { return false }
        let sent = streamClient?.sendKey(keyCode: keyCode, modifiers: modifiers) ?? false
        guard !sent else { return true }
        Task {
            await postKey(keyCode: keyCode, modifiers: modifiers)
        }
        return false
    }

    func sendHome() {
        tapHardwareButton(named: "home")
    }

    func sendAppSwitcher() {
        hapticImpact()
        streamClient?.sendAppSwitcher()
    }

    func sendLock() {
        tapHardwareButton(named: "power")
    }

    func sendHardwareButton(named button: String, phase: HardwareButtonPhase, usagePage: Int? = nil, usage: Int? = nil) {
        guard selectedSimulatorID != nil else { return }
        switch phase {
        case .down:
            hapticImpact()
        case .up:
            hapticSelection()
        }
        let sent = streamClient?.sendHardwareButton(
            button: button,
            phase: phase.rawValue,
            usagePage: usagePage,
            usage: usage
        ) ?? false
        guard !sent else { return }
        Task {
            await postHardwareButton(
                named: button,
                durationMs: nil,
                phase: phase,
                usagePage: usagePage,
                usage: usage
            )
        }
    }

    func tapHardwareButton(named button: String, usagePage: Int? = nil, usage: Int? = nil, durationMs: Int = 80) {
        guard selectedSimulatorID != nil else { return }
        hapticImpact()
        let sent = streamClient?.pressHardwareButton(
            button: button,
            durationMs: durationMs,
            usagePage: usagePage,
            usage: usage
        ) ?? false
        guard !sent else { return }
        Task {
            await postHardwareButton(
                named: button,
                durationMs: durationMs,
                phase: nil,
                usagePage: usagePage,
                usage: usage
            )
        }
    }

    func rotateLeft() {
        hapticSelection()
        streamClient?.sendRotateLeft()
    }

    func rotateRight() {
        hapticSelection()
        streamClient?.sendRotateRight()
    }

    func toggleAppearance() {
        guard selectedSimulatorID != nil else { return }
        hapticSelection()
        let sent = streamClient?.sendToggleAppearance() ?? false
        guard !sent else { return }
        Task {
            await postToggleAppearance()
        }
    }

    func rotateCrown(delta: Double) {
        guard selectedSimulatorID != nil, delta.isFinite else { return }
        hapticCrownTick()
        let sent = streamClient?.sendCrown(delta: delta) ?? false
        guard !sent else { return }
        Task {
            await postCrown(delta: delta)
        }
    }

    func requestKeyframe() {
        hapticImpact()
        streamClient?.requestKeyframe()
    }

    func retryStream() {
        reconnectTask?.cancel()
        reconnectTask = nil
        hapticSelection()
        Task {
            await startStream()
        }
    }

    func setStreamEncoder(_ encoder: StreamEncoder) {
        updateStreamConfig { $0.encoder = encoder }
    }

    func setStreamFPS(_ fps: Int) {
        updateStreamConfig { $0.fps = fps }
    }

    func setStreamQuality(_ quality: StreamQualityPreset) {
        updateStreamConfig { $0.quality = quality }
    }

    func setTouchOverlayVisible(_ isVisible: Bool) {
        guard touchOverlayVisible != isVisible else { return }
        touchOverlayVisible = isVisible
        hapticSelection()
    }

    private func autoConnectIfNeeded(_ endpoint: SimDeckEndpoint) async {
        guard !hasAutoConnected, !isAutoConnecting, self.endpoint == nil, authEndpoint == nil else { return }
        await autoConnectToAvailableEndpointIfNeeded(preferredEndpoint: endpoint)
    }

    private func autoConnectToAvailableEndpointIfNeeded(preferredEndpoint: SimDeckEndpoint? = nil) async {
        guard !hasAutoConnected, !isAutoConnecting, self.endpoint == nil, authEndpoint == nil else { return }
        let candidates = autoConnectCandidates(preferredEndpoint: preferredEndpoint)
        guard !candidates.isEmpty else { return }

        isAutoConnecting = true
        var connected = false
        for candidate in candidates {
            connected = await connect(
                candidate,
                autoStart: false,
                saveEndpoint: false,
                presentPairingOnAuth: false
            )
            if connected {
                break
            }
        }
        isAutoConnecting = false
        if connected {
            hasAutoConnected = true
        }
    }

    private func autoConnectCandidates(preferredEndpoint: SimDeckEndpoint?) -> [SimDeckEndpoint] {
        let orderedEndpoints = [preferredEndpoint].compactMap(\.self)
            + discovery.endpoints
            + savedEndpoints
        return uniqued(orderedEndpoints)
            .map(endpointWithReusableToken)
            .filter { endpoint in
                !endpoint.requiresPairing || endpoint.token?.nilIfBlank != nil
            }
    }

    private func isCurrentStreamRequest(_ generation: Int, simulatorID: String) -> Bool {
        streamRequestGeneration == generation && selectedSimulatorID == simulatorID
    }

    private func handleReviewPromptOpportunity(for state: StreamState) {
        guard !UserDefaults.standard.bool(forKey: Self.didRequestReviewKey) else { return }
        if state == .connected {
            guard sustainedConnectionTask == nil else { return }
            sustainedConnectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sustainedConnectionTask = nil
                guard self.streamState == .connected,
                      !UserDefaults.standard.bool(forKey: Self.didRequestReviewKey) else { return }
                UserDefaults.standard.set(true, forKey: Self.didRequestReviewKey)
                self.reviewRequestPending = true
            }
        } else {
            sustainedConnectionTask?.cancel()
            sustainedConnectionTask = nil
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            consumePendingShortcutAction()
            streamClient?.appDidBecomeActive()
            Task { await refreshSimulatorsIfStale(maxAge: 1, silent: true, activity: .passive) }
            if endpoint?.usesCloudProxy == true,
               serverProxyStatus?.nilIfBlank?.lowercased() != "ready" || simulators.isEmpty {
                startProxyReadinessPolling(autoStart: selectedSimulatorID != nil)
            }
            if streamClient == nil, streamState == .disconnected || streamState == .failed {
                scheduleStreamReconnect(reason: "foreground")
            }
        case .background:
            streamClient?.appDidEnterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func scheduleStreamReconnect(reason: String) {
        guard endpoint != nil, selectedSimulatorID != nil, selectedSimulator?.isBooted == true else { return }
        guard streamState != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastReconnectStartedAt)
            if elapsed < 1.5 {
                try? await Task.sleep(for: .milliseconds(Int((1.5 - elapsed) * 1000)))
            }
            var attempt = 0
            while !Task.isCancelled,
                  self.endpoint != nil,
                  self.selectedSimulatorID != nil,
                  self.selectedSimulator?.isBooted == true {
                attempt += 1
                self.streamReconnects += 1
                self.streamReconnectReason = reason
                self.lastReconnectStartedAt = Date()
                self.status = attempt == 1
                    ? (reason == "foreground" ? "Resuming stream." : "Recovering stream.")
                    : "Retrying stream."
                let connected = await self.startStream(automaticReconnect: true)
                guard !connected else { return }
                let delay = min(10.0, pow(1.8, Double(attempt)))
                self.status = "Retrying stream in \(Int(delay.rounded(.up)))s."
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
        }
    }

    private func startProxyReadinessPolling(autoStart: Bool) {
        guard endpoint?.usesCloudProxy == true else { return }
        guard proxyReadinessTask == nil else { return }
        proxyReadinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, self.endpoint?.usesCloudProxy == true {
                attempt += 1
                await self.refreshSimulators(silent: true, activity: .passive)
                guard !Task.isCancelled else { return }

                let proxyStatus = self.serverProxyStatus?.nilIfBlank?.lowercased()
                if proxyStatus == nil || proxyStatus == "ready" {
                    if !self.simulators.isEmpty {
                        if autoStart, self.selectedSimulatorID == nil {
                            self.selectedSimulatorID = self.preferredSimulatorIDForAutoStart()
                        }
                        self.proxyReadinessTask = nil
                        if autoStart, self.selectedSimulatorID != nil {
                            await self.prepareSelectedSimulator()
                        } else {
                            self.status = "Connected."
                        }
                        return
                    }
                    if proxyStatus == "ready", attempt >= 6 {
                        self.proxyReadinessTask = nil
                        self.status = self.serverStatusMessage ?? "Connected. No simulators found."
                        return
                    }
                } else {
                    self.status = self.serverStatusMessage ?? "Starting Mac..."
                }

                let delay = attempt < 20 ? 2.0 : 5.0
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            self.proxyReadinessTask = nil
        }
    }

    private func cancelProxyReadinessPolling() {
        proxyReadinessTask?.cancel()
        proxyReadinessTask = nil
    }

    private func preferredSimulatorIDForAutoStart() -> String? {
        endpoint?.preferredSimulatorID
            ?? simulators.first(where: \.isBooted)?.udid
            ?? simulators.first?.udid
    }

    private func postHardwareButton(
        named button: String,
        durationMs: Int?,
        phase: HardwareButtonPhase?,
        usagePage: Int?,
        usage: Int?
    ) async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let payload = HardwareButtonControlPayload(
                button: button,
                durationMs: durationMs,
                phase: phase?.rawValue,
                usagePage: usagePage,
                usage: usage
            )
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(payload, path: "/api/simulators/\(encodedID)/button")
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func postKey(keyCode: Int, modifiers: Int) async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let payload = KeyControlPayload(keyCode: keyCode, modifiers: modifiers)
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(payload, path: "/api/simulators/\(encodedID)/key")
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func sendInputControl(_ control: SimulatorInputControl) {
        guard selectedSimulatorID != nil, let streamClient else { return }
        _ = control.send(using: streamClient)
    }

    private func postDismissKeyboard() async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(
                EmptyControlPayload(),
                path: "/api/simulators/\(encodedID)/dismiss-keyboard"
            )
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func postSoftwareKeyboardButton() async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let payload = HardwareButtonControlPayload(
                button: "software-keyboard",
                durationMs: 0,
                phase: nil,
                usagePage: nil,
                usage: nil
            )
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(payload, path: "/api/simulators/\(encodedID)/button")
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func postToggleAppearance() async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(
                EmptyControlPayload(),
                path: "/api/simulators/\(encodedID)/toggle-appearance"
            )
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func postCrown(delta: Double) async {
        guard let endpoint, let selectedSimulatorID else { return }
        do {
            let payload = CrownControlPayload(delta: delta)
            let encodedID = selectedSimulatorID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedSimulatorID
            try await SimDeckAPI(endpoint: endpoint).postControl(
                payload,
                path: "/api/simulators/\(encodedID)/crown"
            )
        } catch {
            status = error.localizedDescription
            hapticWarning()
        }
    }

    private func resetStreamPresentation() {
        streamDisplayToken &+= 1
        if !applyCachedChromeAssetsForSelection() {
            chromeProfile = nil
            chromeImage = nil
            chromeButtonImages = [:]
            chromeScreenMask = nil
        }
        if !applyCachedLastStreamFrameForSelection() {
            lastStreamFrameKey = nil
            lastStreamFrame = nil
            videoSize = .zero
        } else if let lastStreamFrame {
            videoSize = lastStreamFrame.size
        }
        hasCurrentStreamFrame = false
        streamDiagnostics = StreamDiagnostics()
    }

    private func chromeAssets(
        api: SimDeckAPI,
        endpoint: SimDeckEndpoint,
        simulatorID: String,
        forceRefresh: Bool = false
    ) async -> ChromeAssets {
        let cached = cachedChromeAssets(endpoint: endpoint, simulatorID: simulatorID)
        if !forceRefresh, let cached {
            return cached
        }

        let loadedProfile = try? await api.chromeProfile(udid: simulatorID)
        let effectiveProfile = loadedProfile ?? cached?.profile
        let assetStamp = effectiveProfile?.assetStamp
        let loadedImage = try? await api.chromeImage(udid: simulatorID, stamp: assetStamp, includeButtons: false)
        let loadedButtonImages = await chromeButtonImages(api: api, simulatorID: simulatorID, profile: effectiveProfile, stamp: assetStamp)
        let loadedScreenMask: UIImage?
        if effectiveProfile?.hasScreenMask == true {
            loadedScreenMask = try? await api.screenMaskImage(udid: simulatorID, stamp: assetStamp)
        } else {
            loadedScreenMask = nil
        }
        let loadedAssets = ChromeAssets(
            profile: effectiveProfile,
            image: loadedImage ?? cached?.image,
            screenMask: effectiveProfile?.hasScreenMask == true ? (loadedScreenMask ?? cached?.screenMask) : nil,
            buttonImages: loadedButtonImages.isEmpty ? (cached?.buttonImages ?? [:]) : loadedButtonImages
        )
        guard !loadedAssets.isEmpty else {
            return cached ?? loadedAssets
        }
        cacheChromeAssets(loadedAssets, endpoint: endpoint, simulatorID: simulatorID)
        return loadedAssets
    }

    @discardableResult
    private func applyCachedChromeAssetsForSelection() -> Bool {
        guard let endpoint, let selectedSimulatorID,
              let cached = cachedChromeAssets(endpoint: endpoint, simulatorID: selectedSimulatorID) else {
            return false
        }
        applyChromeAssets(cached)
        return true
    }

    private func applyChromeAssets(_ assets: ChromeAssets) {
        chromeProfile = assets.profile
        chromeImage = assets.image
        chromeScreenMask = assets.screenMask
        chromeButtonImages = assets.buttonImages
    }

    private func chromeButtonImages(
        api: SimDeckAPI,
        simulatorID: String,
        profile: ChromeProfile?,
        stamp: String?
    ) async -> [String: ChromeButtonImages] {
        guard let buttons = profile?.buttons, !buttons.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, ChromeButtonImages)?.self, returning: [String: ChromeButtonImages].self) { group in
            for button in buttons {
                group.addTask {
                    async let normal = try? api.chromeButtonImage(udid: simulatorID, button: button.name, pressed: false, stamp: stamp)
                    async let pressed = try? api.chromeButtonImage(udid: simulatorID, button: button.name, pressed: true, stamp: stamp)
                    let images = await ChromeButtonImages(normal: normal, pressed: pressed)
                    guard images.normal != nil || images.pressed != nil else { return nil }
                    return (button.name, images)
                }
            }
            var result: [String: ChromeButtonImages] = [:]
            for await loaded in group {
                if let loaded {
                    result[loaded.0] = loaded.1
                }
            }
            return result
        }
    }

    private func cachedChromeAssets(endpoint: SimDeckEndpoint, simulatorID: String) -> ChromeAssets? {
        let key = chromeCacheKey(endpoint: endpoint, simulatorID: simulatorID)
        if let cached = chromeCache[key] {
            markChromeCacheKeyUsed(key)
            return cached
        }
        guard let cached = loadChromeAssets(endpoint: endpoint, simulatorID: simulatorID) else {
            return nil
        }
        chromeCache[key] = cached
        markChromeCacheKeyUsed(key)
        return cached
    }

    private func cacheChromeAssets(_ assets: ChromeAssets, endpoint: SimDeckEndpoint, simulatorID: String) {
        guard !assets.isEmpty else { return }
        let key = chromeCacheKey(endpoint: endpoint, simulatorID: simulatorID)
        chromeCache[key] = assets
        markChromeCacheKeyUsed(key)
        persistChromeAssets(assets, endpoint: endpoint, simulatorID: simulatorID)
        while chromeCacheOrder.count > Self.chromeCacheLimit, let evictedKey = chromeCacheOrder.first {
            chromeCacheOrder.removeFirst()
            chromeCache[evictedKey] = nil
        }
    }

    private func markChromeCacheKeyUsed(_ key: String) {
        chromeCacheOrder.removeAll { $0 == key }
        chromeCacheOrder.append(key)
    }

    private func chromeCacheKey(endpoint: SimDeckEndpoint, simulatorID: String) -> String {
        let source = "\(chromeCacheHostIdentity(endpoint))|\(simulatorID)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func chromeCacheHostIdentity(_ endpoint: SimDeckEndpoint) -> String {
        if let hostID = endpoint.hostID?.nilIfBlank {
            return "host-id:\(hostID.lowercased())"
        }
        if let hostName = endpoint.hostName?.normalizedSimDeckHostName {
            return "host-name:\(hostName)"
        }
        if let serverID = endpoint.serverID?.nilIfBlank {
            return "server-id:\(serverID.lowercased())"
        }
        return endpoint.baseURL.absoluteString
    }

    private func loadChromeAssets(endpoint: SimDeckEndpoint, simulatorID: String) -> ChromeAssets? {
        guard let directory = chromeCacheDirectoryURL(endpoint: endpoint, simulatorID: simulatorID) else {
            return nil
        }
        let profileURL = directory.appendingPathComponent("profile.json")
        let chromeURL = directory.appendingPathComponent("chrome.png")
        let screenMaskURL = directory.appendingPathComponent("screen-mask.png")
        let profile = (try? Data(contentsOf: profileURL))
            .flatMap { try? JSONDecoder().decode(ChromeProfile.self, from: $0) }
        let image = (try? Data(contentsOf: chromeURL)).flatMap { UIImage(data: $0) }
        let screenMask = profile?.hasScreenMask == true
            ? (try? Data(contentsOf: screenMaskURL)).flatMap { UIImage(data: $0) }
            : nil
        let assets = ChromeAssets(profile: profile, image: image, screenMask: screenMask)
        return assets.isEmpty ? nil : assets
    }

    private func persistChromeAssets(_ assets: ChromeAssets, endpoint: SimDeckEndpoint, simulatorID: String) {
        guard let directory = chromeCacheDirectoryURL(endpoint: endpoint, simulatorID: simulatorID) else {
            return
        }
        let profileData = assets.profile.flatMap { try? JSONEncoder().encode($0) }
        let imageData = assets.image?.pngData()
        let screenMaskData = assets.screenMask?.pngData()
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let profileData {
                    try profileData.write(to: directory.appendingPathComponent("profile.json"), options: [.atomic])
                }
                if let imageData {
                    try imageData.write(to: directory.appendingPathComponent("chrome.png"), options: [.atomic])
                }
                if let screenMaskData {
                    try screenMaskData.write(to: directory.appendingPathComponent("screen-mask.png"), options: [.atomic])
                }
            } catch {
                #if DEBUG
                print("Unable to persist SimDeck chrome cache: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func chromeCacheDirectoryURL(endpoint: SimDeckEndpoint, simulatorID: String) -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent(Self.chromeCacheDirectoryName, isDirectory: true)
            .appendingPathComponent(chromeCacheKey(endpoint: endpoint, simulatorID: simulatorID), isDirectory: true)
    }

    @discardableResult
    private func applyCachedLastStreamFrameForSelection() -> Bool {
        guard let endpoint, let selectedSimulatorID else {
            return false
        }
        let cacheKey = lastFrameCacheKey(endpoint: endpoint, simulatorID: selectedSimulatorID)
        if lastStreamFrameKey == cacheKey, lastStreamFrame != nil {
            return true
        }
        guard let image = loadLastStreamFrame(endpoint: endpoint, simulatorID: selectedSimulatorID) else {
            return false
        }
        lastStreamFrameKey = cacheKey
        lastStreamFrame = image
        return true
    }

    private func loadLastStreamFrame(endpoint: SimDeckEndpoint, simulatorID: String) -> UIImage? {
        guard let url = lastFrameCacheURL(endpoint: endpoint, simulatorID: simulatorID),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }

    private func persistLastStreamFrame(_ image: UIImage, endpoint: SimDeckEndpoint, simulatorID: String) {
        guard let url = lastFrameCacheURL(endpoint: endpoint, simulatorID: simulatorID),
              let data = image.jpegData(compressionQuality: 0.78) else {
            return
        }
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
            } catch {
                #if DEBUG
                print("Unable to persist SimDeck frame cache: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func lastFrameCacheURL(endpoint: SimDeckEndpoint, simulatorID: String) -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent(Self.lastFrameCacheDirectoryName, isDirectory: true)
            .appendingPathComponent("\(lastFrameCacheKey(endpoint: endpoint, simulatorID: simulatorID)).jpg")
    }

    private func lastFrameCacheKey(endpoint: SimDeckEndpoint, simulatorID: String) -> String {
        let source = "\(endpoint.baseURL.absoluteString)|\(simulatorID)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func updateStreamConfig(_ update: (inout StreamConfig) -> Void) {
        var next = streamConfig
        update(&next)
        guard next != streamConfig else { return }
        streamConfig = next
        saveStreamConfig(next)
        streamClient?.applyStreamQuality(next)
        if streamClient != nil {
            status = "Stream set to \(next.summary)."
        }
        hapticSelection()
    }

    private func upsertSimulator(_ simulator: SimulatorMetadata) {
        if let index = simulators.firstIndex(where: { $0.udid == simulator.udid }) {
            simulators[index] = simulator
        } else {
            simulators.insert(simulator, at: 0)
        }
    }

    private static func keyControl(for character: Character) -> (keyCode: Int, modifiers: Int)? {
        let shift = 1 << 0
        let value = String(character)
        if let keyCode = unshiftedHIDUsage[value] {
            return (keyCode, 0)
        }
        if let keyCode = shiftedHIDUsage[value] {
            return (keyCode, shift)
        }
        return nil
    }

    private static let unshiftedHIDUsage: [String: Int] = [
        "a": 4, "b": 5, "c": 6, "d": 7, "e": 8, "f": 9, "g": 10, "h": 11, "i": 12,
        "j": 13, "k": 14, "l": 15, "m": 16, "n": 17, "o": 18, "p": 19, "q": 20,
        "r": 21, "s": 22, "t": 23, "u": 24, "v": 25, "w": 26, "x": 27, "y": 28, "z": 29,
        "1": 30, "2": 31, "3": 32, "4": 33, "5": 34, "6": 35, "7": 36, "8": 37, "9": 38, "0": 39,
        "\n": 40, "\r": 40, "\u{1B}": 41, "\t": 43, " ": 44,
        "-": 45, "=": 46, "[": 47, "]": 48, "\\": 49, ";": 51, "'": 52,
        "`": 53, ",": 54, ".": 55, "/": 56,
        "\u{2019}": 52, "\u{2018}": 52, "\u{2013}": 45, "\u{2014}": 45
    ]

    private static let shiftedHIDUsage: [String: Int] = [
        "A": 4, "B": 5, "C": 6, "D": 7, "E": 8, "F": 9, "G": 10, "H": 11, "I": 12,
        "J": 13, "K": 14, "L": 15, "M": 16, "N": 17, "O": 18, "P": 19, "Q": 20,
        "R": 21, "S": 22, "T": 23, "U": 24, "V": 25, "W": 26, "X": 27, "Y": 28, "Z": 29,
        "!": 30, "@": 31, "#": 32, "$": 33, "%": 34, "^": 35, "&": 36, "*": 37, "(": 38, ")": 39,
        "_": 45, "+": 46, "{": 47, "}": 48, "|": 49, ":": 51, "\"": 52,
        "~": 53, "<": 54, ">": 55, "?": 56,
        "\u{201C}": 52, "\u{201D}": 52
    ]

    private func loadSavedEndpoints() {
        let data = UserDefaults.standard.data(forKey: Self.savedEndpointsKey)
            ?? UserDefaults.standard.data(forKey: Self.legacyRecentEndpointsKey)
        guard let data,
              let endpoints = try? JSONDecoder().decode([SimDeckEndpoint].self, from: data) else {
            return
        }
        savedEndpoints = uniqued(endpoints).map { endpoint in
            var saved = endpoint
            if saved.source == .recent {
                saved.source = .manual
            }
            return saved
        }
        persistSavedEndpoints()
    }

    func saveUserEndpoint(_ endpoint: SimDeckEndpoint) {
        var saved = endpoint
        if saved.source == .recent {
            saved.source = .manual
        }
        saved.requiresPairing = false
        if let existing = savedEndpoints.first(where: { endpointsRepresentSameServer($0, saved) }) {
            saved = mergedEndpoint(existing, saved)
            saved.source = .manual
            saved.requiresPairing = false
        }
        savedEndpoints.removeAll { endpointsRepresentSameServer($0, saved) }
        savedEndpoints.insert(saved, at: 0)
        savedEndpoints = Array(uniqued(savedEndpoints).prefix(12))
        persistSavedEndpoints()
    }

    func renameSavedEndpoint(_ endpoint: SimDeckEndpoint, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = savedEndpoints.firstIndex(where: { endpointsRepresentSameServer($0, endpoint) }) else {
            return
        }
        savedEndpoints[index].customName = trimmed
        if var current = self.endpoint, endpointsRepresentSameServer(current, endpoint) {
            current.customName = trimmed
            self.endpoint = current
            saveSelectedEndpoint(current)
        }
        if var pending = authEndpoint, endpointsRepresentSameServer(pending, endpoint) {
            pending.customName = trimmed
            authEndpoint = pending
        }
        persistSavedEndpoints()
    }

    func deleteSavedEndpoint(_ endpoint: SimDeckEndpoint) {
        savedEndpoints.removeAll { endpointsRepresentSameServer($0, endpoint) }
        SpotlightIndexer.removeSimulatorIndex(for: endpoint)
        if let selectedEndpoint = loadSelectedEndpoint(),
           endpointsRepresentSameServer(selectedEndpoint, endpoint) {
            UserDefaults.standard.removeObject(forKey: Self.selectedEndpointKey)
        }
        scrubDiscoveredCredentials(matching: endpoint)
        if self.endpoint.map({ endpointsRepresentSameServer($0, endpoint) }) == true {
            clearCurrentConnection()
            status = "Connection deleted."
        } else if authEndpoint.map({ endpointsRepresentSameServer($0, endpoint) }) == true {
            authEndpoint = nil
            pairingCode = ""
            manualToken = ""
        }
        persistSavedEndpoints()
        hapticSelection()
    }

    func resetConnections() {
        savedEndpoints = []
        UserDefaults.standard.removeObject(forKey: Self.savedEndpointsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentEndpointsKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedEndpointKey)
        scrubDiscoveredCredentials()
        clearCurrentConnection()
        manualAddress = ""
        manualToken = ""
        pairingCode = ""
        status = "Connections reset."
        SpotlightIndexer.removeAll()
        hapticWarning()
    }

    private func clearCurrentConnection() {
        streamRequestGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelProxyReadinessPolling()
        streamClient?.disconnect()
        streamClient = nil
        endpoint = nil
        authEndpoint = nil
        simulators = []
        selectedSimulatorID = nil
        bootingSimulatorID = nil
        simulatorLifecycleID = nil
        streamState = .idle
        lastSimulatorRefreshAt = Date.distantPast
        resetStreamPresentation()
    }

    private func scrubDiscoveredCredentials(matching endpoint: SimDeckEndpoint? = nil) {
        discovery.endpoints = discovery.endpoints.map { discovered in
            if let endpoint, !endpointsRepresentSameServer(discovered, endpoint) {
                return discovered
            }
            var scrubbed = discovered
            scrubbed.token = nil
            return scrubbed
        }
    }

    private func savePairedEndpoints(primary: SimDeckEndpoint, alternates: [SimDeckEndpoint], token: String) {
        for endpoint in Array(alternates.reversed()) + [primary] {
            var saved = endpoint
            saved.token = token
            saved.requiresPairing = false
            saveUserEndpoint(saved)
        }
    }

    private func endpointWithReusableToken(_ endpoint: SimDeckEndpoint) -> SimDeckEndpoint {
        guard endpoint.token?.nilIfBlank == nil,
              let token = reusableToken(for: endpoint) else {
            return endpoint
        }
        var endpoint = endpoint
        endpoint.token = token
        endpoint.requiresPairing = false
        return endpoint
    }

    private func reusableToken(for endpoint: SimDeckEndpoint) -> String? {
        let storedEndpoints = savedEndpoints + [self.endpoint, loadSelectedEndpoint()].compactMap(\.self)
        if let serverID = endpoint.serverID?.nilIfBlank,
           let token = storedEndpoints
            .first(where: { $0.serverID == serverID })?
            .token?
            .nilIfBlank {
            return token
        }
        if let exactToken = storedEndpoints
            .first(where: { endpointsRepresentSameServer($0, endpoint) })?
            .token?
            .nilIfBlank {
            return exactToken
        }

        guard hostCanShareSimDeckToken(endpoint.baseURL.host(percentEncoded: false)) else {
            return nil
        }
        let port = normalizedPort(for: endpoint.baseURL)
        return storedEndpoints
            .first { stored in
                stored.token?.nilIfBlank != nil
                    && normalizedPort(for: stored.baseURL) == port
                    && hostCanShareSimDeckToken(stored.baseURL.host(percentEncoded: false))
            }?
            .token?
            .nilIfBlank
    }

    private func connectionCandidates(for endpoint: SimDeckEndpoint) -> [SimDeckEndpoint] {
        let primary = endpointWithReusableToken(endpoint)
        let alternateEndpoints = preferredAlternateURLs(for: primary).map { url in
            var alternate = primary
            alternate.baseURL = url.normalizedSimDeckBaseURL()
            alternate.source = endpointSource(for: alternate.baseURL)
            alternate.alternateBaseURLs = ([primary.baseURL] + primary.alternateBaseURLs)
                .map { $0.normalizedSimDeckBaseURL() }
                .filter { $0 != alternate.baseURL }
            return endpointWithReusableToken(alternate)
        }
        return uniquedByBaseURL([primary] + alternateEndpoints)
    }

    private func preferredAlternateURLs(for endpoint: SimDeckEndpoint) -> [URL] {
        let urls = endpoint.alternateBaseURLs.filter { $0 != endpoint.baseURL }
        let preferred = urls.sorted {
            endpointSourceRank(endpointSource(for: $0)) < endpointSourceRank(endpointSource(for: $1))
        }
        return preferred
    }

    private func endpointSource(for url: URL) -> EndpointSource {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return .manual
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 && parts[0] == 100 && (parts[1] & 0b1100_0000) == 0b0100_0000 {
            return .tailscale
        }
        if host.hasSuffix(".local") {
            return .bonjour
        }
        if hostCanShareSimDeckToken(host) {
            return .lan
        }
        return .manual
    }

    private func endpointSourceRank(_ source: EndpointSource) -> Int {
        switch source {
        case .bonjour: 0
        case .lan: 1
        case .tailscale: 2
        case .studioLink: 3
        case .manual: 4
        case .recent: 5
        }
    }

    private func endpointsRepresentSameServer(_ lhs: SimDeckEndpoint, _ rhs: SimDeckEndpoint) -> Bool {
        if let lhsHostID = lhs.normalizedHostID,
           let rhsHostID = rhs.normalizedHostID {
            return lhsHostID == rhsHostID
        }
        if let lhsID = lhs.serverID?.nilIfBlank,
           let rhsID = rhs.serverID?.nilIfBlank {
            return lhsID == rhsID
        }
        if lhs.normalizedHostID == nil,
           rhs.normalizedHostID == nil,
           let lhsHostName = lhs.normalizedHostName,
           let rhsHostName = rhs.normalizedHostName {
            return lhsHostName == rhsHostName
        }
        return lhs.baseURL == rhs.baseURL
            || lhs.alternateBaseURLs.contains(rhs.baseURL)
            || rhs.alternateBaseURLs.contains(lhs.baseURL)
    }

    private func mergedEndpoint(_ lhs: SimDeckEndpoint, _ rhs: SimDeckEndpoint) -> SimDeckEndpoint {
        let preferred = preferredEndpoint(lhs, rhs)
        let other = preferred.baseURL == lhs.baseURL ? rhs : lhs
        var merged = preferred
        merged.serverID = preferred.serverID ?? other.serverID
        merged.hostID = preferred.hostID ?? other.hostID
        merged.hostName = preferred.hostName ?? other.hostName
        merged.serverKind = preferred.serverKind ?? other.serverKind
        merged.token = preferred.token ?? other.token
        merged.preferredSimulatorID = preferred.preferredSimulatorID ?? other.preferredSimulatorID
        merged.requiresPairing = preferred.requiresPairing && other.requiresPairing
        merged.customName = lhs.customName?.nilIfBlank ?? rhs.customName?.nilIfBlank
        if let hostName = merged.hostName?.nilIfBlank {
            merged.name = hostName
        }
        merged.alternateBaseURLs = uniquedURLs(
            [lhs.baseURL, rhs.baseURL] + lhs.alternateBaseURLs + rhs.alternateBaseURLs
        )
        .filter { $0 != merged.baseURL }
        return merged
    }

    private func preferredEndpoint(_ lhs: SimDeckEndpoint, _ rhs: SimDeckEndpoint) -> SimDeckEndpoint {
        if lhs.serverKindRank != rhs.serverKindRank {
            return lhs.serverKindRank < rhs.serverKindRank ? lhs : rhs
        }
        if lhs.requiresPairing != rhs.requiresPairing {
            return lhs.requiresPairing ? rhs : lhs
        }
        if endpointSourceRank(lhs.source) != endpointSourceRank(rhs.source) {
            return endpointSourceRank(lhs.source) < endpointSourceRank(rhs.source) ? lhs : rhs
        }
        return lhs
    }

    private func uniquedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls.map({ $0.normalizedSimDeckBaseURL() }) where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    private func uniquedByBaseURL(_ endpoints: [SimDeckEndpoint]) -> [SimDeckEndpoint] {
        var seen = Set<URL>()
        var result: [SimDeckEndpoint] = []
        for endpoint in endpoints where seen.insert(endpoint.baseURL).inserted {
            result.append(endpoint)
        }
        return result
    }

    private func alternateURLs(from health: HealthResponse, fallbackPort: Int) -> [URL] {
        guard let advertiseHost = health.advertiseHost?.nilIfBlank else { return [] }
        var components = URLComponents()
        components.scheme = "http"
        components.host = advertiseHost
        components.port = health.httpPort ?? fallbackPort
        return components.url.map { [$0] } ?? []
    }

    private func normalizedPort(for url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private func hostCanShareSimDeckToken(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            return false
        }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 100 && (parts[1] & 0b1100_0000) == 0b0100_0000)
    }

    private func persistSavedEndpoints() {
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentEndpointsKey)
        guard !savedEndpoints.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.savedEndpointsKey)
            SpotlightIndexer.indexServers([])
            return
        }
        if let data = try? JSONEncoder().encode(savedEndpoints) {
            UserDefaults.standard.set(data, forKey: Self.savedEndpointsKey)
        }
        SpotlightIndexer.indexServers(savedEndpoints)
    }

    private func uniqued(_ endpoints: [SimDeckEndpoint]) -> [SimDeckEndpoint] {
        var result: [SimDeckEndpoint] = []
        for endpoint in endpoints {
            if let index = result.firstIndex(where: { endpointsRepresentSameServer($0, endpoint) }) {
                result[index] = mergedEndpoint(result[index], endpoint)
            } else {
                result.append(endpoint)
            }
        }
        return result
    }

    private func loadSelectedEndpoint() -> SimDeckEndpoint? {
        guard let data = UserDefaults.standard.data(forKey: Self.selectedEndpointKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SimDeckEndpoint.self, from: data)
    }

    private func saveSelectedEndpoint(_ endpoint: SimDeckEndpoint) {
        if let data = try? JSONEncoder().encode(endpoint) {
            UserDefaults.standard.set(data, forKey: Self.selectedEndpointKey)
        }
    }

    private static func loadStreamConfig() -> StreamConfig {
        guard let data = UserDefaults.standard.data(forKey: streamConfigKey),
              let config = try? JSONDecoder().decode(StreamConfig.self, from: data) else {
            return StreamConfig()
        }
        return config
    }

    private func saveStreamConfig(_ config: StreamConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.streamConfigKey)
        }
    }

    private static func loadHapticsEnabled() -> Bool {
        UserDefaults.standard.object(forKey: hapticsEnabledKey) as? Bool ?? true
    }

    private static func loadTouchOverlayVisible() -> Bool {
        UserDefaults.standard.object(forKey: touchOverlayVisibleKey) as? Bool ?? true
    }

    private static func loadTelemetryEnabled() -> Bool {
        UserDefaults.standard.object(forKey: telemetryEnabledKey) as? Bool ?? true
    }

    func hapticSelection() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func hapticImpact() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func hapticCrownTick() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.55)
    }

    func hapticSuccess() {
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func hapticWarning() {
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension StreamState {
    init(peerState: RTCPeerConnectionState) {
        switch peerState {
        case .connected:
            self = .connected
        case .connecting, .new:
            self = .connecting
        case .disconnected, .closed:
            self = .disconnected
        case .failed:
            self = .failed
        @unknown default:
            self = .disconnected
        }
    }
}
