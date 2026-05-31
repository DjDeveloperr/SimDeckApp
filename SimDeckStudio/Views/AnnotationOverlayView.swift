import SwiftUI
import UIKit

struct AnnotationOverlayView: View {
    let roots: [AccessibilityNode]
    let screenFrame: CGRect
    let screenCornerRadius: CGFloat
    let maskImage: UIImage?
    let isLoading: Bool
    let error: String
    let selectedID: String?
    let onRefresh: () -> Void

    private var tree: [AccessibilityTreeItem] {
        buildAccessibilityTree(roots)
    }

    private var rootFrame: AccessibilityFrame? {
        accessibilityRootFrame(roots)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                annotationScreen
                    .frame(width: screenFrame.width, height: screenFrame.height)
                    .annotationScreenClip(cornerRadius: screenCornerRadius, maskImage: maskImage)
                    .position(x: screenFrame.midX, y: screenFrame.midY)

                Button(action: onRefresh) {
                    refreshIcon
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("Refresh Annotations")
                .disabled(isLoading)
                .position(refreshButtonPosition(in: proxy.size))
            }
        }
        .accessibilityLabel("Annotation Mode")
    }

    private var annotationScreen: some View {
        ZStack(alignment: .topLeading) {
            if let rootFrame {
                ForEach(visibleOverlayItems(rootFrame: rootFrame)) { item in
                    AnnotationElementRect(
                        item: item,
                        rootFrame: rootFrame,
                        screenSize: screenFrame.size,
                        isSelected: item.id == selectedID
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var refreshIcon: some View {
        if isLoading {
            ProgressView()
                .controlSize(.mini)
                .tint(annotationBlue)
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: error.isEmpty ? "arrow.clockwise" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(error.isEmpty ? annotationBlue : .orange)
                .frame(width: 30, height: 30)
        }
    }

    private func visibleOverlayItems(rootFrame: AccessibilityFrame) -> [AccessibilityTreeItem] {
        let candidates = paintOrderedAccessibilityItems(tree)
            .filter(isAccessibilityHitTestCandidate)
            .filter { isVisibleAnnotationOverlayCandidate($0, rootFrame: rootFrame) }
        let items = deduplicatedAnnotationOverlayItems(candidates, rootFrame: rootFrame)
            .filter { !isRootSizedAnnotationFrame(annotationFrame($0.node), rootFrame: rootFrame) }
        var result = selectedAnnotationOverlayItems(
            from: items,
            rootFrame: rootFrame,
            selectedID: selectedID
        )
        if result.isEmpty {
            result = deduplicatedAnnotationOverlayItems(candidates, rootFrame: rootFrame)
                .sorted { first, second in
                    annotationFrameArea(annotationFrame(first.node)) < annotationFrameArea(annotationFrame(second.node))
                }
                .prefix(annotationOverlayFallbackItemCount)
                .map(\.self)
        }
        if let selectedID,
           !result.contains(where: { $0.id == selectedID }),
           let selectedItem = findAccessibilityItem(tree, id: selectedID),
           isAccessibilityHitTestCandidate(selectedItem) {
            result.append(selectedItem)
        }
        return result.sorted {
            annotationFrameArea(annotationFrame($0.node)) > annotationFrameArea(annotationFrame($1.node))
        }
    }

    private func refreshButtonPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(screenFrame.maxX + 24, 22), max(22, size.width - 22)),
            y: min(max(screenFrame.minY - 10, 22), max(22, size.height - 22))
        )
    }
}

func annotationContextAtPoint(
    roots: [AccessibilityNode],
    normalizedPoint: CGPoint
) -> SimulatorAnnotationContext? {
    annotationContextsAtPoint(roots: roots, normalizedPoint: normalizedPoint).first
}

func annotationContextsAtPoint(
    roots: [AccessibilityNode],
    normalizedPoint: CGPoint
) -> [SimulatorAnnotationContext] {
    guard let rootFrame = accessibilityRootFrame(roots) else { return [] }
    let tree = buildAccessibilityTree(roots)
    return findAccessibilityItemsAtPoint(
        tree,
        normalizedPoint: normalizedPoint,
        rootFrame: rootFrame
    )
    .prefix(8)
    .map(annotationContext(for:))
}

struct AnnotationPromptSheet: View {
    @Bindable var model: AppModel
    let context: SimulatorAnnotationContext
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Element") {
                    AnnotationContextSummary(context: context)
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 150)
                        .focused($promptFocused)
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle("Annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.hapticSelection()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.addAnnotation(prompt: prompt, context: context)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                promptFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear(perform: onDismiss)
    }
}

struct AnnotationsSheet: View {
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var resetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            List {
                if model.annotations.isEmpty {
                    ContentUnavailableView("No Annotations", systemImage: "note.text")
                } else {
                    ForEach(model.annotations.sorted { $0.createdAt > $1.createdAt }) { annotation in
                        AnnotationRow(annotation: annotation)
                    }
                }
            }
            .navigationTitle("Annotations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.hapticSelection()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = model.annotationsExportText
                        model.status = "Annotations copied."
                        model.hapticSuccess()
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .disabled(model.annotations.isEmpty)

                    Button(role: .destructive) {
                        resetConfirmationPresented = true
                    } label: {
                        Label("Reset", systemImage: "trash")
                    }
                    .disabled(model.annotations.isEmpty)
                }
            }
            .confirmationDialog(
                "Reset Annotations",
                isPresented: $resetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    model.clearAnnotations()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AnnotationElementRect: View {
    let item: AccessibilityTreeItem
    let rootFrame: AccessibilityFrame
    let screenSize: CGSize
    let isSelected: Bool

    var body: some View {
        let rect = rectInScreen
        Rectangle()
            .fill(fillColor)
            .overlay {
                Rectangle()
                    .stroke(contrastColor, lineWidth: isSelected ? 3.2 : 1.8)
            }
            .overlay {
                Rectangle()
                    .stroke(borderColor, style: StrokeStyle(lineWidth: isSelected ? 2 : 1.15, dash: isSelected ? [] : [4, 3]))
            }
            .frame(width: max(rect.width, 3), height: max(rect.height, 3))
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Text(summary(for: item.node))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(annotationBlue.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .offset(x: -1, y: -19)
                        .allowsHitTesting(false)
                }
            }
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var rectInScreen: CGRect {
        guard let frame = annotationFrame(item.node), frame.isValid, rootFrame.width > 0, rootFrame.height > 0 else {
            return .zero
        }
        return CGRect(
            x: ((frame.x - rootFrame.x) / rootFrame.width) * screenSize.width,
            y: ((frame.y - rootFrame.y) / rootFrame.height) * screenSize.height,
            width: (frame.width / rootFrame.width) * screenSize.width,
            height: (frame.height / rootFrame.height) * screenSize.height
        )
    }

    private var borderColor: Color {
        isSelected ? annotationBlue : annotationBlue.opacity(borderOpacity)
    }

    private var contrastColor: Color {
        Color.white.opacity(isSelected ? 0.55 : contrastOpacity)
    }

    private var fillColor: Color {
        isSelected ? annotationBlue.opacity(0.12) : .clear
    }

    private var borderOpacity: Double {
        if isSelected {
            return 0.95
        }
        let ratio = areaRatio
        if ratio <= 0.015 {
            return 0.72
        }
        if ratio <= 0.08 {
            return 0.5
        }
        if ratio <= 0.22 {
            return 0.32
        }
        return 0.18
    }

    private var contrastOpacity: Double {
        areaRatio <= 0.08 ? 0.32 : 0.16
    }

    private var areaRatio: Double {
        annotationFrameArea(annotationFrame(item.node)) / max(1, rootFrame.width * rootFrame.height)
    }
}

private struct AnnotationContextSummary: View {
    let context: SimulatorAnnotationContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.headline)
            if !context.sourceLocation.isEmpty {
                Text(context.sourceLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !context.identifier.isEmpty {
                Label(context.identifier, systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !context.ancestry.isEmpty {
                Text(context.ancestry.joined(separator: " > "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .textSelection(.enabled)
    }

    private var summary: String {
        if context.label.isEmpty {
            return context.kind
        }
        return "\(context.kind) \"\(context.label)\""
    }
}

private struct AnnotationRow: View {
    let annotation: SimulatorAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(annotation.context.kind)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(annotation.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !annotation.context.label.isEmpty {
                Text(annotation.context.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(annotation.prompt)
                .font(.body)
                .lineLimit(4)
            if !annotation.context.sourceLocation.isEmpty {
                Text(annotation.context.sourceLocation)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

private struct AccessibilityTreeItem: Identifiable {
    let id: String
    let node: AccessibilityNode
    let children: [AccessibilityTreeItem]
    let depth: Int
    let ancestors: [AccessibilityNode]
    let siblings: [AccessibilityNode]
}

private struct AnnotationOverlayCandidate {
    let item: AccessibilityTreeItem
    let frame: AccessibilityFrame
    let areaRatio: Double
    let score: Double

    var isComponentSurface: Bool {
        !item.children.isEmpty && areaRatio >= 0.002 && areaRatio <= 0.16
    }
}

private struct AnnotationOverlayGrid {
    let rootFrame: AccessibilityFrame
    let columns: Int
    let rows: Int
    private var counts: [Int]

    init(rootFrame: AccessibilityFrame, columns: Int = 14, rows: Int = 28) {
        self.rootFrame = rootFrame
        self.columns = columns
        self.rows = rows
        self.counts = Array(repeating: 0, count: columns * rows)
    }

    func accepts(_ candidate: AnnotationOverlayCandidate) -> Bool {
        let indices = coveredIndices(for: candidate.frame)
        guard !indices.isEmpty else { return false }
        let maxPressure = indices.map { counts[$0] }.max() ?? 0
        let averagePressure = Double(indices.reduce(0) { $0 + counts[$1] }) / Double(indices.count)
        let limit = annotationOverlayPressureLimit(areaRatio: candidate.areaRatio)
        if candidate.isComponentSurface {
            return maxPressure < limit + 1 && averagePressure < Double(limit)
        }
        return maxPressure < limit && averagePressure < Double(limit) * 0.82
    }

    mutating func insert(_ candidate: AnnotationOverlayCandidate) {
        for index in coveredIndices(for: candidate.frame) {
            counts[index] += 1
        }
    }

    private func coveredIndices(for frame: AccessibilityFrame) -> [Int] {
        guard rootFrame.width > 0, rootFrame.height > 0 else { return [] }
        let minColumn = gridIndex((frame.x - rootFrame.x) / rootFrame.width, count: columns)
        let maxColumn = gridIndex((frame.x + frame.width - rootFrame.x) / rootFrame.width, count: columns)
        let minRow = gridIndex((frame.y - rootFrame.y) / rootFrame.height, count: rows)
        let maxRow = gridIndex((frame.y + frame.height - rootFrame.y) / rootFrame.height, count: rows)
        guard minColumn <= maxColumn, minRow <= maxRow else { return [] }
        var result: [Int] = []
        for row in minRow...maxRow {
            for column in minColumn...maxColumn {
                result.append(row * columns + column)
            }
        }
        return result
    }

    private func gridIndex(_ value: Double, count: Int) -> Int {
        let scaled = Int((value * Double(count)).rounded(.down))
        return min(max(scaled, 0), count - 1)
    }
}

private func buildAccessibilityTree(_ roots: [AccessibilityNode]) -> [AccessibilityTreeItem] {
    roots.enumerated().map { index, node in
        buildAccessibilityItem(
            node: node,
            id: "\(index)",
            depth: 0,
            ancestors: [],
            siblings: roots.enumerated().compactMap { $0.offset == index ? nil : $0.element }
        )
    }
}

private func buildAccessibilityItem(
    node: AccessibilityNode,
    id: String,
    depth: Int,
    ancestors: [AccessibilityNode],
    siblings: [AccessibilityNode]
) -> AccessibilityTreeItem {
    let childNodes = visibleAccessibilityChildren(node)
    let nextAncestors = ancestors + [node]
    let children = childNodes.enumerated().map { index, child in
        buildAccessibilityItem(
            node: child,
            id: "\(id).\(index)",
            depth: depth + 1,
            ancestors: nextAncestors,
            siblings: childNodes.enumerated().compactMap { $0.offset == index ? nil : $0.element }
        )
    }
    return AccessibilityTreeItem(
        id: id,
        node: node,
        children: children,
        depth: depth,
        ancestors: ancestors,
        siblings: siblings
    )
}

private func flattenAccessibilityTree(_ items: [AccessibilityTreeItem]) -> [AccessibilityTreeItem] {
    items.flatMap { item in
        [item] + flattenAccessibilityTree(item.children)
    }
}

private func paintOrderedAccessibilityItems(_ items: [AccessibilityTreeItem]) -> [AccessibilityTreeItem] {
    items.reversed().flatMap { flattenAccessibilityTree([$0]) }
}

private func findAccessibilityItem(_ items: [AccessibilityTreeItem], id: String) -> AccessibilityTreeItem? {
    for item in items {
        if item.id == id {
            return item
        }
        if let match = findAccessibilityItem(item.children, id: id) {
            return match
        }
    }
    return nil
}

private func findAccessibilityItemsAtPoint(
    _ items: [AccessibilityTreeItem],
    normalizedPoint: CGPoint,
    rootFrame: AccessibilityFrame
) -> [AccessibilityTreeItem] {
    let point = CGPoint(
        x: rootFrame.x + normalizedPoint.x * rootFrame.width,
        y: rootFrame.y + normalizedPoint.y * rootFrame.height
    )

    return flattenAccessibilityTree(items)
        .filter { item in
            frameContainsPoint(annotationFrame(item.node), point: point) && isAccessibilityHitTestCandidate(item)
        }
        .sorted { first, second in
            isBetterAnnotationHitTestCandidate(first, than: second)
        }
}

private func isBetterAnnotationHitTestCandidate(
    _ candidate: AccessibilityTreeItem,
    than current: AccessibilityTreeItem
) -> Bool {
    let candidateSourceScore = annotationSourceScore(candidate.node)
    let currentSourceScore = annotationSourceScore(current.node)
    if candidateSourceScore != currentSourceScore {
        return candidateSourceScore > currentSourceScore
    }

    let candidateArea = annotationFrameArea(annotationFrame(candidate.node))
    let currentArea = annotationFrameArea(annotationFrame(current.node))
    if candidateArea != currentArea {
        return candidateArea < currentArea
    }

    let candidateContentScore = annotationContentScore(candidate.node)
    let currentContentScore = annotationContentScore(current.node)
    if candidateContentScore != currentContentScore {
        return candidateContentScore > currentContentScore
    }

    if candidate.depth != current.depth {
        return candidate.depth > current.depth
    }

    return candidate.id > current.id
}

private func annotationSourceScore(_ node: AccessibilityNode) -> Int {
    let source = cleanText(node.source)?.lowercased()
    if node.reactNative != nil || source == "react-native" {
        return 60
    }
    if node.nativeScript != nil || source == "nativescript" {
        return 60
    }
    if node.flutter != nil || source == "flutter" {
        return 60
    }
    if node.swiftUI != nil || source == "swiftui" {
        return 55
    }
    if node.uikit != nil || node.uikitScript != nil || source == "uikit" {
        return 50
    }
    if node.inspectorId != nil || source == "in-app-inspector" {
        return 40
    }
    if source == "native-ax" || source == "native-ux" {
        return 0
    }
    return 10
}

private func annotationContentScore(_ node: AccessibilityNode) -> Int {
    var score = 0
    if hasMeaningfulNodeContent(node) {
        score += 2
    }
    if primarySourceLocation(node) != nil {
        score += 2
    }
    if !accessibilityIdentifier(node).isEmpty {
        score += 1
    }
    return score
}

private func annotationFrameArea(_ frame: AccessibilityFrame?) -> Double {
    guard let frame, frame.isValid else { return .greatestFiniteMagnitude }
    return frame.width * frame.height
}

private func annotationFrame(_ node: AccessibilityNode) -> AccessibilityFrame? {
    if node.frame?.isValid == true {
        return node.frame
    }
    if node.frameInScreen?.isValid == true {
        return node.frameInScreen
    }
    if node.bounds?.isValid == true {
        return node.bounds
    }
    return nil
}

private func isAccessibilityHitTestCandidate(_ item: AccessibilityTreeItem) -> Bool {
    annotationFrame(item.node)?.isValid == true && !isTransparentHitTestBlocker(item)
}

private func isVisibleAnnotationOverlayCandidate(_ item: AccessibilityTreeItem, rootFrame: AccessibilityFrame) -> Bool {
    if item.depth == 0 {
        return false
    }
    guard let frame = annotationFrame(item.node), frame.isValid else {
        return false
    }
    return frameIntersects(frame, rootFrame)
}

private func deduplicatedAnnotationOverlayItems(
    _ items: [AccessibilityTreeItem],
    rootFrame: AccessibilityFrame
) -> [AccessibilityTreeItem] {
    var result: [String: AccessibilityTreeItem] = [:]
    for item in items {
        guard let frame = annotationFrame(item.node), frame.isValid else { continue }
        let key = annotationFrameKey(frame, rootFrame: rootFrame)
        if let existing = result[key] {
            if isBetterAnnotationHitTestCandidate(item, than: existing) {
                result[key] = item
            }
        } else {
            result[key] = item
        }
    }
    return Array(result.values)
}

private func selectedAnnotationOverlayItems(
    from items: [AccessibilityTreeItem],
    rootFrame: AccessibilityFrame,
    selectedID: String?
) -> [AccessibilityTreeItem] {
    let rootArea = max(1, rootFrame.width * rootFrame.height)
    let candidates = items.compactMap { item -> AnnotationOverlayCandidate? in
        guard let frame = annotationFrame(item.node), frame.isValid else { return nil }
        let areaRatio = annotationFrameArea(frame) / rootArea
        guard frame.width >= 2, frame.height >= 2 else { return nil }
        guard !isLowValueOverlayContainer(item, areaRatio: areaRatio) else { return nil }
        return AnnotationOverlayCandidate(
            item: item,
            frame: frame,
            areaRatio: areaRatio,
            score: annotationOverlayDisplayScore(item, rootFrame: rootFrame)
        )
    }
    .sorted { first, second in
        if first.score != second.score {
            return first.score > second.score
        }
        if first.areaRatio != second.areaRatio {
            return first.areaRatio < second.areaRatio
        }
        return first.item.depth > second.item.depth
    }

    var grid = AnnotationOverlayGrid(rootFrame: rootFrame)
    var result: [AnnotationOverlayCandidate] = []
    for candidate in candidates {
        guard result.count < annotationOverlayMaxItems else { break }
        if candidate.item.id == selectedID || grid.accepts(candidate) {
            result.append(candidate)
            grid.insert(candidate)
        }
    }
    return result.map(\.item)
}

private func isLowValueOverlayContainer(_ item: AccessibilityTreeItem, areaRatio: Double) -> Bool {
    if item.children.isEmpty {
        return false
    }
    if areaRatio >= 0.45 {
        return true
    }
    if areaRatio >= 0.18 && !hasMeaningfulNodeContent(item.node) && !isActionableAnnotationNode(item.node) {
        return true
    }
    return false
}

private func annotationOverlayDisplayScore(_ item: AccessibilityTreeItem, rootFrame: AccessibilityFrame) -> Double {
    let areaRatio = annotationFrameArea(annotationFrame(item.node)) / max(1, rootFrame.width * rootFrame.height)
    var score = Double(annotationSourceScore(item.node)) * 0.45
    score += Double(item.depth) * 0.55
    score += Double(annotationContentScore(item.node)) * 8
    if item.children.isEmpty {
        score += 12
    } else if areaRatio >= 0.002 && areaRatio <= 0.16 {
        score += 26
    }
    if isActionableAnnotationNode(item.node) {
        score += 16
    }
    if primarySourceLocation(item.node) != nil {
        score += 10
    }
    score += annotationOverlayAreaScore(areaRatio)
    if areaRatio > 0.24 {
        score -= 28
    }
    return score
}

private func annotationOverlayAreaScore(_ areaRatio: Double) -> Double {
    if areaRatio < 0.00003 {
        return -18
    }
    if areaRatio < 0.001 {
        return 8
    }
    if areaRatio < 0.018 {
        return 28
    }
    if areaRatio < 0.09 {
        return 24
    }
    if areaRatio < 0.18 {
        return 8
    }
    return -12
}

private func annotationOverlayPressureLimit(areaRatio: Double) -> Int {
    if areaRatio < 0.002 {
        return 5
    }
    if areaRatio < 0.012 {
        return 4
    }
    if areaRatio < 0.06 {
        return 3
    }
    return 2
}

private func annotationFrameKey(_ frame: AccessibilityFrame, rootFrame: AccessibilityFrame) -> String {
    let scale = 1.0 / 6.0
    let x = Int(((frame.x - rootFrame.x) * scale).rounded())
    let y = Int(((frame.y - rootFrame.y) * scale).rounded())
    let width = Int((frame.width * scale).rounded())
    let height = Int((frame.height * scale).rounded())
    return "\(x):\(y):\(width):\(height)"
}

private func isRootSizedAnnotationFrame(_ frame: AccessibilityFrame?, rootFrame: AccessibilityFrame) -> Bool {
    guard let frame, frame.isValid else { return true }
    let areaRatio = annotationFrameArea(frame) / max(1, rootFrame.width * rootFrame.height)
    let nearRootEdges = abs(frame.x - rootFrame.x) <= 2
        && abs(frame.y - rootFrame.y) <= 2
        && abs((frame.x + frame.width) - (rootFrame.x + rootFrame.width)) <= 2
        && abs((frame.y + frame.height) - (rootFrame.y + rootFrame.height)) <= 2
    return areaRatio >= 0.92 || nearRootEdges
}

private func frameIntersects(_ frame: AccessibilityFrame, _ rootFrame: AccessibilityFrame) -> Bool {
    frame.x < rootFrame.x + rootFrame.width
        && frame.x + frame.width > rootFrame.x
        && frame.y < rootFrame.y + rootFrame.height
        && frame.y + frame.height > rootFrame.y
}

private func annotationGranularityScore(_ item: AccessibilityTreeItem, rootFrame: AccessibilityFrame) -> Double {
    let areaRatio = annotationFrameArea(annotationFrame(item.node)) / max(1, rootFrame.width * rootFrame.height)
    var score = Double(item.depth)
    if item.children.isEmpty {
        score += 14
    }
    if hasMeaningfulNodeContent(item.node) {
        score += 8
    }
    if isActionableAnnotationNode(item.node) {
        score += 6
    }
    if primarySourceLocation(item.node) != nil {
        score += 4
    }
    if !accessibilityIdentifier(item.node).isEmpty {
        score += 2
    }
    score += max(0, 1 - min(areaRatio, 1)) * 10
    return score
}

private func isActionableAnnotationNode(_ node: AccessibilityNode) -> Bool {
    node.clickable == true
        || node.longClickable == true
        || node.focusable == true
        || node.scrollable == true
        || !(node.customActions?.isEmpty ?? true)
        || node.control != nil
        || node.semantics != nil
}

private func accessibilityRootFrame(_ roots: [AccessibilityNode]) -> AccessibilityFrame? {
    roots.compactMap(annotationFrame).first { $0.isValid }
}

private func frameContainsPoint(_ frame: AccessibilityFrame?, point: CGPoint) -> Bool {
    guard let frame, frame.isValid else { return false }
    return point.x >= frame.x
        && point.y >= frame.y
        && point.x <= frame.x + frame.width
        && point.y <= frame.y + frame.height
}

private func annotationContext(for item: AccessibilityTreeItem) -> SimulatorAnnotationContext {
    let node = item.node
    return SimulatorAnnotationContext(
        elementID: item.id,
        kind: accessibilityKind(node),
        label: primaryAccessibilityText(node),
        identifier: accessibilityIdentifier(node),
        value: cleanText(node.AXValue) ?? "",
        source: sourceText(for: item),
        sourceLocation: sourceLocationText(for: item),
        frame: annotationFrame(node),
        ancestry: item.ancestors.suffix(6).map(summary(for:)),
        siblings: item.siblings.prefix(8).map(summary(for:)),
        details: annotationDetails(for: node)
    )
}

private func sourceText(for item: AccessibilityTreeItem) -> String {
    cleanText(item.node.source)
        ?? item.ancestors.reversed().compactMap { cleanText($0.source) }.first
        ?? ""
}

private func sourceLocationText(for item: AccessibilityTreeItem) -> String {
    if let ownLocation = cleanText(sourceLocationText(item.node)) {
        return ownLocation
    }
    return item.ancestors.reversed()
        .compactMap { cleanText(sourceLocationText($0)) }
        .first ?? ""
}

private func annotationDetails(for node: AccessibilityNode) -> [SimulatorAnnotationDetail] {
    var details: [SimulatorAnnotationDetail] = []
    appendDetail("Type", accessibilityKind(node), to: &details)
    appendDetail("Label", primaryAccessibilityText(node), to: &details)
    appendDetail("Identifier", accessibilityIdentifier(node), to: &details)
    appendDetail("React Native ID", node.id, to: &details)
    appendDetail("Display Name", node.displayName, to: &details)
    appendDetail("Raw Label", node.label, to: &details)
    appendDetail("AX Label", node.AXLabel, to: &details)
    appendDetail("AX Identifier", node.AXIdentifier, to: &details)
    appendDetail("AX Unique ID", node.AXUniqueId, to: &details)
    appendDetail("AX Frame", node.AXFrame, to: &details)
    appendDetail("Inspector ID", node.inspectorId, to: &details)
    appendDetail("UIKit ID", node.uikitId, to: &details)
    appendDetail("Module", node.moduleName, to: &details)
    appendDetail("Source", node.source, to: &details)
    appendDetail("Source File", sourceLocationText(node), to: &details)
    appendDetail("Class", node.androidClass ?? node.className, to: &details)
    appendDetail("Package", node.androidPackage, to: &details)
    appendDetail("Resource ID", node.androidResourceId, to: &details)
    appendDetail("Subrole", node.subrole, to: &details)
    appendDetail("Role", node.roleDescription ?? node.role, to: &details)
    appendDetail("Value", node.AXValue, to: &details)
    appendDetail("Placeholder", node.placeholder, to: &details)
    appendDetail("Text", node.text, to: &details)
    appendDetail("Title", node.title, to: &details)
    appendDetail("Image", node.imageName, to: &details)
    appendDetail("Help", node.help, to: &details)
    appendDetail("Frame", annotationFrame(node).map(frameText), to: &details)
    appendDetail("Frame In Screen", node.frameInScreen.map(frameText), to: &details)
    appendDetail("Bounds", node.bounds.map(frameText), to: &details)
    appendDetail("Alpha", node.alpha.map { $0.formatted(.number.precision(.fractionLength(2))) }, to: &details)
    appendDetail("Enabled", node.enabled.map(boolText), to: &details)
    appendDetail("Hidden", node.isHidden.map(boolText), to: &details)
    appendDetail("Opaque", node.isOpaque.map(boolText), to: &details)
    appendDetail("User Interaction", node.isUserInteractionEnabled.map(boolText), to: &details)
    appendDetail("Clickable", node.clickable.map(boolText), to: &details)
    appendDetail("Long Clickable", node.longClickable.map(boolText), to: &details)
    appendDetail("Focusable", node.focusable.map(boolText), to: &details)
    appendDetail("Focused", node.focused.map(boolText), to: &details)
    appendDetail("Scrollable", node.scrollable.map(boolText), to: &details)
    appendDetail("Checkable", node.checkable.map(boolText), to: &details)
    appendDetail("Checked", node.checked.map(boolText), to: &details)
    appendDetail("Selected", node.selected.map(boolText), to: &details)
    appendDetail("Password", node.password.map(boolText), to: &details)
    appendDetail("Control", node.control?.annotationPreview, to: &details)
    appendDetail("Scroll", node.scroll?.annotationPreview, to: &details)
    appendDetail("Semantics", node.semantics?.annotationPreview, to: &details)
    appendDetail("Background", node.backgroundColor?.annotationPreview, to: &details)
    appendDetail("React Native", node.reactNative?.annotationPreview, to: &details)
    appendDetail("NativeScript", node.nativeScript?.annotationPreview, to: &details)
    appendDetail("Flutter", node.flutter?.annotationPreview, to: &details)
    appendDetail("SwiftUI", node.swiftUI?.annotationPreview, to: &details)
    appendDetail("UIKit", node.uikit?.annotationPreview, to: &details)
    appendDetail("UIKit Script", node.uikitScript?.annotationPreview, to: &details)
    appendDetail("View Controller", node.viewController?.annotationPreview, to: &details)
    appendDetail("Actions", node.customActions?.joined(separator: ", "), to: &details)
    appendDetail("Debug", node.debugDescription, to: &details)
    appendDetail("PID", node.pid.map(String.init), to: &details)
    return details
}

private func appendDetail(_ name: String, _ value: String?, to details: inout [SimulatorAnnotationDetail]) {
    guard let value = cleanText(value) else { return }
    details.append(SimulatorAnnotationDetail(name: name, value: value))
}

private func boolText(_ value: Bool) -> String {
    value ? "true" : "false"
}

private func frameText(_ frame: AccessibilityFrame) -> String {
    "x \(frameNumber(frame.x)), y \(frameNumber(frame.y)), w \(frameNumber(frame.width)), h \(frameNumber(frame.height))"
}

private func frameNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(1)))
}

private func summary(for node: AccessibilityNode) -> String {
    let kind = accessibilityKind(node)
    let label = primaryAccessibilityText(node)
    if !label.isEmpty {
        return "\(kind) \"\(label.truncatedAnnotationText())\""
    }
    let identifier = accessibilityIdentifier(node)
    if !identifier.isEmpty {
        return "\(kind) #\(identifier.truncatedAnnotationText())"
    }
    return kind
}

private func primaryAccessibilityText(_ node: AccessibilityNode) -> String {
    return [
        node.label,
        node.AXLabel,
        node.text,
        node.title,
        node.AXUniqueId,
        node.AXIdentifier,
        node.AXValue,
        node.placeholder,
        node.imageName
    ]
    .compactMap(cleanText)
    .first { isMeaningfulAccessibilityText($0, for: node) } ?? ""
}

private func accessibilityIdentifier(_ node: AccessibilityNode) -> String {
    cleanText(node.id)
        ?? cleanText(node.inspectorId)
        ?? cleanText(node.AXUniqueId)
        ?? cleanText(node.AXIdentifier)
        ?? node.androidResourceId
        ?? ""
}

private func accessibilityKind(_ node: AccessibilityNode) -> String {
    let kind = cleanText(node.displayName)
        ?? cleanText(node.type)
        ?? cleanText(node.role)
        ?? cleanText(node.className)
        ?? "Element"
    let withoutReactPrefix = node.source == "react-native" ? stripReactNativePrefix(kind) : kind
    return strippedGeneratedOrdinal(withoutReactPrefix)
}

private func isMeaningfulAccessibilityText(_ value: String, for node: AccessibilityNode) -> Bool {
    if generatedNodeNames(node).contains(value) {
        return false
    }
    if value.hasPrefix("rn:"), value.dropFirst(3).allSatisfy(\.isNumber) {
        return false
    }
    let kind = accessibilityKind(node).lowercased()
    if !kind.contains("text"), value.allSatisfy(\.isNumber) {
        return false
    }
    if isGeneratedOrdinalLabel(value) {
        return false
    }
    return true
}

private func visibleAccessibilityChildren(_ node: AccessibilityNode) -> [AccessibilityNode] {
    if node.source == "react-native",
       stripReactNativePrefix(cleanText(node.type) ?? "") == "Text",
       !primaryAccessibilityText(node).isEmpty {
        return []
    }
    return node.children ?? []
}

private func isTransparentHitTestBlocker(_ item: AccessibilityTreeItem) -> Bool {
    let node = item.node
    if node.source == "flutter" {
        if jsonBool(node.flutter, key: "transparent") {
            return true
        }
        return !hasMeaningfulNodeContent(node) && isFlutterTransparentContainerType(cleanText(node.type))
    }

    if node.source == "nativescript" {
        return !hasMeaningfulNodeContent(node) && isNativeScriptTransparentContainerType(cleanText(node.type))
    }

    if node.source != "in-app-inspector" || node.nativeScript != nil {
        return false
    }

    let rawClassName = cleanText(node.className)
    let type = cleanText(node.type)
    guard isTransparentContainerClass(rawClassName) || isTransparentContainerClass(type) else {
        return false
    }
    return !hasMeaningfulNodeContent(node)
}

private func hasMeaningfulNodeContent(_ node: AccessibilityNode) -> Bool {
    return [
        node.label,
        node.AXLabel,
        node.text,
        node.AXIdentifier,
        node.AXValue,
        node.placeholder,
        node.imageName,
        node.title
    ]
    .compactMap(cleanText)
    .contains { isMeaningfulAccessibilityText($0, for: node) }
}

private func generatedNodeNames(_ node: AccessibilityNode) -> Set<String> {
    let names = [node.type, node.displayName, node.className, node.role, "UIView", "UIKit View"]
        .compactMap(cleanText)
    return Set(names + names.map { "_\($0)" })
}

private func primarySourceLocation(_ node: AccessibilityNode) -> AccessibilitySourceLocation? {
    if let location = node.sourceLocation, cleanText(location.file) != nil {
        return location
    }
    if let location = node.sourceLocations?.first(where: { cleanText($0.file) != nil }) {
        return location
    }
    if cleanText(node.sourceFile) != nil {
        return AccessibilitySourceLocation(
            column: node.sourceColumn,
            file: node.sourceFile,
            kind: nil,
            line: node.sourceLine,
            offset: nil
        )
    }
    return nil
}

private func sourceLocationText(_ node: AccessibilityNode) -> String {
    guard let location = primarySourceLocation(node),
          let file = cleanText(location.file) else {
        return ""
    }
    let path = sourceFilePath(file)
    if let line = location.line, let column = location.column {
        return "\(path):\(line):\(column)"
    }
    if let line = location.line {
        return "\(path):\(line)"
    }
    return path
}

private func sourceFilePath(_ file: String) -> String {
    guard file.hasPrefix("file://") else { return file }
    if let url = URL(string: file) {
        return url.path.removingPercentEncoding ?? url.path
    }
    return file.replacingOccurrences(of: "file://", with: "")
}

private func cleanText(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

private func stripReactNativePrefix(_ value: String) -> String {
    value.hasPrefix("RCT") && value.count > 3 ? String(value.dropFirst(3)) : value
}

private func strippedGeneratedOrdinal(_ value: String) -> String {
    guard isGeneratedOrdinalLabel(value) else { return value }
    let parts = value.split(separator: " ")
    return String(parts[0])
}

private func isGeneratedOrdinalLabel(_ value: String) -> Bool {
    let parts = value.split(separator: " ")
    guard parts.count == 2,
          parts[1].allSatisfy(\.isNumber) else {
        return false
    }
    return generatedOrdinalPrefixes.contains(parts[0].lowercased())
}

private func jsonBool(_ object: [String: JSONValue]?, key: String) -> Bool {
    if case .bool(let value) = object?[key] {
        return value
    }
    return false
}

private func unqualifiedClassName(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.split(separator: ".").last.map(String.init) ?? value
}

private func isTransparentContainerClass(_ value: String?) -> Bool {
    guard let className = unqualifiedClassName(value) else { return false }
    return className == "UIView"
        || className == "UITransitionView"
        || className == "UIDropShadowView"
        || className == "UIViewControllerWrapperView"
        || className == "UINavigationTransitionView"
        || className == "_UITabBarContainerView"
        || className == "_UITouchPassthroughView"
        || className == "_UIFloatingBarContainerView"
        || className.contains("FloatingBarHostingView")
}

private func isNativeScriptTransparentContainerType(_ value: String?) -> Bool {
    guard let type = unqualifiedClassName(value) else { return false }
    return nativeScriptTransparentContainerTypes.contains(type)
}

private func isFlutterTransparentContainerType(_ value: String?) -> Bool {
    guard let type = unqualifiedClassName(value) else { return false }
    return type.hasPrefix("_")
        || flutterTransparentContainerTypes.contains(type)
        || flutterFrameworkContainerTypes.contains(type)
}

private let nativeScriptTransparentContainerTypes: Set<String> = [
    "AbsoluteLayout", "ActionBar", "ContentView", "DockLayout", "FlexboxLayout",
    "Frame", "GridLayout", "HtmlView", "Page", "Placeholder", "ProxyViewContainer",
    "RootLayout", "StackLayout", "TabAccessory", "TabView", "WrapLayout"
]

private let flutterTransparentContainerTypes: Set<String> = [
    "AbsorbPointer", "Align", "AnimatedBuilder", "AnimatedContainer", "AnimatedOpacity",
    "AspectRatio", "Builder", "Center", "Column", "ConstrainedBox", "Container",
    "CustomPaint", "DecoratedBox", "Directionality", "Expanded", "Flexible",
    "GestureDetector", "IgnorePointer", "ListView", "Material", "MediaQuery",
    "Opacity", "Padding", "Positioned", "Row", "SafeArea", "Scaffold",
    "Scrollable", "Semantics", "SizedBox", "Stack", "Transform", "Viewport"
]

private let flutterFrameworkContainerTypes: Set<String> = [
    "CupertinoTheme", "HeroControllerScope", "IconTheme", "Localizations",
    "MaterialApp", "Navigator", "Overlay", "PageStorage", "RawView", "RootWidget",
    "ScaffoldMessenger", "ScrollConfiguration", "Shortcuts", "Title", "View",
    "WidgetsApp"
]

private let generatedOrdinalPrefixes: Set<String> = [
    "button", "component", "element", "image", "pressable", "rctview",
    "scrollview", "textinput", "view", "wrap"
]

private let annotationOverlayMaxItems = 360
private let annotationOverlayFallbackItemCount = 80
private let annotationBlue = Color(red: 0.2, green: 0.65, blue: 0.95)

private extension Dictionary where Key == String, Value == JSONValue {
    var annotationPreview: String {
        sorted { $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key): \($0.value.compactDescription)" }
            .joined(separator: ", ")
    }
}

private extension String {
    func truncatedAnnotationText(maxLength: Int = 80) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength - 1)) + "..."
    }
}

private extension View {
    @ViewBuilder
    func annotationScreenClip(cornerRadius: CGFloat, maskImage: UIImage?) -> some View {
        if let maskImage {
            self.mask(
                Image(uiImage: maskImage)
                    .resizable()
                    .scaledToFill()
            )
        } else {
            self.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
