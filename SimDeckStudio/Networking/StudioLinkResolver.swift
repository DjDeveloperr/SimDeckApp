import Foundation

enum StudioLinkResolver {
    static func route(for url: URL) -> AppRoute? {
        if url.scheme?.lowercased() == "simdeck" {
            if let pairingLink = pairingLinkFromCustomScheme(url) {
                return .pairing(pairingLink, autoStart: shouldAutoStart(url, endpoint: pairingLink.endpoint))
            }
            if let endpoint = endpointFromCustomScheme(url) {
                return .endpoint(endpoint, autoStart: shouldAutoStart(url, endpoint: endpoint))
            }
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        if let ciSession = ciProxySession(from: url) {
            return .ciSession(ciSession, autoStart: shouldAutoStart(url) || ciSession.device?.nilIfBlank != nil)
        }
        if let endpoint = endpointFromLaunchpadURL(url) {
            return .endpoint(endpoint, autoStart: shouldAutoStart(url, endpoint: endpoint))
        }
        if let endpoint = endpointFromStudioURL(url) {
            return .endpoint(endpoint, autoStart: shouldAutoStart(url, endpoint: endpoint))
        }
        let serverID = queryValue("serverId", in: url) ?? queryValue("sid", in: url) ?? queryValue("s", in: url)
        let hostID = queryValue("hostId", in: url) ?? queryValue("hid", in: url)
        let hostName = queryValue("hostName", in: url) ?? queryValue("hname", in: url)
        let serverKind = queryValue("serverKind", in: url) ?? queryValue("kind", in: url)
        return .endpoint(
            SimDeckEndpoint(
                name: url.host ?? "SimDeck",
                baseURL: url,
                source: source(for: url.host),
                preferredSimulatorID: queryValue("device", in: url) ?? queryValue("udid", in: url),
                serverID: serverID,
                hostID: hostID,
                hostName: hostName,
                serverKind: serverKind
            ),
            autoStart: shouldAutoStart(url)
        )
    }

    static func endpointFromAddress(_ value: String, token: String? = nil) -> SimDeckEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        if let endpoint = endpointFromStudioURL(url) {
            var endpointWithToken = endpoint
            endpointWithToken.token = token?.nilIfBlank
            return endpointWithToken
        }
        return SimDeckEndpoint(
            name: url.host ?? "SimDeck",
            baseURL: url,
            source: source(for: url.host),
            token: token,
            hostID: queryValue("hostId", in: url) ?? queryValue("hid", in: url),
            hostName: queryValue("hostName", in: url) ?? queryValue("hname", in: url),
            serverKind: queryValue("serverKind", in: url) ?? queryValue("kind", in: url)
        )
    }

    private static func endpointFromCustomScheme(_ url: URL) -> SimDeckEndpoint? {
        guard url.scheme?.lowercased() == "simdeck" else { return nil }
        let serverID = queryValue("serverId", in: url) ?? queryValue("sid", in: url) ?? queryValue("s", in: url)
        let hostID = queryValue("hostId", in: url) ?? queryValue("hid", in: url)
        let hostName = queryValue("hostName", in: url) ?? queryValue("hname", in: url)
        let serverKind = queryValue("serverKind", in: url) ?? queryValue("kind", in: url)
        if let rawURL = queryValue("url", in: url) ?? queryValue("u", in: url),
           var endpoint = endpointFromAddress(rawURL) {
            if let token = queryValue("token", in: url) {
                endpoint.token = token
            }
            endpoint.preferredSimulatorID = queryValue("device", in: url) ?? queryValue("udid", in: url)
            endpoint.serverID = serverID
            endpoint.hostID = hostID ?? endpoint.hostID
            endpoint.hostName = hostName ?? endpoint.hostName
            endpoint.serverKind = serverKind ?? endpoint.serverKind
            return endpoint
        }
        guard let host = queryValue("host", in: url) ?? url.host else { return nil }
        let port = queryValue("port", in: url).flatMap(Int.init)
        var components = URLComponents()
        components.scheme = queryValue("scheme", in: url) ?? "http"
        components.host = host
        components.port = port
        guard let baseURL = components.url else { return nil }
        return SimDeckEndpoint(
            name: host,
            baseURL: baseURL,
            source: source(for: host),
            token: queryValue("token", in: url),
            preferredSimulatorID: queryValue("device", in: url) ?? queryValue("udid", in: url),
            serverID: serverID,
            hostID: hostID,
            hostName: hostName,
            serverKind: serverKind
        )
    }

    private static func pairingLinkFromCustomScheme(_ url: URL) -> SimDeckPairingLink? {
        guard url.scheme?.lowercased() == "simdeck",
              ["pair", "pairing"].contains(url.host?.lowercased() ?? "") else {
            return nil
        }
        guard var endpoint = endpointFromCustomScheme(url) else { return nil }
        let pairingCode = queryValue("code", in: url) ?? queryValue("pairingCode", in: url) ?? queryValue("c", in: url)
        let serverID = queryValue("serverId", in: url) ?? queryValue("sid", in: url) ?? queryValue("s", in: url)
        endpoint.serverID = endpoint.serverID ?? serverID
        if endpoint.token == nil {
            endpoint.token = queryValue("token", in: url)
        }
        let alternateEndpoints = alternateEndpointValues(in: url).compactMap { rawValue -> SimDeckEndpoint? in
            guard var alternate = endpointFromAddress(rawValue, token: endpoint.token) else { return nil }
            alternate.preferredSimulatorID = endpoint.preferredSimulatorID
            alternate.serverID = endpoint.serverID
            alternate.hostID = endpoint.hostID
            alternate.hostName = endpoint.hostName
            alternate.serverKind = endpoint.serverKind
            return alternate
        }
        .filter { $0.baseURL != endpoint.baseURL }
        return SimDeckPairingLink(
            endpoint: endpoint,
            pairingCode: pairingCode,
            alternateEndpoints: uniquedEndpoints(alternateEndpoints)
        )
    }

    private static func endpointFromStudioURL(_ url: URL) -> SimDeckEndpoint? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let simulatorIndex = parts.firstIndex(of: "simulator"),
              parts.indices.contains(simulatorIndex + 1) else {
            return nil
        }
        let previewID = parts[simulatorIndex + 1]
        guard !previewID.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/provider-sessions/\(previewID)/simdeck"
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else { return nil }
        return SimDeckEndpoint(
            name: "Studio \(previewID)",
            baseURL: baseURL,
            source: .studioLink,
            token: queryValue("simdeckToken", in: url) ?? queryValue("token", in: url),
            preferredSimulatorID: queryValue("device", in: url) ?? queryValue("udid", in: url),
            serverID: queryValue("serverId", in: url) ?? queryValue("sid", in: url) ?? queryValue("s", in: url),
            hostID: queryValue("hostId", in: url) ?? queryValue("hid", in: url),
            hostName: queryValue("hostName", in: url) ?? queryValue("hname", in: url),
            serverKind: queryValue("serverKind", in: url) ?? queryValue("kind", in: url)
        )
    }

    /// Parses Universal Links served by the launchpad at https://app.simdeck.sh.
    ///
    /// The launchpad lets a user (or agent) build a deeplink that targets a specific
    /// simdeck server + simulator, and then either opens the iOS app via a universal
    /// link or hands a `simdeck://` URL off to whatever tool is forwarding the link
    /// (Codex/Claude/etc.). The launchpad URL carries the *target* host as query
    /// params; the URL host itself is always `app.simdeck.sh` and should never be
    /// used as the endpoint base.
    ///
    /// Recognized paths: `/open`, `/connect`, `/pair`. Required params: `host`.
    /// Optional: `port`, `scheme` (default `http`), `udid`/`device`, `serverId`/`sid`/`s`,
    /// `hostId`/`hid`, `hostName`/`hname`, `serverKind`/`kind`, `token`, plus `code`/`pairingCode`
    /// when path is `/pair`.
    private static func endpointFromLaunchpadURL(_ url: URL) -> SimDeckEndpoint? {
        guard isLaunchpadHost(url.host(percentEncoded: false)) else { return nil }
        let path = url.path.lowercased()
        let isOpenPath = path.hasPrefix("/open") || path.hasPrefix("/connect") || path.hasPrefix("/pair")
        guard isOpenPath else { return nil }
        guard let targetHost = queryValue("host", in: url)?.nilIfBlank else { return nil }
        let scheme = (queryValue("scheme", in: url)?.lowercased()).flatMap { value in
            ["http", "https"].contains(value) ? value : nil
        } ?? "http"
        let port = queryValue("port", in: url).flatMap(Int.init)
        var components = URLComponents()
        components.scheme = scheme
        components.host = targetHost
        components.port = port
        guard let baseURL = components.url else { return nil }
        let serverID = queryValue("serverId", in: url) ?? queryValue("sid", in: url) ?? queryValue("s", in: url)
        let hostID = queryValue("hostId", in: url) ?? queryValue("hid", in: url)
        let hostName = queryValue("hostName", in: url) ?? queryValue("hname", in: url)
        let serverKind = queryValue("serverKind", in: url) ?? queryValue("kind", in: url)
        let token = queryValue("token", in: url) ?? queryValue("simdeckToken", in: url)
        return SimDeckEndpoint(
            name: hostName?.nilIfBlank ?? targetHost,
            baseURL: baseURL,
            source: source(for: targetHost),
            token: token,
            preferredSimulatorID: queryValue("device", in: url) ?? queryValue("udid", in: url),
            serverID: serverID,
            hostID: hostID,
            hostName: hostName,
            serverKind: serverKind
        )
    }

    private static func isLaunchpadHost(_ host: String?) -> Bool {
        host?.lowercased() == "app.simdeck.sh"
    }

    private static func ciProxySession(from url: URL) -> CIProxySession? {
        guard isCIProxyHost(url.host(percentEncoded: false)),
              let encodedRedirect = queryValue("redirect", in: url),
              let decodedData = encodedRedirect.base64URLDecodedData,
              let decodedValue = String(data: decodedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodedValue.isEmpty else {
            return nil
        }

        if decodedValue.hasPrefix("http://") || decodedValue.hasPrefix("https://") {
            return ciProxySession(fromDecodedURLString: decodedValue)
        }

        guard let payloadData = decodedValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CIProxySessionPayload.self, from: payloadData),
              payload.v == 1,
              let upstream = normalizedCIUpstream(payload.upstream) else {
            return nil
        }

        let device = queryValue("device", in: url) ?? payload.device
        return CIProxySession(
            upstream: upstream,
            token: payload.token?.nilIfBlank,
            tokenCipher: payload.tokenCipher,
            device: device,
            platform: payload.platform,
            repo: payload.repo,
            pr: payload.pr,
            runID: payload.runId,
            expiresAt: payload.expiresAt
        )
    }

    private static func ciProxySession(fromDecodedURLString value: String) -> CIProxySession? {
        guard let components = URLComponents(string: value),
              let url = components.url,
              let upstream = normalizedCIUpstream(url.absoluteString) else {
            return nil
        }
        let token = components.queryItems?.first { $0.name == "simdeckToken" }?.value?.nilIfBlank
        let device = components.queryItems?.first { $0.name == "device" }?.value?.nilIfBlank
        return CIProxySession(
            upstream: upstream,
            token: token,
            tokenCipher: nil,
            device: device,
            platform: nil,
            repo: nil,
            pr: nil,
            runID: nil,
            expiresAt: nil
        )
    }

    private static func normalizedCIUpstream(_ value: String?) -> URL? {
        guard let value, var components = URLComponents(string: value) else { return nil }
        guard components.scheme?.lowercased() == "https", components.host?.nilIfBlank != nil else {
            return nil
        }
        components.path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isCIProxyHost(_ host: String?) -> Bool {
        host?.lowercased() == "ci.simdeck.sh"
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value?
            .nilIfBlank
    }

    private static func queryValues(_ name: String, in url: URL) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == name }
            .compactMap { $0.value?.nilIfBlank } ?? []
    }

    private static func alternateEndpointValues(in url: URL) -> [String] {
        queryValues("alt", in: url)
            + queryValues("a", in: url)
            + Array(queryValues("url", in: url).dropFirst())
            + queryValues("lan", in: url)
            + queryValues("tailscale", in: url)
    }

    private static func shouldAutoStart(_ url: URL, endpoint: SimDeckEndpoint? = nil) -> Bool {
        if let explicitValue = queryValue("autoStart", in: url)
            ?? queryValue("autostart", in: url)
            ?? queryValue("start", in: url)
            ?? queryValue("open", in: url) {
            return ["1", "true", "yes", "y", "on"].contains(explicitValue.lowercased())
        }
        return endpoint?.preferredSimulatorID?.nilIfBlank != nil
            || queryValue("device", in: url) != nil
            || queryValue("udid", in: url) != nil
    }

    private static func uniquedEndpoints(_ endpoints: [SimDeckEndpoint]) -> [SimDeckEndpoint] {
        var seen = Set<URL>()
        var result: [SimDeckEndpoint] = []
        for endpoint in endpoints where seen.insert(endpoint.baseURL).inserted {
            result.append(endpoint)
        }
        return result
    }

    private static func source(for host: String?) -> EndpointSource {
        guard let host, isTailscaleIPv4Host(host) else { return .manual }
        return .tailscale
    }

    private static func isTailscaleIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (parts[1] & 0b1100_0000) == 0b0100_0000
    }
}

private struct CIProxySessionPayload: Decodable {
    let v: Int
    let upstream: String
    let token: String?
    let tokenCipher: CIProxyTokenCipher?
    let device: String?
    let platform: String?
    let repo: String?
    let pr: String?
    let runId: String?
    let expiresAt: String?
}
