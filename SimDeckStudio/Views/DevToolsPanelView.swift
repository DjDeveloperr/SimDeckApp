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
}

struct DevToolsPanelView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedUDID: String?
    @State private var webKitTargets: [WebKitTarget] = []
    @State private var chromeTargets: [ChromeDevToolsTarget] = []
    @State private var warnings: [String] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedTarget: DevToolsPanelTarget?
    @State private var reloadID = UUID()
    @State private var loadGeneration = 0

    private var selectedSimulator: SimulatorMetadata? {
        let udid = selectedUDID ?? model.selectedSimulatorID
        return model.simulators.first { $0.udid == udid }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedTarget,
                   let endpoint = model.endpoint,
                   let url = frontendURL(for: selectedTarget, endpoint: endpoint) {
                    EmbeddedDevToolsWebView(url: url, token: endpoint.token, reloadID: reloadID)
                        .ignoresSafeArea(edges: .bottom)
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
                            dismiss()
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
            selectedUDID = selectedUDID ?? model.selectedSimulatorID ?? model.simulators.first?.udid
            Task { await loadTargets() }
        }
        .onChange(of: selectedUDID) {
            selectedTarget = nil
            Task { await loadTargets() }
        }
    }

    private var targetList: some View {
        List {
            Section("Simulator") {
                if model.simulators.isEmpty {
                    ContentUnavailableView("No Simulators", systemImage: "iphone")
                } else {
                    Picker("Simulator", selection: selectedUdidBinding) {
                        ForEach(model.simulators) { simulator in
                            Text(simulator.name).tag(Optional(simulator.udid))
                        }
                    }
                }
            }

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

    private var selectedUdidBinding: Binding<String?> {
        Binding {
            selectedUDID
        } set: { value in
            selectedUDID = value
        }
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
        return absolute.addingSimDeckTokenToDevToolsWebSocket(endpoint.token)
    }
}

private struct EmbeddedDevToolsWebView: UIViewRepresentable {
    let url: URL
    let token: String?
    let reloadID: UUID

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url || context.coordinator.reloadID != reloadID else { return }
        context.coordinator.loadedURL = url
        context.coordinator.reloadID = reloadID
        var request = URLRequest(url: url)
        if let token = token?.nilIfBlank {
            request.setValue(token, forHTTPHeaderField: "X-SimDeck-Token")
        }
        webView.load(request)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var loadedURL: URL?
        var reloadID: UUID?
    }
}

private extension URL {
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
