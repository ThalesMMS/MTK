//
//  ClinicalViewportGrid.swift
//  MTKUI
//
//  SwiftUI 2x2 clinical layout backed by MTKRenderingEngine viewports.
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import CoreGraphics
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

    /// Creates a clinical 2x2 viewport grid.
    ///
    /// Pass a preconfigured controller when ownership lives in a coordinator or view model. When
    /// `controller` is `nil`, the view creates one on the main actor and applies `dataset` once it
    /// is ready. The controller and view are `@MainActor` isolated; mutate them from UI code or by
    /// explicitly hopping to the main actor.
    public init(controller: ClinicalViewportGridController? = nil,
                dataset: VolumeDataset? = nil,
                viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        _store = StateObject(wrappedValue: ClinicalViewportGridControllerStore(controller: controller,
                                                                               dataset: dataset))
        self.style = style
        self.viewportOverlay = viewportOverlay
    }

    public var body: some View {
        Group {
            if let controller = store.controller {
                ClinicalViewportGridContent(controller: controller,
                                            viewportOverlay: viewportOverlay,
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
    @Published var controller: ClinicalViewportGridController?
    @Published var initializationError: (any Error)?

    private let initialDataset: VolumeDataset?
    private let ownsController: Bool
    private var preparationTask: Task<Void, Never>?
    private var didApplyInitialDataset = false

    init(controller: ClinicalViewportGridController?, dataset: VolumeDataset?) {
        self.controller = controller
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
                let resolvedController: ClinicalViewportGridController
                if let existingController = self.controller {
                    resolvedController = existingController
                } else {
                    resolvedController = try await ClinicalViewportGridController.make()
                    self.controller = resolvedController
                }

                if ownsController, let initialDataset, !didApplyInitialDataset {
                    try await resolvedController.applyDataset(initialDataset)
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
        guard let controller else { return }
        await controller.shutdown()
        self.controller = nil
        didApplyInitialDataset = false
    }
}

@MainActor
private struct ClinicalViewportGridContent: View {
    @ObservedObject private var controller: ClinicalViewportGridController
    private let style: any VolumetricUIStyle
    private let viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)?
    @State private var draftWindowLevel = WindowLevelShift(window: 400, level: 40)
    @State private var draftSlabThickness = 3.0
    @State private var pendingMPRGestureTasks: [MTKCore.Axis: Task<Void, Never>] = [:]
    @State private var activeMPRGestures = Set<MTKCore.Axis>()
    @State private var lastVolumeDragTranslation = CGSize.zero
    @State private var pendingVolumeGestureTask: Task<Void, Never>?
    @State private var volumeGestureActive = false

    init(controller: ClinicalViewportGridController,
         viewportOverlay: ((ClinicalViewportDebugSnapshot) -> AnyView)? = nil,
         style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.controller = controller
        self.viewportOverlay = viewportOverlay
        self.style = style
    }

    var body: some View {
        VStack(spacing: 12) {
            viewportGrid()
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
        .padding()
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

    private func viewportGrid() -> some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let paneSide = max(min((proxy.size.width - spacing) / 2,
                                   (proxy.size.height - spacing) / 2), 1)
            let usePlaceholders = paneSide < 4

            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    gridPane(usePlaceholders: usePlaceholders, size: paneSide) {
                        mprPane(axis: .axial, surface: controller.axialSurface, title: "Axial")
                    }
                    gridPane(usePlaceholders: usePlaceholders, size: paneSide) {
                        mprPane(axis: .coronal, surface: controller.coronalSurface, title: "Coronal")
                    }
                }
                HStack(spacing: spacing) {
                    gridPane(usePlaceholders: usePlaceholders, size: paneSide) {
                        mprPane(axis: .sagittal, surface: controller.sagittalSurface, title: "Sagittal")
                    }
                    gridPane(usePlaceholders: usePlaceholders, size: paneSide) {
                        volumePane(surface: controller.volumeSurface)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func gridPane<Content: View>(usePlaceholders: Bool,
                                        size: CGFloat,
                                        @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            if usePlaceholders {
                Color.clear
            } else {
                content()
            }
        }
        .frame(width: size, height: size)
    }

    private func mprPane(axis: MTKCore.Axis, surface: MetalViewportSurface, title: String) -> some View {
        GeometryReader { proxy in
            let offset = controller.crosshairOffsets[axis] ?? .zero

            MetalViewportContainer(surface: surface) {
                ZStack {
                    CrosshairOverlayView(style: style, position: offset)
                    OrientationOverlayView(transform: controller.displayTransform(for: axis), style: style)
                    paneBadge(title)
                    viewportOverlay?(controller.debugSnapshot(for: controller.viewportID(for: axis)))
                }
            }
            .contentShape(Rectangle())
            .gesture(mprGesture(axis: axis, size: proxy.size))
        }
        .aspectRatio(1, contentMode: .fit)
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func volumePane(surface: MetalViewportSurface) -> some View {
        MetalViewportContainer(surface: surface) {
            ZStack {
                paneBadge(controller.volumeViewportMode.displayName)
                viewportOverlay?(controller.debugSnapshot(for: controller.volumeViewportID))
            }
        }
        .contentShape(Rectangle())
        .gesture(volumeGesture())
        .aspectRatio(1, contentMode: .fit)
        .background(paneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func paneBadge(_ title: String) -> some View {
        VStack {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .padding(6)
                    .background(style.overlayBackground.cornerRadius(8))
                    .foregroundStyle(style.overlayForeground)
                    .accessibilityIdentifier("ClinicalViewportPaneTitle")
                Spacer()
            }
            Spacer()
        }
        .padding(8)
    }

    private func mprGesture(axis: MTKCore.Axis, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }

                // Treat the gesture as a crosshair drag (absolute location). Avoid also using the same
                // drag to scroll slices; that created conflicting semantics and platform differences.
                let shouldBeginInteraction = activeMPRGestures.insert(axis).inserted
                let normalized = CGPoint(
                    x: min(max(value.location.x / size.width, 0), 1),
                    y: min(max(value.location.y / size.height, 0), 1)
                )

                let beginInteractionTask = shouldBeginInteraction
                    ? Task { @MainActor in await controller.beginAdaptiveSamplingInteraction() }
                    : nil
                pendingMPRGestureTasks[axis]?.cancel()
                pendingMPRGestureTasks[axis] = Task { @MainActor in
                    await beginInteractionTask?.value
                    guard !Task.isCancelled else { return }
                    await controller.setCrosshair(in: axis, normalizedPoint: normalized)
                }
            }
            .onEnded { _ in
                pendingMPRGestureTasks[axis]?.cancel()
                pendingMPRGestureTasks[axis] = nil
                if activeMPRGestures.remove(axis) != nil {
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

    private func volumeGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let shouldBeginInteraction = !volumeGestureActive
                if shouldBeginInteraction {
                    volumeGestureActive = true
                }
                let previous = lastVolumeDragTranslation
                let delta = CGSize(width: value.translation.width - previous.width,
                                   height: value.translation.height - previous.height)
                lastVolumeDragTranslation = value.translation

                let beginInteractionTask = shouldBeginInteraction
                    ? Task { @MainActor in await controller.beginAdaptiveSamplingInteraction() }
                    : nil
                pendingVolumeGestureTask?.cancel()
                pendingVolumeGestureTask = Task { @MainActor in
                    await beginInteractionTask?.value
                    guard !Task.isCancelled else { return }
                    await controller.rotateVolumeCamera(screenDelta: delta)
                }
            }
            .onEnded { _ in
                lastVolumeDragTranslation = .zero
                pendingVolumeGestureTask?.cancel()
                pendingVolumeGestureTask = nil
                if volumeGestureActive {
                    volumeGestureActive = false
                    Task { @MainActor in await controller.endAdaptiveSamplingInteraction() }
                }
            }
    }

    private var paneBackground: Color {
#if os(iOS)
        Color(.systemBackground)
#elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
#endif
    }
}
#endif
