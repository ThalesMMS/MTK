//
//  ClinicalViewportGrid.swift
//  MTKUI
//
//  SwiftUI 2x2 clinical layout backed by MTKRenderingEngine viewports.
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import CoreGraphics
import Foundation
import MTKCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A ready-to-use SwiftUI 2×2 clinical viewport grid backed by the MTK rendering engine.
///
/// `ClinicalViewportGrid` is intended as an embeddable, production-quality building block.
/// It owns or displays a ``ClinicalViewportGridController`` and renders four synchronized
/// viewports (volume and/or MPR), with an optional per-viewport overlay hook for diagnostics.
///
/// - Note: This view is available on iOS and macOS.
/// - Important: Mutate the controller only from the main actor.
@MainActor
public struct ClinicalViewportGrid: View {
    @StateObject private var store: ClinicalViewportGridControllerStore
    private let style: any VolumetricUIStyle
    private let viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)?
    private let interactionMode: NativeVolume3DInteractionMode
    private let showsCompactChrome: Bool

    /// Creates a clinical 2x2 viewport grid from the public viewport session contract.
    public init(session: ClinicalViewportSession,
                viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
                interactionMode: NativeVolume3DInteractionMode = .orbit,
                showsCompactChrome: Bool = true,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        _store = StateObject(wrappedValue: ClinicalViewportGridControllerStore(session: session,
                                                                               dataset: nil))
        self.style = style
        self.viewportOverlay = viewportOverlay
        self.interactionMode = interactionMode
        self.showsCompactChrome = showsCompactChrome
    }

    /// Creates a clinical 2x2 viewport grid.
    ///
    /// Pass a preconfigured controller when ownership lives in a coordinator or view model. When
    /// `controller` is `nil`, the view creates one on the main actor and applies `dataset` once it
    /// is ready. The controller and view are `@MainActor` isolated; mutate them from UI code or by
    /// explicitly hopping to the main actor.
    public init(controller: ClinicalViewportGridController? = nil,
                dataset: VolumeDataset? = nil,
                viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
                interactionMode: NativeVolume3DInteractionMode = .orbit,
                showsCompactChrome: Bool = true,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        _store = StateObject(wrappedValue: ClinicalViewportGridControllerStore(controller: controller,
                                                                               dataset: dataset))
        self.style = style
        self.viewportOverlay = viewportOverlay
        self.interactionMode = interactionMode
        self.showsCompactChrome = showsCompactChrome
    }

    public var body: some View {
        Group {
            if let controller = store.controller {
                ClinicalViewportGridContent(controller: controller,
                                            viewportOverlay: viewportOverlay,
                                            interactionMode: interactionMode,
                                            showsCompactChrome: showsCompactChrome,
                                            style: style)
            } else if let error = store.initializationError {
                Text(error.localizedDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.65))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.65))
            }
        }
        .task {
            await store.prepare()
        }
        .onDisappear {
            Task {
                await store.shutdownIfOwned()
            }
        }
    }
}

@MainActor
private final class ClinicalViewportGridControllerStore: ObservableObject {
    @Published var session: ClinicalViewportSession?
    @Published var initializationError: (any Error)?

    private let initialDataset: VolumeDataset?
    private let ownsController: Bool
    private var preparationTask: Task<Void, Never>?
    private var didApplyInitialDataset = false

    var controller: ClinicalViewportGridController? {
        session?.controller
    }

    init(session: ClinicalViewportSession, dataset: VolumeDataset?) {
        self.session = session
        self.initialDataset = dataset
        self.ownsController = false
    }

    init(controller: ClinicalViewportGridController?, dataset: VolumeDataset?) {
        self.session = controller.map(ClinicalViewportSession.init(controller:))
        self.initialDataset = dataset
        self.ownsController = controller == nil
    }

    func prepare() async {
        if let preparationTask {
            await preparationTask.value
            return
        }

        let task = Task { @MainActor in
            do {
                let resolvedSession: ClinicalViewportSession
                if let existingSession = self.session {
                    resolvedSession = existingSession
                } else {
                    resolvedSession = try await ClinicalViewportSession.make()
                    self.session = resolvedSession
                }

                if ownsController, let initialDataset, !didApplyInitialDataset {
                    try await resolvedSession.applyDataset(initialDataset)
                    didApplyInitialDataset = true
                }
            } catch {
                initializationError = error
            }
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }

    func shutdownIfOwned() async {
        guard ownsController else { return }
        let task = preparationTask
        task?.cancel()
        await task?.value
        preparationTask = nil
        guard let session else { return }
        await session.shutdown()
        self.session = nil
        didApplyInitialDataset = false
    }
}

private enum MPRGestureType {
    case crosshair
    case tilt
    case slice
    case pan
    case windowLevel
}

@MainActor
private struct ClinicalViewportGridContent: View {
    @ObservedObject private var controller: ClinicalViewportGridController
    private let style: any VolumetricUIStyle
    private let viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)?
    private let interactionMode: NativeVolume3DInteractionMode
    private let showsCompactChrome: Bool
    @State private var draftWindowLevel = WindowLevelShift(window: 400, level: 40)
    @State private var draftSlabThickness = 3.0
    @State private var pendingMPRGestureTasks: [MTKCore.Axis: Task<Void, Never>] = [:]
    @State private var pendingMPRMagnificationTasks: [MTKCore.Axis: Task<Void, Never>] = [:]
    @State private var activeMPRGestures = Set<MTKCore.Axis>()
    @State private var activeMPRMagnificationGestures = Set<MTKCore.Axis>()
    @State private var lastMPRDragTranslations: [MTKCore.Axis: CGSize] = [:]
    @State private var lastMPRDragEventTimes: [MTKCore.Axis: CFAbsoluteTime] = [:]
    @State private var lastMPRMagnifications: [MTKCore.Axis: CGFloat] = [:]
    @State private var lastMPRMagnificationEventTimes: [MTKCore.Axis: CFAbsoluteTime] = [:]

    @State private var activeMPRGestureTypes: [MTKCore.Axis: MPRGestureType] = [:]
    @State private var startDragAngles: [MTKCore.Axis: Double] = [:]
    @State private var controlsExpanded = false
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif

    @State private var slot1Axis: MTKCore.Axis = .axial
    @State private var slot2Axis: MTKCore.Axis = .sagittal
    @State private var slot3Axis: MTKCore.Axis = .coronal

    @State private var verticalSplit: CGFloat = 0.5
    @State private var horizontalSplit: CGFloat = 0.5

    @State private var startVerticalSplit: CGFloat = 0.5
    @State private var startHorizontalSplit: CGFloat = 0.5
    @State private var isDraggingVertical = false
    @State private var isDraggingHorizontal = false

    @State private var fullscreenSlot: Int? = nil

    init(controller: ClinicalViewportGridController,
         viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
         interactionMode: NativeVolume3DInteractionMode = .orbit,
         showsCompactChrome: Bool = true,
         style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.viewportOverlay = viewportOverlay
        self.style = style
        self.interactionMode = interactionMode
        self.showsCompactChrome = showsCompactChrome
    }

    var body: some View {
        Group {
            if isCompactPhonePortrait {
                compactPhoneLayout()
            } else {
                regularLayout()
            }
        }
        .onAppear {
            draftWindowLevel = controller.windowLevel
            draftSlabThickness = controller.slabThickness
        }
        .onChange(of: controller.windowLevel) { _, newValue in
            draftWindowLevel = newValue
        }
        .onChange(of: controller.slabThickness) { _, newValue in
            draftSlabThickness = newValue
        }
        .accessibilityIdentifier("ClinicalViewportGrid")
    }

    private var isCompactPhonePortrait: Bool {
#if os(iOS)
        horizontalSizeClass == .compact && verticalSizeClass == .regular
#else
        false
#endif
    }

    private func regularLayout() -> some View {
        VStack(spacing: 12) {
            viewportGrid()
                .aspectRatio(1, contentMode: .fit)
            clinicalControls()
        }
        .padding()
    }

    private func compactPhoneLayout() -> some View {
        GeometryReader { proxy in
            let safeHeight = max(proxy.size.height, 1)
            if showsCompactChrome {
                let controlsHeight: CGFloat = controlsExpanded ? min(220, safeHeight * 0.38) : 48
                VStack(spacing: 6) {
                    compactHeader()
                        .frame(height: 30)
                    viewportGrid()
                        .frame(maxWidth: .infinity)
                        .frame(height: max(safeHeight - controlsHeight - 42, 160))
                    compactControlsSheet()
                        .frame(height: controlsHeight)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            } else {
                viewportGrid()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func compactHeader() -> some View {
        HStack(spacing: 8) {
            Text("MPR")
                .font(.headline)
            Text(activeAxisLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy) {
                    controlsExpanded.toggle()
                }
            } label: {
                Image(systemName: controlsExpanded ? "slider.horizontal.below.rectangle" : "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ClinicalViewportCompactControlsToggle")
        }
    }

    private var activeAxisLabel: String {
        switch controller.activeMPRAxis {
        case .axial:
            return "Axial"
        case .sagittal:
            return "Sagittal"
        case .coronal:
            return "Coronal"
        }
    }

    private func compactControlsSheet() -> some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    withAnimation(.snappy) {
                        controlsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: controlsExpanded ? "chevron.down" : "chevron.up")
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(.plain)
                Text("WL \(Int(draftWindowLevel.level)) / \(Int(draftWindowLevel.window))")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("Slab \(Int(draftSlabThickness))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if controlsExpanded {
                clinicalControls()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func clinicalControls() -> some View {
        VStack(spacing: isCompactPhonePortrait ? 6 : 12) {
            SlabThicknessControlView(thickness: $draftSlabThickness,
                                     style: style,
                                     onCommit: commitSlabThickness)
            WindowLevelControlView(
                level: Binding(get: { draftWindowLevel.level },
                               set: { draftWindowLevel = WindowLevelShift(window: draftWindowLevel.window,
                                                                          level: $0) }),
                window: Binding(get: { draftWindowLevel.window },
                                set: { draftWindowLevel = WindowLevelShift(window: max($0, 1),
                                                                           level: draftWindowLevel.level) }),
                style: style,
                onCommit: commitWindowLevel
            )
        }
    }

    private func switchAxis(for slot: Int, to newAxis: MTKCore.Axis) {
        if slot == 1 {
            if slot2Axis == newAxis {
                slot2Axis = slot1Axis
            } else if slot3Axis == newAxis {
                slot3Axis = slot1Axis
            }
            slot1Axis = newAxis
        } else if slot == 2 {
            if slot1Axis == newAxis {
                slot1Axis = slot2Axis
            } else if slot3Axis == newAxis {
                slot3Axis = slot2Axis
            }
            slot2Axis = newAxis
        } else if slot == 3 {
            if slot1Axis == newAxis {
                slot1Axis = slot3Axis
            } else if slot2Axis == newAxis {
                slot2Axis = slot3Axis
            }
            slot3Axis = newAxis
        }
    }

    private func axisBadgeNumber(_ axis: MTKCore.Axis) -> String {
        switch axis {
        case .axial:
            return "1"
        case .sagittal:
            return "2"
        case .coronal:
            return "3"
        }
    }

    private func axisMenu(for slot: Int, currentAxis: MTKCore.Axis) -> some View {
        Menu {
            Button(action: { switchAxis(for: slot, to: .axial) }) {
                HStack {
                    Text("1 — Axial")
                    if currentAxis == .axial { Image(systemName: "checkmark") }
                }
            }
            Button(action: { switchAxis(for: slot, to: .sagittal) }) {
                HStack {
                    Text("2 — Sagittal")
                    if currentAxis == .sagittal { Image(systemName: "checkmark") }
                }
            }
            Button(action: { switchAxis(for: slot, to: .coronal) }) {
                HStack {
                    Text("3 — Coronal")
                    if currentAxis == .coronal { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Text(axisBadgeNumber(currentAxis))
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(style.overlayBackground.cornerRadius(12))
                .foregroundStyle(style.overlayForeground)
        }
        .accessibilityIdentifier("ClinicalViewportAxisBadgeMenu")
    }

    private func horizontalDivider(totalHeight: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray)
                .frame(width: 40, height: 6)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !isDraggingVertical {
                        isDraggingVertical = true
                        startVerticalSplit = verticalSplit
                    }
                    let delta = gesture.translation.height / totalHeight
                    verticalSplit = min(max(startVerticalSplit + delta, 0.2), 0.8)
                }
                .onEnded { _ in
                    isDraggingVertical = false
                }
        )
    }

    private func verticalDivider(totalWidth: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(width: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray)
                .frame(width: 6, height: 40)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !isDraggingHorizontal {
                        isDraggingHorizontal = true
                        startHorizontalSplit = horizontalSplit
                    }
                    let delta = gesture.translation.width / totalWidth
                    horizontalSplit = min(max(startHorizontalSplit + delta, 0.2), 0.8)
                }
                .onEnded { _ in
                    isDraggingHorizontal = false
                }
        )
    }

    private func slotPane(slotIndex: Int,
                          axis: MTKCore.Axis,
                          surface: MetalViewportSurface,
                          presentationPriority: Int = 0) -> some View {
        GeometryReader { proxy in
            let offset = controller.crosshairOffsets[axis] ?? .zero
            let angleDegrees = controller.crosshairAngles[axis] ?? 0.0

            ZStack {
                MetalViewportContainer(surface: surface, presentationPriority: presentationPriority) {
                    ZStack {
                        CrosshairOverlayView(style: style, position: offset, angle: Angle(degrees: angleDegrees))
                        OrientationOverlayView(transform: controller.displayTransform(for: axis), style: style)
                        viewportOverlay?(controller.debugSnapshot(for: controller.viewportID(for: axis)))
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(mprGesture(axis: axis, size: proxy.size))
                .simultaneousGesture(mprMagnificationGesture(axis: axis))
                .onAppear {
                    attachMPRScrollWheel(axis: axis, surface: surface)
                    schedulePostLayoutRender(axis: axis)
                }
                .onChange(of: proxy.size) { _, _ in
                    schedulePostLayoutRender(axis: axis)
                }
                .onDisappear {
                    surface.onScrollWheel = nil
                }

                paneControls(slotIndex: slotIndex, axis: axis)
            }
        }
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .modifier(MPRComputerTestActionsModifier(enabled: computerTestActionsEnabled,
                                                 axis: axis,
                                                 controller: controller))
    }

    private func paneControls(slotIndex: Int, axis: MTKCore.Axis) -> some View {
        VStack {
            HStack {
                axisMenu(for: slotIndex, currentAxis: axis)
                Spacer()
                Button(action: {
                    if fullscreenSlot == slotIndex {
                        fullscreenSlot = nil
                    } else {
                        fullscreenSlot = slotIndex
                    }
                }) {
                    Image(systemName: fullscreenSlot == slotIndex ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .padding(6)
                        .background(style.overlayBackground.cornerRadius(12))
                        .foregroundStyle(style.overlayForeground)
                }
                .accessibilityIdentifier("ClinicalViewportFullscreenToggle")
            }
            Spacer()
        }
        .padding(8)
    }

    private struct ViewportGridLayout {
        var rect1: CGRect
        var rect2: CGRect
        var rect3: CGRect
        var horizontalDivider: CGRect
        var verticalDivider: CGRect
    }

    private func computeViewportLayout(totalWidth: CGFloat, totalHeight: CGFloat) -> ViewportGridLayout {
        if fullscreenSlot != nil {
            let full = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            let zero = CGRect.zero
            return ViewportGridLayout(
                rect1: fullscreenSlot == 1 ? full : zero,
                rect2: fullscreenSlot == 2 ? full : zero,
                rect3: fullscreenSlot == 3 ? full : zero,
                horizontalDivider: zero,
                verticalDivider: zero
            )
        }

        let dividerThickness: CGFloat = 12
        let halfDivider = dividerThickness / 2
        let topHeight = max(totalHeight * verticalSplit - halfDivider, 1)
        let bottomHeight = max(totalHeight * (1.0 - verticalSplit) - halfDivider, 1)
        let leftWidth = max(totalWidth * horizontalSplit - halfDivider, 1)
        let rightWidth = max(totalWidth * (1.0 - horizontalSplit) - halfDivider, 1)

        let bottomY = topHeight + dividerThickness
        let bottomXRight = leftWidth + dividerThickness

        return ViewportGridLayout(
            rect1: CGRect(x: 0, y: 0, width: totalWidth, height: topHeight),
            rect2: CGRect(x: 0, y: bottomY, width: leftWidth, height: bottomHeight),
            rect3: CGRect(x: bottomXRight, y: bottomY, width: rightWidth, height: bottomHeight),
            horizontalDivider: CGRect(x: 0, y: topHeight, width: totalWidth, height: dividerThickness),
            verticalDivider: CGRect(x: leftWidth, y: bottomY, width: dividerThickness, height: bottomHeight)
        )
    }

    private func positionedSlot(slotIndex: Int,
                                axis: MTKCore.Axis,
                                rect: CGRect) -> some View {
        let isHidden = rect.width <= 0 || rect.height <= 0
        let isFullscreen = fullscreenSlot == slotIndex
        return slotPane(slotIndex: slotIndex,
                        axis: axis,
                        surface: controller.surface(for: axis))
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .position(x: rect.midX, y: rect.midY)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .zIndex(isFullscreen ? 1 : 0)
    }

    private func viewportGrid() -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let totalHeight = proxy.size.height
            let layout = computeViewportLayout(totalWidth: totalWidth, totalHeight: totalHeight)

            ZStack(alignment: .topLeading) {
                positionedSlot(slotIndex: 1, axis: slot1Axis, rect: layout.rect1)
                positionedSlot(slotIndex: 2, axis: slot2Axis, rect: layout.rect2)
                positionedSlot(slotIndex: 3, axis: slot3Axis, rect: layout.rect3)

                if fullscreenSlot == nil {
                    horizontalDivider(totalHeight: totalHeight)
                        .frame(width: layout.horizontalDivider.width,
                               height: layout.horizontalDivider.height)
                        .position(x: layout.horizontalDivider.midX,
                                  y: layout.horizontalDivider.midY)

                    verticalDivider(totalWidth: totalWidth)
                        .frame(width: layout.verticalDivider.width,
                               height: layout.verticalDivider.height)
                        .position(x: layout.verticalDivider.midX,
                                  y: layout.verticalDivider.midY)
                }
            }
            .frame(width: totalWidth, height: totalHeight)
        }
    }

    private func schedulePostLayoutRender(axis: MTKCore.Axis) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            await controller.refreshPresentationLayout(for: axis)
        }
    }

    private func mprGesture(axis: MTKCore.Axis, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }

                let now = CFAbsoluteTimeGetCurrent()
                let shouldBeginInteraction = activeMPRGestures.insert(axis).inserted
                controller.setActiveMPRAxis(axis)
                let previous = lastMPRDragTranslations[axis] ?? .zero
                let delta = CGSize(width: value.translation.width - previous.width,
                                   height: value.translation.height - previous.height)
                lastMPRDragTranslations[axis] = value.translation
                let normalized = CGPoint(
                    x: min(max(value.location.x / size.width, 0), 1),
                    y: min(max(value.location.y / size.height, 0), 1)
                )

                let gestureType: MPRGestureType
                if let existingType = activeMPRGestureTypes[axis] {
                    gestureType = existingType
                } else {
                    switch controller.mprInteractionTool {
                    case .pan:
                        gestureType = .pan
                    case .windowLevel:
                        gestureType = .windowLevel
                    case .crosshair, .slice:
                        let offset = controller.crosshairOffsets[axis] ?? .zero
                        let center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
                        let dx = value.startLocation.x - center.x
                        let dy = value.startLocation.y - center.y
                        let distance = sqrt(dx*dx + dy*dy)

                        if distance <= 24.0 {
                            gestureType = .crosshair
                        } else {
                            let angleDegrees = controller.crosshairAngles[axis] ?? 0.0
                            let theta = angleDegrees * .pi / 180.0
                            let d_h = abs(-sin(theta) * Double(dx) + cos(theta) * Double(dy))
                            let d_v = abs(cos(theta) * Double(dx) + sin(theta) * Double(dy))

                            if min(d_h, d_v) <= 20.0 {
                                gestureType = .tilt
                                startDragAngles[axis] = angleDegrees
                            } else {
                                gestureType = .slice
                            }
                        }
                    }
                    activeMPRGestureTypes[axis] = gestureType
                }

                if shouldBeginInteraction {
                    Task { @MainActor in
                        logMPRInteractionInfo("[MTKMPRInteraction] swiftui.drag.begin axis=\(axis) tool=\(controller.mprInteractionTool) gestureType=\(gestureType)")
                        await controller.beginAdaptiveSamplingInteraction()
                    }
                }
                if abs(delta.width) >= 0.5 || abs(delta.height) >= 0.5 {
                    let eventDeltaMilliseconds = lastMPRDragEventTimes[axis].map {
                        max(0, (now - $0) * 1000.0)
                    } ?? 0
                    logMPRInteractionDebug(String(format: "[MTKMPRInteraction][MTKPerf] swiftui.drag.delta axis=%@ gestureType=%@ dx=%.2f dy=%.2f normalized=(%.3f,%.3f) eventDtMs=%.3f",
                                                 String(describing: axis),
                                                 String(describing: gestureType),
                                                 delta.width,
                                                 delta.height,
                                                 normalized.x,
                                                 normalized.y,
                                                 eventDeltaMilliseconds))
                }
                lastMPRDragEventTimes[axis] = now
                let enqueuedAt = CFAbsoluteTimeGetCurrent()
                pendingMPRGestureTasks[axis] = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let latency = max(0, (CFAbsoluteTimeGetCurrent() - enqueuedAt) * 1000.0)
                    logMPRInteractionDebug(String(format: "[MTKMPRInteraction][MTKPerf] swiftui.drag.apply axis=%@ gestureType=%@ dx=%.2f dy=%.2f mainActorLatencyMs=%.3f",
                                                 String(describing: axis),
                                                 String(describing: gestureType),
                                                 delta.width,
                                                 delta.height,
                                                 latency))
                    switch gestureType {
                    case .crosshair:
                        await controller.setCrosshair(in: axis, normalizedPoint: normalized)
                    case .tilt:
                        let offset = controller.crosshairOffsets[axis] ?? .zero
                        let center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
                        let currentDragAngle = atan2(Double(value.location.y - center.y), Double(value.location.x - center.x))
                        let startDragTouchAngle = atan2(Double(value.startLocation.y - center.y), Double(value.startLocation.x - center.x))
                        let deltaAngle = currentDragAngle - startDragTouchAngle
                        let initialAngleDegrees = startDragAngles[axis] ?? 0.0
                        let newAngleDegrees = (initialAngleDegrees + (deltaAngle * 180.0 / .pi)).truncatingRemainder(dividingBy: 360.0)
                        controller.setCrosshairAngle(newAngleDegrees, for: axis)
                    case .slice:
                        let deltaNormalized = Float(delta.height / max(size.height, 1))
                        await controller.scrollSlice(axis: axis, deltaNormalized: deltaNormalized)
                    case .pan:
                        let deltaNormalized = SIMD2<Float>(
                            Float(delta.width / max(size.width, 1)),
                            Float(delta.height / max(size.height, 1))
                        )
                        controller.panMPR(axis: axis, deltaNormalized: deltaNormalized)
                    case .windowLevel:
                        await controller.adjustMPRWindowLevel(screenDelta: delta)
                    }
                }
            }
            .onEnded { _ in
                logMPRInteractionInfo("[MTKMPRInteraction] swiftui.drag.end axis=\(axis)")
                lastMPRDragTranslations[axis] = nil
                lastMPRDragEventTimes[axis] = nil
                activeMPRGestureTypes[axis] = nil
                startDragAngles[axis] = nil
                pendingMPRGestureTasks[axis] = nil
                if activeMPRGestures.remove(axis) != nil {
                    Task { @MainActor in await controller.endAdaptiveSamplingInteraction() }
                }
            }
    }

    private func mprMagnificationGesture(axis: MTKCore.Axis) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let now = CFAbsoluteTimeGetCurrent()
                let shouldBeginInteraction = activeMPRMagnificationGestures.insert(axis).inserted
                controller.setActiveMPRAxis(axis)
                let previous = lastMPRMagnifications[axis] ?? 1
                let factor = previous > 0 ? value.magnification / previous : value.magnification
                lastMPRMagnifications[axis] = value.magnification
                let anchor = SIMD2<Float>(Float(value.startAnchor.x),
                                          Float(value.startAnchor.y))

                if shouldBeginInteraction {
                    Task { @MainActor in
                        logMPRInteractionInfo("[MTKMPRInteraction] swiftui.pinch.begin axis=\(axis)")
                        await controller.beginAdaptiveSamplingInteraction()
                    }
                }
                if abs(factor - 1) >= 0.005 {
                    let eventDeltaMilliseconds = lastMPRMagnificationEventTimes[axis].map {
                        max(0, (now - $0) * 1000.0)
                    } ?? 0
                    logMPRInteractionDebug(String(format: "[MTKMPRInteraction][MTKPerf] swiftui.pinch.factor axis=%@ factor=%.4f cumulative=%.4f anchor=(%.3f,%.3f) eventDtMs=%.3f",
                                                 String(describing: axis),
                                                 Double(factor),
                                                 Double(value.magnification),
                                                 anchor.x,
                                                 anchor.y,
                                                 eventDeltaMilliseconds))
                }
                lastMPRMagnificationEventTimes[axis] = now
                let enqueuedAt = CFAbsoluteTimeGetCurrent()
                pendingMPRMagnificationTasks[axis] = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    let latency = max(0, (CFAbsoluteTimeGetCurrent() - enqueuedAt) * 1000.0)
                    logMPRInteractionDebug(String(format: "[MTKMPRInteraction][MTKPerf] swiftui.pinch.apply axis=%@ factor=%.4f mainActorLatencyMs=%.3f",
                                                 String(describing: axis),
                                                 Double(factor),
                                                 latency))
                    controller.zoomMPR(axis: axis, factor: Float(factor), anchor: anchor)
                }
            }
            .onEnded { _ in
                logMPRInteractionInfo("[MTKMPRInteraction] swiftui.pinch.end axis=\(axis)")
                lastMPRMagnifications[axis] = nil
                lastMPRMagnificationEventTimes[axis] = nil
                pendingMPRMagnificationTasks[axis] = nil
                if activeMPRMagnificationGestures.remove(axis) != nil {
                    Task { @MainActor in await controller.endAdaptiveSamplingInteraction() }
                }
            }
    }

    private func commitWindowLevel() {
        Task {
            await controller.setMPRWindowLevel(window: draftWindowLevel.window,
                                               level: draftWindowLevel.level)
        }
    }

    private func commitSlabThickness(_ thickness: Double) {
        Task {
            await controller.setMPRSlabThickness(thickness)
        }
    }



    private func attachMPRScrollWheel(axis: MTKCore.Axis, surface: MetalViewportSurface) {
        surface.onScrollWheel = { [weak controller] deltaY, hasPreciseScrollingDeltas in
            guard let controller else { return }
            let steps = MPRScrollStepMapper.steps(deltaY: deltaY,
                                                  hasPreciseScrollingDeltas: hasPreciseScrollingDeltas)
            guard steps != 0 else { return }
            Task { @MainActor in
                logMPRInteractionInfo("[MTKMPRInteraction] scrollWheel axis=\(axis) steps=\(steps)")
                await controller.scrollSlice(axis: axis, steps: steps)
            }
        }
    }

    private var computerTestActionsEnabled: Bool {
        if ProcessInfo.processInfo.environment["MTK_COMPUTER_TEST_ACTIONS"] == "1" {
            return true
        }
#if DEBUG
        return true
#else
        return false
#endif
    }

    private var paneBackground: Color {
#if os(iOS)
        Color(.systemBackground)
#elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
#endif
    }

    private func logMPRInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.mprInteractionLoggingEnabled else { return }
        MTKCore.Logger.info(message(), category: "com.mtk.ui.ClinicalViewportGrid")
    }

    private func logMPRInteractionDebug(_ message: @autoclosure () -> String) {
        guard Logger.mprInteractionLoggingEnabled else { return }
        MTKCore.Logger.debug(message(), category: "com.mtk.ui.ClinicalViewportGrid")
    }
}

@MainActor
private struct MPRComputerTestActionsModifier: ViewModifier {
    let enabled: Bool
    let axis: MTKCore.Axis
    let controller: ClinicalViewportGridController

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(axisDisplayName) MPR pane"))
                .accessibilityIdentifier("MTKClinicalMPRPane.\(axisIdentifier)")
                .accessibilityAction(named: Text("Scroll slice forward")) {
                    Task { @MainActor in
                        await controller.scrollSlice(axis: axis, steps: 1)
                    }
                }
                .accessibilityAction(named: Text("Scroll slice backward")) {
                    Task { @MainActor in
                        await controller.scrollSlice(axis: axis, steps: -1)
                    }
                }
        } else {
            content
        }
    }

    private var axisDisplayName: String {
        switch axis {
        case .axial:
            return "Axial"
        case .coronal:
            return "Coronal"
        case .sagittal:
            return "Sagittal"
        }
    }

    private var axisIdentifier: String {
        switch axis {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }
}
#endif
