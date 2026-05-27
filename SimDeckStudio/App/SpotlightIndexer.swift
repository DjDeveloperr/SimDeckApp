import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndexer {
    private static let serverDomain = "simdeck.servers"
    private static let simulatorDomainPrefix = "simdeck.simulators"

    static func indexServers(_ endpoints: [SimDeckEndpoint]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        guard !endpoints.isEmpty else {
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [serverDomain])
            return
        }
        let items = endpoints.compactMap { endpoint -> CSSearchableItem? in
            guard let url = link(for: endpoint) else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = endpoint.displayName
            attributes.contentDescription = endpoint.listSubtitle
            attributes.keywords = keywords(for: endpoint)
            attributes.contentURL = url
            return CSSearchableItem(
                uniqueIdentifier: url.absoluteString,
                domainIdentifier: serverDomain,
                attributeSet: attributes
            )
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    static func indexSimulators(_ simulators: [SimulatorMetadata], for endpoint: SimDeckEndpoint) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let domain = simulatorDomain(for: endpoint)
        guard !simulators.isEmpty else {
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            return
        }
        let items = simulators.compactMap { simulator -> CSSearchableItem? in
            guard let url = link(for: endpoint, simulator: simulator) else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = simulator.name
            attributes.contentDescription = "\(simulator.subtitle) on \(endpoint.displayName)"
            attributes.keywords = keywords(for: endpoint) + keywords(for: simulator)
            attributes.contentURL = url
            return CSSearchableItem(
                uniqueIdentifier: url.absoluteString,
                domainIdentifier: domain,
                attributeSet: attributes
            )
        }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            CSSearchableIndex.default().indexSearchableItems(items)
        }
    }

    static func removeSimulatorIndex(for endpoint: SimDeckEndpoint) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [simulatorDomain(for: endpoint)])
    }

    static func removeAll() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    private static func link(for endpoint: SimDeckEndpoint, simulator: SimulatorMetadata? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "simdeck"
        components.host = "spotlight"
        components.path = simulator == nil ? "/server" : "/simulator"
        var queryItems = [URLQueryItem(name: "server", value: endpoint.id)]
        if let simulator {
            queryItems.append(URLQueryItem(name: "udid", value: simulator.udid))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func keywords(for endpoint: SimDeckEndpoint) -> [String] {
        [
            "SimDeck",
            endpoint.displayName,
            endpoint.hostName,
            endpoint.serverKindLabel,
            endpoint.baseURL.host(percentEncoded: false)
        ]
        .compactMap { $0?.nilIfBlank }
    }

    private static func keywords(for simulator: SimulatorMetadata) -> [String] {
        [
            simulator.name,
            simulator.platform,
            simulator.runtimeName,
            simulator.deviceTypeName
        ]
        .compactMap { $0?.nilIfBlank }
    }

    private static func simulatorDomain(for endpoint: SimDeckEndpoint) -> String {
        "\(simulatorDomainPrefix).\(stableIdentifier(endpoint.id))"
    }

    private static func stableIdentifier(_ value: String) -> String {
        value
            .unicodeScalars
            .map { scalar -> String in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
            }
            .joined()
    }
}
