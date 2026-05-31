import SwiftUI
import UIKit
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
                        .ignoresSafeArea(.keyboard, edges: .bottom)

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
            Metrics.track(.devToolsTargetOpened, properties: Metrics.endpointProperties(model.endpoint).merging(
                Metrics.simulatorProperties(model.selectedSimulator)
            ) { current, _ in current }.merging([
                "target_kind": target.metricsKind
            ]) { current, _ in current })
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

private extension DevToolsPanelTarget {
    var metricsKind: String {
        switch self {
        case .webKit:
            return "webkit"
        case .chrome:
            return "chrome"
        }
    }
}

private struct EmbeddedDevToolsWebView: UIViewRepresentable {
    private static let inspectorPageZoom = 0.86
    private static let framedInspectorScale = 0.86

    private static let disableInputZoomScript: WKUserScript = {
        let source = """
        (function() {
            function applyViewport() {
                var metas = document.querySelectorAll('meta[name="viewport"]');
                metas.forEach(function(el) { el.parentNode && el.parentNode.removeChild(el); });
                var meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover, interactive-widget=overlays-content';
                (document.head || document.documentElement).appendChild(meta);
            }
            applyViewport();
            document.addEventListener('DOMContentLoaded', applyViewport);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }()

    let url: URL
    let token: String?
    let wrapsInFrame: Bool
    let reloadID: UUID
    @Binding var loadState: DevToolsWebViewState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "simdeckInspector")
        configuration.userContentController.addUserScript(Self.disableInputZoomScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.bouncesZoom = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInset = .zero
        webView.scrollView.verticalScrollIndicatorInsets = .zero
        webView.scrollView.horizontalScrollIndicatorInsets = .zero
        context.coordinator.observeScrollInset(of: webView.scrollView)
        context.coordinator.observeKeyboard(for: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        webView.pageZoom = wrapsInFrame ? 1 : Self.inspectorPageZoom
        webView.scrollView.setZoomScale(1, animated: false)
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
        coordinator.stopObservingScrollInset()
        coordinator.stopObservingKeyboard()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "simdeckInspector")
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.scrollView.delegate = nil
    }

    private static func wrapperHTML(for url: URL) -> String {
        let urlLiteral = javaScriptLiteral(url.absoluteString)
        let inverseScale = 1 / framedInspectorScale
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover, interactive-widget=overlays-content">
        <style>
        html, body { width: 100%; height: 100%; margin: 0; padding: 0; background: #111; }
        body { overflow: hidden; touch-action: none; }
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var loadedURL: URL?
        var reloadID: UUID?
        var wrapsInFrame = false
        var loadState: Binding<DevToolsWebViewState>
        private var reloadWorkItem: DispatchWorkItem?
        private var lastReloadAt = Date.distantPast
        private var contentInsetObservation: NSKeyValueObservation?
        private var indicatorInsetObservation: NSKeyValueObservation?
        private weak var observedWebView: WKWebView?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var savedContentOffset: CGPoint?

        init(loadState: Binding<DevToolsWebViewState>) {
            self.loadState = loadState
        }

        func observeScrollInset(of scrollView: UIScrollView) {
            contentInsetObservation = scrollView.observe(\.contentInset, options: [.new]) { sv, _ in
                if sv.contentInset != .zero {
                    sv.contentInset = .zero
                }
            }
            indicatorInsetObservation = scrollView.observe(\.verticalScrollIndicatorInsets, options: [.new]) { sv, _ in
                if sv.verticalScrollIndicatorInsets != .zero {
                    sv.verticalScrollIndicatorInsets = .zero
                }
            }
        }

        func observeKeyboard(for webView: WKWebView) {
            observedWebView = webView
            let center = NotificationCenter.default
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let webView = self.observedWebView else { return }
                self.savedContentOffset = webView.scrollView.contentOffset
            })
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restoreContentOffset()
            })
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restoreContentOffset()
            })
        }

        private func restoreContentOffset() {
            guard let webView = observedWebView else { return }
            webView.scrollView.contentInset = .zero
            webView.scrollView.verticalScrollIndicatorInsets = .zero
            let target = savedContentOffset ?? .zero
            if webView.scrollView.contentOffset != target {
                webView.scrollView.setContentOffset(target, animated: false)
            }
            savedContentOffset = nil
        }

        func stopObservingKeyboard() {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            keyboardObservers.removeAll()
            observedWebView = nil
            savedContentOffset = nil
        }

        func stopObservingScrollInset() {
            contentInsetObservation?.invalidate()
            contentInsetObservation = nil
            indicatorInsetObservation?.invalidate()
            indicatorInsetObservation = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Loading inspector...", isError: false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setZoomScale(1, animated: false)
            if !wrapsInFrame {
                loadState.wrappedValue = DevToolsWebViewState()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Inspector failed: \(error.localizedDescription)", isError: true)
            scheduleReload(of: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadState.wrappedValue = DevToolsWebViewState(message: "Inspector failed: \(error.localizedDescription)", isError: true)
            scheduleReload(of: webView)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            completionHandler(defaultText ?? "")
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            nil
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard scrollView.zoomScale != 1 else { return }
            scrollView.setZoomScale(1, animated: false)
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
                    reloadWorkItem?.cancel()
                case "stalled":
                    loadState.wrappedValue = DevToolsWebViewState(
                        message: "Reconnecting DevTools\(reason.map { ": \($0)" } ?? "...")",
                        isError: false
                    )
                    scheduleReload(of: message.webView)
                default:
                    loadState.wrappedValue = DevToolsWebViewState(
                        message: "Inspector \(state)\(reason.map { ": \($0)" } ?? "...")",
                        isError: false
                    )
                    if state == "failed" || state == "disconnected" {
                        scheduleReload(of: message.webView)
                    }
                }
            } else if type == "simdeck:webkit-inspector:socket",
                      let state = payload["state"] as? String,
                      state != "open" {
                loadState.wrappedValue = DevToolsWebViewState(message: "Inspector socket \(state)...", isError: false)
                if state == "closed" || state == "failed" || state == "disconnected" {
                    scheduleReload(of: message.webView)
                }
            }
        }

        private func scheduleReload(of webView: WKWebView?) {
            guard let webView else { return }
            let now = Date()
            let delay = max(1.2, 2.5 - now.timeIntervalSince(lastReloadAt))
            reloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.lastReloadAt = Date()
                self.loadState.wrappedValue = DevToolsWebViewState(message: "Reconnecting DevTools...", isError: false)
                webView.reload()
            }
            reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
              var queryItems = components.queryItems else {
            return self
        }
        for socketParameter in ["ws", "wss"] {
            guard let wsIndex = queryItems.firstIndex(where: { $0.name == socketParameter }),
                  var wsValue = queryItems[wsIndex].value,
                  !wsValue.contains("simdeckToken=") else {
                continue
            }
            var tokenComponents = URLComponents()
            tokenComponents.queryItems = [URLQueryItem(name: "simdeckToken", value: token)]
            let tokenQuery = tokenComponents.percentEncodedQuery ?? "simdeckToken=\(token)"
            wsValue += wsValue.contains("?") ? "&" : "?"
            wsValue += tokenQuery
            queryItems[wsIndex] = URLQueryItem(name: socketParameter, value: wsValue)
        }
        components.queryItems = queryItems
        return components.url ?? self
    }
}
