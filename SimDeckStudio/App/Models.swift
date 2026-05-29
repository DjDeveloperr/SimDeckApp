import Foundation

enum EndpointSource: String, Codable, CaseIterable, Sendable {
    case bonjour
    case lan
    case tailscale
    case manual
    case studioLink
    case recent

    var label: String {
        switch self {
        case .bonjour: "Bonjour"
        case .lan: "LAN"
        case .tailscale: "Tailscale"
        case .manual: "Manual"
        case .studioLink: "Studio"
        case .recent: "Recent"
        }
    }

    var systemImage: String {
        switch self {
        case .bonjour: "dot.radiowaves.left.and.right"
        case .lan: "network"
        case .tailscale: "point.3.connected.trianglepath.dotted"
        case .manual: "link"
        case .studioLink: "cloud"
        case .recent: "clock"
        }
    }
}

struct SimDeckEndpoint: Identifiable, Hashable, Codable, Sendable {
    var id: String { hostIdentityKey ?? serverID ?? baseURL.absoluteString }

    var name: String
    var baseURL: URL
    var source: EndpointSource
    var token: String?
    var requiresPairing: Bool
    var preferredSimulatorID: String?
    var serverID: String?
    var hostID: String?
    var hostName: String?
    var customName: String?
    var serverKind: String?
    var alternateBaseURLs: [URL]

    var displayName: String {
        customName?.nilIfBlank ?? hostName?.nilIfBlank ?? name
    }

    var listSubtitle: String {
        var parts: [String] = []
        if let label = serverKindLabel {
            parts.append(label)
        }
        let count = allBaseURLs.count
        if count > 1 || hostName?.nilIfBlank != nil {
            parts.append(count == 1 ? "1 address" : "\(count) addresses")
        } else if let host = baseURL.host(percentEncoded: false)?.nilIfBlank {
            parts.append(host)
        } else {
            parts.append(baseURL.absoluteString)
        }
        if requiresPairing {
            parts.append("Pairing required")
        }
        return parts.joined(separator: " • ")
    }

    var allBaseURLs: [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in ([baseURL] + alternateBaseURLs).map({ $0.normalizedSimDeckBaseURL() }) where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    var hostIdentityKey: String? {
        if let hostID = normalizedHostID {
            return "host-id:\(hostID)"
        }
        if let hostName = normalizedHostName {
            return "host-name:\(hostName)"
        }
        return nil
    }

    var hostIdentityKeys: Set<String> {
        if let hostID = normalizedHostID {
            return ["host-id:\(hostID)"]
        }
        if let hostName = normalizedHostName {
            return ["host-name:\(hostName)"]
        }
        return []
    }

    var normalizedHostID: String? {
        hostID?.nilIfBlank?.lowercased()
    }

    var normalizedHostName: String? {
        hostName?.normalizedSimDeckHostName
    }

    var serverKindRank: Int {
        switch serverKind?.normalizedSimDeckServerKind {
        case "launchagent":
            return 0
        case "foreground":
            return 1
        case "workspace":
            return 2
        case "standalone":
            return 3
        default:
            return 4
        }
    }

    init(
        name: String,
        baseURL: URL,
        source: EndpointSource,
        token: String? = nil,
        requiresPairing: Bool = false,
        preferredSimulatorID: String? = nil,
        serverID: String? = nil,
        hostID: String? = nil,
        hostName: String? = nil,
        serverKind: String? = nil,
        alternateBaseURLs: [URL] = []
    ) {
        let normalizedBaseURL = baseURL.normalizedSimDeckBaseURL()
        self.name = name
        self.baseURL = normalizedBaseURL
        self.source = source
        self.token = token?.nilIfBlank
        self.requiresPairing = requiresPairing
        self.preferredSimulatorID = preferredSimulatorID?.nilIfBlank
        self.serverID = serverID?.nilIfBlank
        self.hostID = hostID?.nilIfBlank
        self.hostName = hostName?.nilIfBlank
        self.serverKind = serverKind?.nilIfBlank
        self.alternateBaseURLs = alternateBaseURLs
            .map { $0.normalizedSimDeckBaseURL() }
            .filter { $0 != normalizedBaseURL }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case baseURL
        case source
        case token
        case requiresPairing
        case preferredSimulatorID
        case serverID
        case hostID = "hostId"
        case hostName
        case serverKind
        case alternateBaseURLs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            baseURL: try container.decode(URL.self, forKey: .baseURL),
            source: try container.decode(EndpointSource.self, forKey: .source),
            token: try container.decodeIfPresent(String.self, forKey: .token),
            requiresPairing: try container.decodeIfPresent(Bool.self, forKey: .requiresPairing) ?? false,
            preferredSimulatorID: try container.decodeIfPresent(String.self, forKey: .preferredSimulatorID),
            serverID: try container.decodeIfPresent(String.self, forKey: .serverID),
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID),
            hostName: try container.decodeIfPresent(String.self, forKey: .hostName),
            serverKind: try container.decodeIfPresent(String.self, forKey: .serverKind),
            alternateBaseURLs: try container.decodeIfPresent([URL].self, forKey: .alternateBaseURLs) ?? []
        )
    }

    var serverKindLabel: String? {
        switch serverKind?.normalizedSimDeckServerKind {
        case "launchagent":
            return "LaunchAgent"
        case "foreground":
            return "Foreground"
        case "workspace":
            return "Workspace"
        case "standalone":
            return "Standalone"
        default:
            return nil
        }
    }

    var usesCloudProxy: Bool {
        if serverKind?.normalizedSimDeckServerKind == "cloudflareproxy" {
            return true
        }
        return baseURL.host(percentEncoded: false)?.lowercased().hasSuffix(".workers.dev") == true
    }
}

struct SimulatorMetadata: Identifiable, Hashable, Decodable, Sendable {
    var id: String { udid }

    let udid: String
    let name: String
    let platform: String?
    let runtimeIdentifier: String?
    let runtimeName: String?
    let deviceTypeIdentifier: String?
    let deviceTypeName: String?
    let isBooted: Bool
    let android: AndroidSimulatorInfo?
    let privateDisplay: PrivateDisplayInfo?

    var subtitle: String {
        [runtimeName, deviceTypeName]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    var systemImage: String {
        let metadata = [
            platform,
            runtimeIdentifier,
            runtimeName,
            deviceTypeIdentifier,
            deviceTypeName,
            name
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if metadata.contains("apple-tv") || metadata.contains("apple tv") || metadata.contains("tvos") {
            return "appletv"
        }
        if metadata.contains("apple-watch") || metadata.contains("apple watch") || metadata.contains("watchos") {
            return "applewatch"
        }
        if metadata.contains("ipad") {
            return "ipad"
        }
        if metadata.contains("vision") || metadata.contains("xros") {
            return "visionpro"
        }
        if metadata.contains("mac") {
            return "macbook"
        }
        if metadata.contains("android") || metadata.contains("pixel") {
            return "rectangle.portrait"
        }
        return "iphone.gen3"
    }

    var isIPhone: Bool {
        let metadata = [platform, runtimeIdentifier, runtimeName, deviceTypeIdentifier, deviceTypeName, name]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if metadata.contains("ipad") || metadata.contains("apple-tv") || metadata.contains("apple tv")
            || metadata.contains("tvos") || metadata.contains("apple-watch") || metadata.contains("apple watch")
            || metadata.contains("watchos") || metadata.contains("vision") || metadata.contains("xros")
            || metadata.contains("macbook") || metadata.contains("imac") || metadata.contains("android") {
            return false
        }
        return metadata.contains("iphone") || metadata.contains("ios")
    }
}

struct ChromeDevToolsTargetDiscovery: Decodable, Sendable {
    let udid: String
    let targets: [ChromeDevToolsTarget]
    let warnings: [String]
}

struct ChromeDevToolsTarget: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    let title: String
    let type: String
    let url: String
    let description: String
    let devtoolsFrontendUrl: String
    let webSocketDebuggerUrl: String
    let source: String
    let processIdentifier: Int
    let bundleIdentifier: String?
    let appName: String?
}

struct WebKitTargetDiscovery: Decodable, Sendable {
    let udid: String
    let socketPath: String?
    let targets: [WebKitTarget]
    let warnings: [String]
}

struct WebKitTarget: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    let appId: String
    let appName: String?
    let appActive: Bool
    let pageActive: Bool
    let pageId: Int
    let title: String?
    let url: String?
    let kind: String
    let inspectorUrl: String
    let webSocketUrl: String
}

struct AndroidSimulatorInfo: Hashable, Decodable, Sendable {
    let avdName: String?
    let grpcPort: Int?
    let serial: String?
}

struct PrivateDisplayInfo: Hashable, Decodable, Sendable {
    let displayReady: Bool
    let displayStatus: String
    let displayWidth: Int
    let displayHeight: Int
}

struct StreamDiagnostics: Hashable, Sendable {
    var codec: String = ""
    var width: UInt64 = 0
    var height: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var decodedFrames: UInt64 = 0
    var renderedFrames: UInt64 = 0
    var decoderDroppedFrames: UInt64 = 0
    var presentationDroppedFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var packetsLost: UInt64 = 0
    var latestPacketGapMs: Double = 0
    var latestFrameGapMs: Double = 0
    var packetFps: Double = 0
    var decodedFps: Double = 0
    var renderedFps: Double = 0
    var peerConnectionState: String = ""
    var iceConnectionState: String = ""
    var iceGatheringState: String = ""
    var signalingState: String = ""
    var selectedCandidatePair: String = ""
    var timestamp = Date()

    init() {}

    init(stats: [String: Any]) {
        codec = stats["codec"] as? String ?? ""
        width = StreamDiagnostics.uintValue(stats["width"])
        height = StreamDiagnostics.uintValue(stats["height"])
        receivedPackets = StreamDiagnostics.uintValue(stats["receivedPackets"])
        decodedFrames = StreamDiagnostics.uintValue(stats["decodedFrames"])
        renderedFrames = StreamDiagnostics.uintValue(stats["renderedFrames"])
        decoderDroppedFrames = StreamDiagnostics.uintValue(stats["decoderDroppedFrames"])
        presentationDroppedFrames = StreamDiagnostics.uintValue(stats["presentationDroppedFrames"])
        droppedFrames = StreamDiagnostics.uintValue(stats["droppedFrames"])
        if decoderDroppedFrames == 0 {
            decoderDroppedFrames = droppedFrames
        }
        packetsLost = StreamDiagnostics.uintValue(stats["packetsLost"])
        latestPacketGapMs = StreamDiagnostics.doubleValue(stats["latestPacketGapMs"])
        latestFrameGapMs = StreamDiagnostics.doubleValue(stats["latestFrameGapMs"])
        packetFps = StreamDiagnostics.doubleValue(stats["packetFps"])
        decodedFps = StreamDiagnostics.doubleValue(stats["decodedFps"])
        renderedFps = StreamDiagnostics.doubleValue(stats["appFps"])
        peerConnectionState = stats["peerConnectionState"] as? String ?? stats["status"] as? String ?? ""
        iceConnectionState = stats["iceConnectionState"] as? String ?? ""
        iceGatheringState = stats["iceGatheringState"] as? String ?? ""
        signalingState = stats["signalingState"] as? String ?? ""
        selectedCandidatePair = stats["selectedCandidatePair"] as? String ?? ""
        timestamp = Date()
    }

    private static func uintValue(_ value: Any?) -> UInt64 {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? UInt {
            return UInt64(value)
        }
        if let value = value as? Int {
            return UInt64(max(value, 0))
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return 0
    }
}

struct ChromeProfile: Hashable, Codable, Sendable {
    let totalWidth: Double
    let totalHeight: Double
    let screenX: Double
    let screenY: Double
    let screenWidth: Double
    let screenHeight: Double
    let contentX: Double?
    let contentY: Double?
    let contentWidth: Double?
    let contentHeight: Double?
    let cornerRadius: Double
    let chromeStyle: String?
    let hasScreenMask: Bool?
    let buttons: [ChromeButtonProfile]?

    var assetStamp: String {
        var parts = [
            totalWidth,
            totalHeight,
            screenX,
            screenY,
            screenWidth,
            screenHeight,
            contentX ?? 0,
            contentY ?? 0,
            contentWidth ?? 0,
            contentHeight ?? 0,
            cornerRadius
        ]
            .map { value in
                Self.stampValue(value)
            }
        parts.append(hasScreenMask == true ? "mask" : "nomask")
        parts.append(contentsOf: (buttons ?? [])
            .sorted { $0.name < $1.name }
            .map(\.assetStamp))
        return parts.joined(separator: "x")
    }

    private static func stampValue(_ value: Double) -> String {
        value.isFinite ? String(Int((value * 1000).rounded())) : "0"
    }
}

struct ChromeButtonProfile: Hashable, Codable, Sendable {
    let name: String
    let label: String?
    let type: String?
    let imageName: String?
    let imageDownName: String?
    let imageDownDrawMode: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let anchor: String?
    let align: String?
    let usagePage: Int?
    let usage: Int?
    let onTop: Bool?
    let normalOffset: ChromeButtonOffset?
    let rolloverOffset: ChromeButtonOffset?

    var assetStamp: String {
        [
            sanitized(name),
            sanitized(type),
            sanitized(imageName),
            sanitized(imageDownName),
            sanitized(imageDownDrawMode),
            sanitized(anchor),
            sanitized(align),
            onTop == true ? "top" : "under",
            stampValue(x),
            stampValue(y),
            stampValue(width),
            stampValue(height),
            stampValue(normalOffset?.x ?? 0),
            stampValue(normalOffset?.y ?? 0),
            stampValue(rolloverOffset?.x ?? 0),
            stampValue(rolloverOffset?.y ?? 0),
            usagePage.map(String.init) ?? "",
            usage.map(String.init) ?? ""
        ].joined(separator: ".")
    }

    private func stampValue(_ value: Double) -> String {
        value.isFinite ? String(Int((value * 1000).rounded())) : "0"
    }

    private func sanitized(_ value: String?) -> String {
        (value ?? "").map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
                ? character
                : "_"
        }
        .reduce(into: "") { $0.append($1) }
    }
}

struct ChromeButtonOffset: Hashable, Codable, Sendable {
    let x: Double
    let y: Double
}

struct SimulatorsResponse: Decodable, Sendable {
    let simulators: [SimulatorMetadata]
    let proxyStatus: String?
    let statusMessage: String?
    let runId: String?
    let runUrl: String?
}

struct SimulatorDeviceTypeOption: Identifiable, Hashable, Decodable, Sendable {
    var id: String { identifier }

    let identifier: String
    let name: String
    let productFamily: String?
    let supportedRuntimeIdentifiers: [String]?
}

struct SimulatorRuntimeOption: Identifiable, Hashable, Decodable, Sendable {
    var id: String { identifier }

    let identifier: String
    let name: String
    let platform: String?
    let isAvailable: Bool?
    let supportedDeviceTypeIdentifiers: [String]?
}

struct AndroidEmulatorDeviceTypeOption: Identifiable, Hashable, Decodable, Sendable {
    var id: String { identifier }

    let identifier: String
    let name: String
    let oem: String?
    let tag: String?
}

struct AndroidEmulatorSystemImageOption: Identifiable, Hashable, Decodable, Sendable {
    var id: String { identifier }

    let identifier: String
    let name: String
    let description: String?
    let apiLevel: Int?
    let tag: String?
    let abi: String?
}

struct AndroidEmulatorCreateOptions: Hashable, Decodable, Sendable {
    let deviceTypes: [AndroidEmulatorDeviceTypeOption]
    let systemImages: [AndroidEmulatorSystemImageOption]
    let unavailableReason: String?
}

struct SimulatorCreateOptionsResponse: Hashable, Decodable, Sendable {
    let deviceTypes: [SimulatorDeviceTypeOption]
    let runtimes: [SimulatorRuntimeOption]
    let android: AndroidEmulatorCreateOptions?
}

struct CreatePairedWatchRequest: Encodable, Hashable, Sendable {
    let name: String
    let deviceTypeIdentifier: String
    let runtimeIdentifier: String?
}

struct CreateSimulatorRequest: Encodable, Hashable, Sendable {
    let platform: String?
    let name: String
    let deviceTypeIdentifier: String
    let runtimeIdentifier: String?
    let pairedWatch: CreatePairedWatchRequest?
}

struct CreateSimulatorResponse: Decodable, Sendable {
    let ok: Bool
    let created: CreatedSimulatorInfo
    let simulator: SimulatorMetadata
    let pairedWatchSimulator: SimulatorMetadata?
}

struct CreatedSimulatorInfo: Decodable, Sendable {
    let udid: String
    let pairedWatchUDID: String?
}

struct HealthResponse: Decodable, Sendable {
    let ok: Bool
    let serverId: String?
    let advertiseHost: String?
    let hostId: String?
    let hostName: String?
    let httpPort: Int?
    let serverKind: String?
    let videoCodec: String?
    let realtimeStream: Bool?
    let webRtc: WebRTCConfigurationResponse?
    let proxyStatus: String?
    let statusMessage: String?
    let runId: String?
    let runUrl: String?
}

struct WebRTCConfigurationResponse: Decodable, Sendable {
    let iceServers: [IceServer]?
    let iceTransportPolicy: String?
}

struct IceServer: Hashable, Decodable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?

    enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urls = try? container.decode([String].self, forKey: .urls) {
            self.urls = urls
        } else {
            self.urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct WebRTCVideoMetadata: Decodable, Sendable {
    let width: Int
    let height: Int
}

struct WebRTCAnswerPayload: Decodable, Sendable {
    let sdp: String
    let type: String
    let video: WebRTCVideoMetadata?
}

enum StreamEncoder: String, CaseIterable, Codable, Hashable, Sendable {
    case auto
    case hardware
    case software

    var label: String {
        switch self {
        case .auto: "Auto"
        case .hardware: "Hardware"
        case .software: "Software"
        }
    }
}

enum StreamQualityPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case auto
    case full
    case balanced
    case economy
    case low
    case tiny

    var label: String {
        switch self {
        case .auto: "Auto"
        case .full: "Full"
        case .balanced: "1280"
        case .economy: "1080"
        case .low: "720"
        case .tiny: "540"
        }
    }

    var summaryLabel: String {
        switch self {
        case .auto: "Auto"
        case .full: "Full res"
        case .balanced: "1280px"
        case .economy: "1080px"
        case .low: "720px"
        case .tiny: "540px"
        }
    }

    var payloadProfile: String {
        self == .auto ? StreamQualityPreset.economy.rawValue : rawValue
    }
}

struct StreamConfig: Codable, Hashable, Sendable {
    var encoder: StreamEncoder = .auto
    var fps: Int = 60
    var quality: StreamQualityPreset = .full

    var summary: String {
        "WebRTC / \(quality.summaryLabel) / \(fps) fps"
    }

    var cloudProxyDefault: StreamConfig {
        var config = self
        config.encoder = .software
        if config.fps > 30 {
            config.fps = 30
        }
        if config.quality == .auto || config.quality == .full {
            config.quality = .economy
        }
        return config
    }
}

struct StreamQualityPayload: Encodable, Sendable {
    var profile: String
    var fps: Int
    var videoCodec: String

    init(config: StreamConfig = StreamConfig()) {
        profile = config.quality.payloadProfile
        fps = config.fps
        videoCodec = config.encoder.rawValue
    }

    var jsonObject: [String: Any] {
        [
            "profile": profile,
            "fps": fps,
            "videoCodec": videoCodec
        ]
    }
}

struct WebRTCOfferPayload: Encodable, Sendable {
    let clientId: String
    let sdp: String
    let streamConfig: StreamQualityPayload
    let type: String
}

enum AppRoute: Hashable, Sendable {
    case endpoint(SimDeckEndpoint, autoStart: Bool)
    case pairing(SimDeckPairingLink, autoStart: Bool)
    case ciSession(CIProxySession, autoStart: Bool)
}

struct SimDeckPairingLink: Hashable, Sendable {
    let endpoint: SimDeckEndpoint
    let pairingCode: String?
    let alternateEndpoints: [SimDeckEndpoint]
}

enum AppPresentationRequest: Hashable, Sendable {
    case pair
    case scanPairingQR
    case ciSessionPassword
}

struct CIProxyTokenCipher: Hashable, Codable, Sendable {
    let algorithm: String
    let ciphertext: String
    let iv: String
    let salt: String
}

struct CIProxySession: Hashable, Sendable {
    let upstream: URL
    let token: String?
    let tokenCipher: CIProxyTokenCipher?
    let device: String?
    let platform: String?
    let repo: String?
    let pr: String?
    let runID: String?
    let expiresAt: String?

    var requiresPassword: Bool {
        token?.nilIfBlank == nil && tokenCipher != nil
    }

    var displayName: String {
        if let repo = repo?.nilIfBlank {
            return pr?.nilIfBlank.map { "\(repo) #\($0)" } ?? repo
        }
        return "SimDeck CI"
    }

    func endpoint(token overrideToken: String? = nil) -> SimDeckEndpoint {
        SimDeckEndpoint(
            name: displayName,
            baseURL: upstream,
            source: .studioLink,
            token: overrideToken?.nilIfBlank ?? token?.nilIfBlank,
            preferredSimulatorID: device?.nilIfBlank,
            serverID: runID?.nilIfBlank.map { "github-actions-\($0)" },
            hostName: displayName,
            serverKind: "githubActions"
        )
    }
}

extension URL {
    func normalizedSimDeckBaseURL() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        if components.path != "/" {
            components.path = components.path.trimmingTrailingSlashes()
        }
        return components.url ?? self
    }
}

extension String {
    var base64URLDecodedData: Data? {
        var value = replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: value)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    var normalizedSimDeckHostName: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }
        let withoutLocal = trimmed.lowercased().hasSuffix(".local")
            ? String(trimmed.dropLast(".local".count))
            : trimmed
        return withoutLocal.split(separator: ".").first.map { String($0).lowercased() }?.nilIfBlank
    }

    var normalizedSimDeckServerKind: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
