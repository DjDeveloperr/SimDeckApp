import SwiftUI
import WebKit

private enum DevToolsPanelTarget: Identifiable, Hashable {
    case webKit(WebKitTarget)
    case chrome(ChromeDevToolsTarget)

    var id: String {
        switch self {
        case .webKit(let target):
            "webkit-\(target.id)"
        case .chrome(let target):
            "chrome-\(target.id)"
        }
    }

    var title: String {
        switch self {
        case .webKit(let target):
            target.title?.nilIfBlank ?? target.appName?.nilIfBlank ?? "WebKit Target"
        case .chrome(let target):
            target.title.nilIfBlank ?? target.appName?.nilIfBlank ?? "DevTools Target"
        }
    }

    var subtitle: String {
        switch self {
        case .webKit(let target):
            [target.appName, target.url, target.kind].compactMap { $0?.nilIfBlank }.joined(separator: " - ")
        case .chrome(let target):
            [target.source, target.appName, target.url].compactMap { $0?.nilIfBlank }.joined(separator: " - ")
        }
    }

    var systemImage: String {
        switch self {
        case .webKit:
            "safari"
        case .chrome:
            "hammer"
        }
    }

    var frontendPath: String {
        switch self {
        case .webKit(let target):
            target.inspectorUrl
        case .chrome(let target):
            target.devtoolsFrontendUrl
        }
    }

    var wrapsInFrame: Bool {
        switch self {
        case .webKit:
            true
        case .chrome:
            false
        }
    }
}

private struct DevToolsWebViewState: Equatable {
    var message: String?
    var isError = false
}

struct DevToolsPanelView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @State private var webKitTargets: [WebKitTarget] = []
    @State private var chromeTargets: [ChromeDevToolsTarget] = []
    @State private var warnings: [String] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedTarget: DevToolsPanelTarget?
    @State private var reloadID = UUID()
    @State private var loadGeneration = 0
    @State private var webViewState = DevToolsWebViewState()

    private var selectedSimulator: SimulatorMetadata? {
        model.selectedSimulator
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedTarget,
                   let endpoint = model.endpoint,
                   let url = frontendURL(for: selectedTarget, endpoint: endpoint) {
                    ZStack(alignment: .bottom) {
                        EmbeddedDevToolsWebView(
                            url: url,
                            token: endpoint.token,
                            wrapsInFrame: selectedTarget.wrapsInFrame,
                            reloadID: reloadID,
                            loadState: $webViewState
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if let message = webViewState.message {
                            Label(message, systemImage: webViewState.isError ? "exclamationmark.triangle" : "network")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(webViewState.isError ? 0.28 : 0.12))
                                }
                                .padding(10)
                        }
                    }
                } else {
                    targetList
                }
            }
            .navigationTitle(selectedTarget == nil ? "DevTools" : selectedTarget?.title ?? "DevTools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedTarget == nil ? "Done" : "Targets") {
                        if selectedTarget == nil {
                            close()
                        } else {
                            self.selectedTarget = nil
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if selectedTarget == nil {
                            Task { await loadTargets() }
                        } else {
                            reloadID = UUID()
                        }
                    } label: {
                        Label(selectedTarget == nil ? "Refresh" : "Reload", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || model.endpoint == nil || selectedSimulator == nil)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            Task { await loadTargets() }
        }
        .onChange(of: model.endpoint?.id) {
            selectedTarget = nil
            Task { await loadTargets() }
        }
        .onChange(of: model.selectedSimulatorID) {
            selectedTarget = nil
            Task { await loadTargets() }
        }
        .onChange(of: selectedTarget?.id) {
            webViewState = DevToolsWebViewState(message: "Loading inspector...", isError: false)
        }
    }

    private var targetList: some View {
        List {
            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Finding devtools targets...")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if !webKitTargets.isEmpty {
                Section("WebKit") {
                    ForEach(webKitTargets) { target in
                        targetButton(.webKit(target))
                    }
                }
            }

            if !chromeTargets.isEmpty {
                Section("Chrome / React Native") {
                    ForEach(chromeTargets) { target in
                        targetButton(.chrome(target))
                    }
                }
            }

            if !warnings.isEmpty {
                Section("Warnings") {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !isLoading, errorMessage == nil, webKitTargets.isEmpty, chromeTargets.isEmpty {
                ContentUnavailableView("No DevTools Targets", systemImage: "hammer")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func targetButton(_ target: DevToolsPanelTarget) -> some View {
        Button {
            model.hapticSelection()
            selectedTarget = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: target.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .lineLimit(1)
                    if !target.subtitle.isEmpty {
                        Text(target.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadTargets() async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let endpoint = model.endpoint, let selectedSimulator else {
            webKitTargets = []
            chromeTargets = []
            warnings = []
            errorMessage = model.endpoint == nil ? "Connect to a server first." : "Select a simulator first."
            return
        }
        isLoading = true
        errorMessage = nil
        warnings = []
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        let api = SimDeckAPI(endpoint: endpoint)
        var loadedWebKitTargets: [WebKitTarget] = []
        var loadedChromeTargets: [ChromeDevToolsTarget] = []
        var loadedWarnings: [String] = []
        do {
            let webKit = try await api.webKitTargets(udid: selectedSimulator.udid)
            loadedWebKitTargets = webKit.targets
            loadedWarnings.append(contentsOf: webKit.warnings)
        } catch {
            loadedWarnings.append("WebKit: \(error.localizedDescription)")
        }

        do {
            let chrome = try await api.chromeDevToolsTargets(udid: selectedSimulator.udid)
            loadedChromeTargets = chrome.targets
            loadedWarnings.append(contentsOf: chrome.warnings)
        } catch {
            loadedWarnings.append("Chrome / React Native: \(error.localizedDescription)")
        }

        guard generation == loadGeneration else { return }
        webKitTargets = loadedWebKitTargets
        chromeTargets = loadedChromeTargets
        warnings = loadedWarnings
        if webKitTargets.isEmpty, chromeTargets.isEmpty, warnings.isEmpty {
            errorMessage = "No inspectable targets were reported."
        }
    }

    private func frontendURL(for target: DevToolsPanelTarget, endpoint: SimDeckEndpoint) -> URL? {
        guard let absolute = URL(string: target.frontendPath, relativeTo: endpoint.baseURL)?.absoluteURL else {
            return nil
        }
        return absolute
            .addingSimDeckTokenToPageQuery(endpoint.token)
            .addingSimDeckTokenToDevToolsWebSocket(endpoint.token)
    }
}

private struct EmbeddedDevToolsWebView: UIViewRepresentable {
    private static let inspectorPageZoom = 0.86
    private static let framedInspectorScale = 0.86

    let url: URL
    let token: String?
    let wrapsInFrame: Bool
    let reloadID: UUID
    @Binding var loadState: DevToolsWebViewState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "simdeckInspector")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        webView.pageZoom = wrapsInFrame ? 1 : Self.inspectorPageZoom
        guard context.coordinator.loadedURL != url
            || context.coordinator.reloadID != reloadID
            || context.coordinator.wrapsInFrame != wrapsInFrame else {
            return
        }
        context.coordinator.loadedURL = url
        context.coordinator.reloadID = reloadID
        context.coordinator.wrapsInFrame = wrapsInFrame
        loadState = DevToolsWebViewState(message: "Loading inspector...", isError: false)
        let loadInspector = {
            if wrapsInFrame {
                webView.loadHTMLString(Self.wrapperHTML(for: url), baseURL: url)
            } else {
                var request = URLRequest(url: url)
                if let token = token?.nilIfBlank {
                    request.setValue(token, forHTTPHeaderField: "X-SimDeck-Token")
                }
                webView.load(request)
            }
        }
        if let token = token?.nilIfBlank,
           let cookie = Self.accessCookie(token: token, url: url) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                loadInspector()
            }
        } else {
            loadInspector()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "simdeckInspector")
        uiView.navigationDelegate = nil
    }

    private static func wrapperHTML(for url: URL) -> String {
        let urlLiteral = javaScriptLiteral(url.absoluteString)
        let inverseScale = 1 / framedInspectorScale
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        html, body { width: 100%; height: 100%; margin: 0; padding: 0; background: #111; }
        body { overflow: hidden; }
        iframe {
            width: \(inverseScale * 100)%;
            height: \(inverseScale * 100)%;
            margin: 0;
            padding: 0;
            border: 0;
            background: #111;
            transform: scale(\(framedInspectorScale));
            transform-origin: top left;
        }
        </style>
        </head>
        <body>
        <iframe id="inspector" allow="clipboard-read; clipboard-write"></iframe>
        <script>
        window.addEventListener("message", function(event) {
            try { window.webkit.messageHandlers.simdeckInspector.postMessage(event.data); } catch (_) {}
        });
        document.getElementById("inspector").src = \(urlLiteral);
        </script>
        </body>
        </html>
        """
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    private static func accessCookie(token: String, url: URL) -> HTTPCookie? {
        guard let host = url.host(percentEncoded: false) else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "simdeck_token",
            .value: token,
            .expires: Date().addingTimeInterval(60 * 60)
        ]
        if url.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var reloadID: UUID?
        var wrapsInFrame = false
        var loadState: Binding<DevToolsWebViewState>

        init(loadState: Binding<DevToolsWebViewState>) {
            self.loadState = loadState
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Loading inspector...", isError: false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !wrapsInFrame {
                loadState.wrappedValue = DevToolsWebViewState()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Inspector failed: \(error.localizedDescription)", isError: true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Inspector failed: \(error.localizedDescription)", isError: true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                return
            }
            if type == "simdeck:webkit-inspector:health" {
                let state = payload["state"] as? String ?? "loading"
                let reason = payload["reason"] as? String
                switch state {
                case "ready":
                    loadState.wrappedValue = DevToolsWebViewState()
                case "stalled":
                    loadState.wrappedValue = DevToolsWebViewState(
                        message: "Inspector connected, waiting for page content\(reason.map { ": \($0)" } ?? ".")",
                        isError: false
                    )
                default:
                    loadState.wrappedValue = DevToolsWebViewState(
                        message: "Inspector \(state)\(reason.map { ": \($0)" } ?? "...")",
                        isError: false
                    )
                }
            } else if type == "simdeck:webkit-inspector:socket",
                      let state = payload["state"] as? String,
                      state != "open" {
                loadState.wrappedValue = DevToolsWebViewState(message: "Inspector socket \(state)...", isError: false)
            }
        }
    }
}

private extension URL {
    func addingSimDeckTokenToPageQuery(_ token: String?) -> URL {
        guard let token = token?.nilIfBlank,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "simdeckToken" }) {
            queryItems.append(URLQueryItem(name: "simdeckToken", value: token))
        }
        components.queryItems = queryItems
        return components.url ?? self
    }

    func addingSimDeckTokenToDevToolsWebSocket(_ token: String?) -> URL {
        guard let token = token?.nilIfBlank,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              var queryItems = components.queryItems,
              let wsIndex = queryItems.firstIndex(where: { $0.name == "ws" }),
              var wsValue = queryItems[wsIndex].value,
              !wsValue.contains("simdeckToken=") else {
            return self
        }
        var tokenComponents = URLComponents()
        tokenComponents.queryItems = [URLQueryItem(name: "simdeckToken", value: token)]
        let tokenQuery = tokenComponents.percentEncodedQuery ?? "simdeckToken=\(token)"
        wsValue += wsValue.contains("?") ? "&" : "?"
        wsValue += tokenQuery
        queryItems[wsIndex] = URLQueryItem(name: "ws", value: wsValue)
        components.queryItems = queryItems
        return components.url ?? self
    }
}
