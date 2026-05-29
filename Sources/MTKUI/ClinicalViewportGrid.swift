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
    private let screenLayout: MPRScreenLayout
    private let showsAnnotations: Bool
    private let showsCrosshair: Bool
    private let showsCompactChrome: Bool
    private let hangingProtocolDefinition: HangingProtocolDefinition?
    private let hangingProtocolContext: HangingProtocolContext?

    /// Creates a clinical 2x2 viewport grid from the public viewport session contract.
    public init(session: ClinicalViewportSession,
                viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
                interactionMode: NativeVolume3DInteractionMode = .orbit,
                screenLayout: MPRScreenLayout = .defaultLayout,
                showsAnnotations: Bool = true,
                showsCrosshair: Bool = true,
                showsCompactChrome: Bool = true,
                hangingProtocolDefinition: HangingProtocolDefinition? = nil,
                hangingProtocolContext: HangingProtocolContext? = nil,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        _store = StateObject(wrappedValue: ClinicalViewportGridControllerStore(session: session,
                                                                               dataset: nil))
        self.style = style
        self.viewportOverlay = viewportOverlay
        self.interactionMode = interactionMode
        self.screenLayout = screenLayout
        self.showsAnnotations = showsAnnotations
        self.showsCrosshair = showsCrosshair
        self.showsCompactChrome = showsCompactChrome
        self.hangingProtocolDefinition = hangingProtocolDefinition
        self.hangingProtocolContext = hangingProtocolContext
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
                screenLayout: MPRScreenLayout = .defaultLayout,
                showsAnnotations: Bool = true,
                showsCrosshair: Bool = true,
                showsCompactChrome: Bool = true,
                hangingProtocolDefinition: HangingProtocolDefinition? = nil,
                hangingProtocolContext: HangingProtocolContext? = nil,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        _store = StateObject(wrappedValue: ClinicalViewportGridControllerStore(controller: controller,
                                                                               dataset: dataset))
        self.style = style
        self.viewportOverlay = viewportOverlay
        self.interactionMode = interactionMode
        self.screenLayout = screenLayout
        self.showsAnnotations = showsAnnotations
        self.showsCrosshair = showsCrosshair
        self.showsCompactChrome = showsCompactChrome
        self.hangingProtocolDefinition = hangingProtocolDefinition
        self.hangingProtocolContext = hangingProtocolContext
    }

    public var body: some View {
        Group {
            if let controller = store.controller {
                ClinicalViewportGridContent(controller: controller,
                                            viewportOverlay: viewportOverlay,
                                            interactionMode: interactionMode,
                                            screenLayout: screenLayout,
                                            showsAnnotations: showsAnnotations,
                                            showsCrosshair: showsCrosshair,
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
            await store.applyHangingProtocolIfNeeded(definition: hangingProtocolDefinition,
                                                     context: hangingProtocolContext)
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

    func applyHangingProtocolIfNeeded(definition: HangingProtocolDefinition?,
                                      context: HangingProtocolContext?) async {
        guard let definition,
              let controller
        else { return }
        await controller.applyHangingProtocol(definition, context: context)
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
    case roi
}

struct MPRViewportGridLayout: Equatable {
    var rect1: CGRect
    var rect2: CGRect
    var rect3: CGRect
    var dividers: [MPRViewportGridDivider]
}

enum MPRViewportGridDivider: Equatable {
    case horizontal(CGRect)
    case vertical(CGRect)
}

enum MPRViewportGridLayoutCalculator {
    static let dividerThickness: CGFloat = 12

    static func layout(for screenLayout: MPRScreenLayout,
                       totalWidth: CGFloat,
                       totalHeight: CGFloat,
                       verticalSplit: CGFloat,
                       horizontalSplit: CGFloat,
                       fullscreenSlot: Int?) -> MPRViewportGridLayout {
        if fullscreenSlot != nil {
            let full = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            let zero = CGRect.zero
            return MPRViewportGridLayout(
                rect1: fullscreenSlot == 1 ? full : zero,
                rect2: fullscreenSlot == 2 ? full : zero,
                rect3: fullscreenSlot == 3 ? full : zero,
                dividers: []
            )
        }

        let halfDivider = dividerThickness / 2
        let topHeight = max(totalHeight * verticalSplit - halfDivider, 1)
        let bottomHeight = max(totalHeight * (1.0 - verticalSplit) - halfDivider, 1)
        let leftWidth = max(totalWidth * horizontalSplit - halfDivider, 1)
        let rightWidth = max(totalWidth * (1.0 - horizontalSplit) - halfDivider, 1)

        let bottomY = topHeight + dividerThickness
        let bottomXRight = leftWidth + dividerThickness

        switch screenLayout {
        case .hSplit1x2:
            return MPRViewportGridLayout(
                rect1: CGRect(x: 0, y: 0, width: totalWidth, height: topHeight),
                rect2: CGRect(x: 0, y: bottomY, width: leftWidth, height: bottomHeight),
                rect3: CGRect(x: bottomXRight, y: bottomY, width: rightWidth, height: bottomHeight),
                dividers: [
                    .horizontal(CGRect(x: 0, y: topHeight, width: totalWidth, height: dividerThickness)),
                    .vertical(CGRect(x: leftWidth, y: bottomY, width: dividerThickness, height: bottomHeight))
                ]
            )
        case .hSplit2x1:
            return MPRViewportGridLayout(
                rect1: CGRect(x: 0, y: 0, width: leftWidth, height: topHeight),
                rect2: CGRect(x: bottomXRight, y: 0, width: rightWidth, height: topHeight),
                rect3: CGRect(x: 0, y: bottomY, width: totalWidth, height: bottomHeight),
                dividers: [
                    .horizontal(CGRect(x: 0, y: topHeight, width: totalWidth, height: dividerThickness)),
                    .vertical(CGRect(x: leftWidth, y: 0, width: dividerThickness, height: topHeight))
                ]
            )
        case .vSplit3x1:
            let rowHeight = max((totalHeight - dividerThickness * 2) / 3, 1)
            let firstDividerY = rowHeight
            let secondRowY = rowHeight + dividerThickness
            let secondDividerY = secondRowY + rowHeight
            let thirdRowY = secondDividerY + dividerThickness
            return MPRViewportGridLayout(
                rect1: CGRect(x: 0, y: 0, width: totalWidth, height: rowHeight),
                rect2: CGRect(x: 0, y: secondRowY, width: totalWidth, height: rowHeight),
                rect3: CGRect(x: 0, y: thirdRowY, width: totalWidth, height: rowHeight),
                dividers: [
                    .horizontal(CGRect(x: 0, y: firstDividerY, width: totalWidth, height: dividerThickness)),
                    .horizontal(CGRect(x: 0, y: secondDividerY, width: totalWidth, height: dividerThickness))
                ]
            )
        }
    }
}

@MainActor
private struct ClinicalViewportGridContent: View {
    @ObservedObject private var controller: ClinicalViewportGridController
    private let style: any VolumetricUIStyle
    private let viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)?
    private let interactionMode: NativeVolume3DInteractionMode
    private let screenLayout: MPRScreenLayout
    private let showsAnnotations: Bool
    private let showsCrosshair: Bool
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
         screenLayout: MPRScreenLayout = .defaultLayout,
         showsAnnotations: Bool = true,
         showsCrosshair: Bool = true,
         showsCompactChrome: Bool = true,
         style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.viewportOverlay = viewportOverlay
        self.style = style
        self.interactionMode = interactionMode
        self.screenLayout = screenLayout
        self.showsAnnotations = showsAnnotations
        self.showsCrosshair = showsCrosshair
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
        .onChange(of: screenLayout) { _, _ in
            schedulePostLayoutRender(for: slotContent(slot: 1, fallbackAxis: slot1Axis))
            schedulePostLayoutRender(for: slotContent(slot: 2, fallbackAxis: slot2Axis))
            schedulePostLayoutRender(for: slotContent(slot: 3, fallbackAxis: slot3Axis))
        }
        .accessibilityValue(effectiveScreenLayout.title)
        .accessibilityIdentifier("ClinicalViewportGrid")
    }

    private var effectiveScreenLayout: MPRScreenLayout {
        controller.hangingProtocolResolvedLayout?.screenLayout ?? screenLayout
    }

    private var hasResolvedHangingProtocol: Bool {
        controller.hangingProtocolResolvedLayout != nil
    }

    private func slotContent(slot: Int,
                             fallbackAxis: MTKCore.Axis) -> HangingProtocolViewportContent {
        controller.hangingProtocolViewportContent(for: slot) ??
        .mpr(HangingProtocolImagePlane(axis: fallbackAxis))
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
                          presentationPriority: Int = 0,
                          showsAxisControls: Bool = true) -> some View {
        GeometryReader { proxy in
            let offset = controller.crosshairOffsets[axis] ?? .zero
            let angleDegrees = controller.crosshairAngles[axis] ?? 0.0

            ZStack {
                MetalViewportContainer(surface: surface, presentationPriority: presentationPriority) {
                    ZStack {
                        if showsCrosshair {
                            CrosshairOverlayView(
                                style: style,
                                position: offset,
                                angle: Angle(degrees: angleDegrees),
                                accessibilityIdentifier: "MPRCrosshairOverlay.\(axisIdentifier(for: axis))"
                            )
                        }
                        if showsAnnotations {
                            OrientationOverlayView(transform: controller.displayTransform(for: axis), style: style)
                            MPRImageAnnotationsOverlay(
                                state: controller.mprImageAnnotationsOverlayState(slotIndex: slotIndex, axis: axis),
                                style: style
                            )
                        }
                        ViewerROIOverlayView(annotations: controller.mprROIAnnotations(for: axis)) { point in
                            controller.viewportPoint(forMPRROIImagePoint: point,
                                                      axis: axis,
                                                      viewportSize: proxy.size)
                        }
                        CADFindingOverlayView(
                            findings: controller.cadFindingsForOverlay(axis: axis),
                            selectedFindingID: controller.structuredReportViewerState?.selectedFindingID
                        )
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

                if showsAxisControls {
                    paneControls(slotIndex: slotIndex, axis: axis)
                }
            }
        }
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .modifier(MPRComputerTestActionsModifier(enabled: computerTestActionsEnabled,
                                                 axis: axis,
                                                 controller: controller))
    }

    private func axisIdentifier(for axis: MTKCore.Axis) -> String {
        switch axis {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
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

    private func computeViewportLayout(totalWidth: CGFloat, totalHeight: CGFloat) -> MPRViewportGridLayout {
        MPRViewportGridLayoutCalculator.layout(for: effectiveScreenLayout,
                                               totalWidth: totalWidth,
                                               totalHeight: totalHeight,
                                               verticalSplit: verticalSplit,
                                               horizontalSplit: horizontalSplit,
                                               fullscreenSlot: fullscreenSlot)
    }

    private func positionedSlot(slotIndex: Int,
                                fallbackAxis: MTKCore.Axis,
                                rect: CGRect) -> some View {
        let isHidden = rect.width <= 0 || rect.height <= 0
        let isFullscreen = fullscreenSlot == slotIndex
        let content = slotContent(slot: slotIndex, fallbackAxis: fallbackAxis)
        return slotView(slotIndex: slotIndex, content: content)
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .position(x: rect.midX, y: rect.midY)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .zIndex(isFullscreen ? 1 : 0)
    }

    @ViewBuilder
    private func slotView(slotIndex: Int,
                          content: HangingProtocolViewportContent) -> some View {
        switch content {
        case .mpr(let plane), .stack2D(let plane):
            let axis = plane.axis
            slotPane(slotIndex: slotIndex,
                     axis: axis,
                     surface: controller.surface(for: axis),
                     showsAxisControls: !hasResolvedHangingProtocol)
        case .volume3D:
            volumeSlotPane(slotIndex: slotIndex)
        }
    }

    private func volumeSlotPane(slotIndex: Int) -> some View {
        GeometryReader { _ in
            Group {
#if os(iOS)
                MetalViewportContainer(
                    surface: controller.volumeSurface,
                    native3DInteraction: NativeVolume3DInteraction(controller: controller,
                                                                   interactionMode: interactionMode)
                ) {
                    ZStack {
                        viewportOverlay?(controller.debugSnapshot(for: controller.volumeViewportID))
                    }
                    .allowsHitTesting(false)
                }
#else
                MetalViewportContainer(surface: controller.volumeSurface) {
                    ZStack {
                        viewportOverlay?(controller.debugSnapshot(for: controller.volumeViewportID))
                    }
                    .allowsHitTesting(false)
                }
#endif
            }
            .contentShape(Rectangle())
            .onAppear {
                schedulePostLayoutRender(for: .volume3D)
            }
            .onChange(of: controller.volumeViewportMode) { _, _ in
                schedulePostLayoutRender(for: .volume3D)
            }
        }
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("MTKClinicalVolumePane.\(slotIndex)")
    }

    private func viewportGrid() -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let totalHeight = proxy.size.height
            let layout = computeViewportLayout(totalWidth: totalWidth, totalHeight: totalHeight)

            ZStack(alignment: .topLeading) {
                positionedSlot(slotIndex: 1, fallbackAxis: slot1Axis, rect: layout.rect1)
                positionedSlot(slotIndex: 2, fallbackAxis: slot2Axis, rect: layout.rect2)
                positionedSlot(slotIndex: 3, fallbackAxis: slot3Axis, rect: layout.rect3)

                if fullscreenSlot == nil {
                    ForEach(Array(layout.dividers.enumerated()), id: \.offset) { _, divider in
                        positionedDivider(divider, totalWidth: totalWidth, totalHeight: totalHeight)
                    }
                }
            }
            .frame(width: totalWidth, height: totalHeight)
        }
    }

    @ViewBuilder
    private func positionedDivider(_ divider: MPRViewportGridDivider,
                                   totalWidth: CGFloat,
                                   totalHeight: CGFloat) -> some View {
        switch divider {
        case .horizontal(let rect):
            horizontalDivider(totalHeight: totalHeight)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .vertical(let rect):
            verticalDivider(totalWidth: totalWidth)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func schedulePostLayoutRender(axis: MTKCore.Axis) {
        Task { @MainActor in
            await Task.yield()
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            await controller.refreshPresentationLayout(for: axis)
        }
    }

    private func schedulePostLayoutRender(for content: HangingProtocolViewportContent) {
        switch content {
        case .mpr(let plane), .stack2D(let plane):
            schedulePostLayoutRender(axis: plane.axis)
        case .volume3D:
            Task { @MainActor in
                await Task.yield()
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                await controller.prepareDisplayedVolumeViewport()
            }
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
                    case .slice:
                        gestureType = .slice
                    case .rotation:
                        gestureType = .tilt
                        startDragAngles[axis] = controller.crosshairAngles[axis] ?? 0.0
                    case .roi:
                        gestureType = .roi
                    case .crosshair:
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
                        let newAngleDegrees = ClinicalViewportGridController.rotationAngleDegrees(
                            initialAngleDegrees: startDragAngles[axis] ?? 0.0,
                            center: center,
                            startLocation: value.startLocation,
                            currentLocation: value.location
                        )
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
                    case .roi:
                        break
                    }
                }
            }
            .onEnded { value in
                logMPRInteractionInfo("[MTKMPRInteraction] swiftui.drag.end axis=\(axis)")
                if activeMPRGestureTypes[axis] == .roi {
                    commitMPRROI(axis: axis, size: size, value: value)
                }
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
                guard controller.mprInteractionTool != .slice,
                      controller.mprInteractionTool != .windowLevel,
                      controller.mprInteractionTool != .roi else { return }
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

    private func commitMPRROI(axis: MTKCore.Axis,
                              size: CGSize,
                              value: DragGesture.Value) {
        guard let endPoint = controller.normalizedMPRImagePoint(for: axis,
                                                                viewportLocation: value.location,
                                                                viewportSize: size) else {
            return
        }
        let startPoint = controller.normalizedMPRImagePoint(for: axis,
                                                            viewportLocation: value.startLocation,
                                                            viewportSize: size)
        switch controller.mprROIKind {
        case .point, .text:
            _ = controller.addMPRROIFromGesture(axis: axis,
                                                startImagePoint: endPoint,
                                                endImagePoint: endPoint)
        case .distance, .angle, .cobbAngle, .area, .ellipse, .closedPath, .curvedLine, .arrow, .scribble, .volume, .ctr:
            guard let startPoint else { return }
            _ = controller.addMPRROIFromGesture(axis: axis,
                                                startImagePoint: startPoint,
                                                endImagePoint: endPoint)
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
            guard controller.mprInteractionTool == .slice else { return }
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

private struct ViewerROIOverlayView: View {
    let annotations: [ViewerROIAnnotation]
    let pointMapper: (CGPoint) -> CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(annotations) { annotation in
                annotationView(annotation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("ViewerROIOverlay")
    }

    @ViewBuilder
    private func annotationView(_ annotation: ViewerROIAnnotation) -> some View {
        switch annotation.kind {
        case .distance:
            if annotation.normalizedImagePoints.count >= 2 {
                let start = pointMapper(annotation.normalizedImagePoints[0])
                let end = pointMapper(annotation.normalizedImagePoints[1])
                let midpoint = CGPoint(x: (start.x + end.x) * 0.5,
                                       y: (start.y + end.y) * 0.5 - 14)
                line(from: start, to: end, annotation: annotation)
                label(annotation.measurement?.displayText ?? "Distance", annotation: annotation)
                    .position(midpoint)
            }
        case .angle:
            if annotation.normalizedImagePoints.count >= 3 {
                let points = annotation.normalizedImagePoints.prefix(3).map(pointMapper)
                polyline(points: points, annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .cobbAngle:
            if annotation.normalizedImagePoints.count >= 4 {
                let points = annotation.normalizedImagePoints.prefix(4).map(pointMapper)
                line(from: points[0], to: points[1], annotation: annotation)
                line(from: points[2], to: points[3], annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        case .point:
            if let point = annotation.normalizedImagePoints.first {
                pointMarker(at: pointMapper(point), annotation: annotation)
            }
        case .text:
            if let point = annotation.normalizedImagePoints.first {
                label(annotation.text ?? "Annotation", annotation: annotation)
                    .position(pointMapper(point))
            }
        case .arrow:
            if annotation.normalizedImagePoints.count >= 2 {
                arrow(from: pointMapper(annotation.normalizedImagePoints[0]),
                      to: pointMapper(annotation.normalizedImagePoints[1]),
                      annotation: annotation)
            }
        case .area, .closedPath, .volume:
            if annotation.normalizedImagePoints.count >= 3 {
                let points = annotation.normalizedImagePoints.map(pointMapper)
                polygon(points: points, annotation: annotation)
                label(annotation.text ?? annotation.measurement?.displayText ?? annotation.kind.displayName,
                      annotation: annotation)
                    .position(labelPoint(points: points))
            }
        case .ellipse:
            if annotation.normalizedImagePoints.count >= 2 {
                let points = annotation.normalizedImagePoints.map(pointMapper)
                ellipse(points: points, annotation: annotation)
                label(annotation.text ?? annotation.measurement?.displayText ?? annotation.kind.displayName,
                      annotation: annotation)
                    .position(labelPoint(points: points))
            }
        case .curvedLine, .scribble:
            if annotation.normalizedImagePoints.count >= 2 {
                let points = annotation.normalizedImagePoints.map(pointMapper)
                polyline(points: points, annotation: annotation)
                if let text = annotation.text ?? annotation.measurement?.displayText {
                    label(text, annotation: annotation)
                        .position(labelPoint(points: points, yOffset: -12))
                }
            }
        case .ctr:
            if annotation.normalizedImagePoints.count >= 4 {
                let points = annotation.normalizedImagePoints.prefix(4).map(pointMapper)
                line(from: points[0], to: points[1], annotation: annotation)
                line(from: points[2], to: points[3], annotation: annotation)
                label(annotation.measurement?.displayText ?? annotation.kind.displayName, annotation: annotation)
                    .position(labelPoint(points: points, yOffset: -12))
            }
        }
    }

    private func line(from start: CGPoint,
                      to end: CGPoint,
                      annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round))
    }

    private func arrow(from start: CGPoint,
                       to end: CGPoint,
                       annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 13
            let spread: CGFloat = .pi / 7
            let first = CGPoint(x: end.x - arrowLength * cos(angle - spread),
                                y: end.y - arrowLength * sin(angle - spread))
            let second = CGPoint(x: end.x - arrowLength * cos(angle + spread),
                                 y: end.y - arrowLength * sin(angle + spread))
            path.move(to: end)
            path.addLine(to: first)
            path.move(to: end)
            path.addLine(to: second)
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func polyline(points: [CGPoint],
                          annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func polygon(points: [CGPoint],
                         annotation: ViewerROIAnnotation) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func ellipse(points: [CGPoint],
                         annotation: ViewerROIAnnotation) -> some View {
        let rect = boundingRect(points: points)
        return Ellipse()
            .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                    style: StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func pointMarker(at point: CGPoint,
                             annotation: ViewerROIAnnotation) -> some View {
        Circle()
            .stroke(Color(viewerROIColor: annotation.style.strokeColor),
                    lineWidth: annotation.style.lineWidth)
            .frame(width: 10, height: 10)
            .position(point)
    }

    private func label(_ text: String,
                       annotation: ViewerROIAnnotation) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color(viewerROIColor: annotation.style.textColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color(viewerROIColor: annotation.style.labelBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func labelPoint(points: [CGPoint],
                            yOffset: CGFloat = 0) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count) + yOffset
        return CGPoint(x: x, y: y)
    }

    private func boundingRect(points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}

private extension Color {
    init(viewerROIColor color: ViewerROIColor) {
        self.init(red: color.red,
                  green: color.green,
                  blue: color.blue,
                  opacity: color.alpha)
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
