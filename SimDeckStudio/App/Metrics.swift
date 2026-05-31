import Foundation

enum MetricsEvent: String {
    case appLaunched = "app_launched"
    case serverConnected = "server_connected"
    case serverConnectionFailed = "server_connection_failed"
    case serverPairingRequired = "server_pairing_required"
    case serverPaired = "server_paired"
    case serverPairFailed = "server_pair_failed"
    case simulatorSelected = "simulator_selected"
    case simulatorBootRequested = "simulator_boot_requested"
    case simulatorBooted = "simulator_booted"
    case simulatorBootFailed = "simulator_boot_failed"
    case simulatorCreated = "simulator_created"
    case simulatorCreateFailed = "simulator_create_failed"
    case streamConnected = "stream_connected"
    case streamConnectFailed = "stream_connect_failed"
    case softwareKeyboardToggled = "software_keyboard_toggled"
    case devToolsOpened = "devtools_opened"
    case devToolsTargetOpened = "devtools_target_opened"
}

enum Metrics {
    private static let projectToken = "c92391dd021671a6309b17b4b4408d34"
    private static let enabledKey = "telemetryEnabled"
    private static let distinctIDKey = "telemetryDistinctID"
    private static let sessionID = UUID().uuidString
    private static let endpoint = URL(string: "https://api.mixpanel.com/track?ip=0")!

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if !enabled {
            UserDefaults.standard.removeObject(forKey: distinctIDKey)
        }
    }

    static func track(_ event: MetricsEvent, properties: [String: Any] = [:]) {
        guard isEnabled else { return }

        var eventProperties = commonProperties()
        properties.forEach { key, value in
            if isAllowedPropertyValue(value) {
                eventProperties[key] = value
            }
        }

        let eventPayload: [String: Any] = [
            "event": event.rawValue,
            "properties": eventProperties
        ]
        let payload = [eventPayload]

        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        URLSession.shared.dataTask(with: request).resume()
    }

    static func endpointProperties(_ endpoint: SimDeckEndpoint?) -> [String: Any] {
        guard let endpoint else { return [:] }
        return [
            "server_kind": endpoint.metricsServerKind,
            "endpoint_source": endpoint.source.rawValue,
            "uses_cloud_proxy": endpoint.usesCloudProxy
        ]
    }

    static func simulatorProperties(_ simulator: SimulatorMetadata?) -> [String: Any] {
        guard let simulator else { return [:] }
        return [
            "simulator_platform": simulator.metricsPlatform,
            "simulator_family": simulator.metricsFamily,
            "simulator_booted": simulator.isBooted
        ]
    }

    static func errorKind(_ error: Error) -> String {
        if let apiError = error as? SimDeckAPIError {
            switch apiError {
            case .authRequired:
                return "auth_required"
            case .invalidResponse:
                return "invalid_response"
            case let .requestFailed(status, _):
                return "http_\(status)"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "network_\(nsError.code)"
        }
        return "unknown"
    }

    private static func commonProperties() -> [String: Any] {
        [
            "token": projectToken,
            "distinct_id": distinctID(),
            "$insert_id": UUID().uuidString,
            "time": Int(Date().timeIntervalSince1970),
            "platform": "ios",
            "event_source": "simdeck_ios",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build_number": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "build_configuration": buildConfiguration,
            "telemetry_schema": 1,
            "session_id": sessionID
        ]
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func distinctID() -> String {
        if let existing = UserDefaults.standard.string(forKey: distinctIDKey), !existing.isEmpty {
            return existing
        }
        let newID = "simdeck-ios-\(UUID().uuidString)"
        UserDefaults.standard.set(newID, forKey: distinctIDKey)
        return newID
    }

    private static func isAllowedPropertyValue(_ value: Any) -> Bool {
        switch value {
        case is String, is Bool, is Int, is Double, is Float:
            return true
        default:
            return false
        }
    }
}

private extension SimDeckEndpoint {
    var metricsServerKind: String {
        serverKind?.normalizedSimDeckServerKind ?? "unknown"
    }
}

private extension SimulatorMetadata {
    var metricsPlatform: String {
        let metadata = [
            platform,
            runtimeIdentifier,
            runtimeName,
            deviceTypeIdentifier,
            deviceTypeName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if android != nil || metadata.contains("android") {
            return "android"
        }
        if metadata.contains("tvos") || metadata.contains("apple-tv") || metadata.contains("apple tv") {
            return "tvos"
        }
        if metadata.contains("watchos") || metadata.contains("apple-watch") || metadata.contains("apple watch") {
            return "watchos"
        }
        if metadata.contains("xros") || metadata.contains("vision") {
            return "visionos"
        }
        if metadata.contains("ios") || metadata.contains("iphone") || metadata.contains("ipad") {
            return "ios"
        }
        return "unknown"
    }

    var metricsFamily: String {
        let metadata = [
            platform,
            runtimeIdentifier,
            runtimeName,
            deviceTypeIdentifier,
            deviceTypeName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if android != nil || metadata.contains("android") {
            return "android"
        }
        if metadata.contains("apple-tv") || metadata.contains("apple tv") || metadata.contains("tvos") {
            return "apple_tv"
        }
        if metadata.contains("apple-watch") || metadata.contains("apple watch") || metadata.contains("watchos") {
            return "apple_watch"
        }
        if metadata.contains("vision") || metadata.contains("xros") {
            return "apple_vision"
        }
        if metadata.contains("ipad") {
            return "ipad"
        }
        if metadata.contains("iphone") || metricsPlatform == "ios" {
            return "iphone"
        }
        return "unknown"
    }
}
