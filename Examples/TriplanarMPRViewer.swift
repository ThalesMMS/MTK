//
//  TriplanarMPRViewer.swift
//  MTK Examples
//
//  MPR-only engine-native example with one shared VolumeResourceHandle.
//

import SwiftUI
import Metal
import MTKCore
import MTKUI

private func axisTitle(for axis: MTKCore.Axis) -> String {
    switch axis {
    case .axial:
        return "Axial"
    case .coronal:
        return "Coronal"
    case .sagittal:
        return "Sagittal"
    }
}

/// Example purpose: shared resource model and ref-counted GPU texture pattern.
///
/// ADR concepts demonstrated:
/// the dataset is uploaded once through `engine.setVolume(_:for:)`, producing a
/// single `VolumeResourceHandle` shared by axial, coronal, and sagittal
/// viewports. Each pane renders from that shared GPU resource, so there is no
/// duplicate 3D texture upload for the three orthogonal reviews.
/// See `MTK/Architecture/ClinicalRenderingADR.md`.
///
/// Interactive MPR presentation remains Metal-native as `MTLTexture` until
/// `PresentationPass` presents into `MTKView`. This example does not use
/// SceneKit or `CGImage` for display.
struct TriplanarMPRViewerExample: View {
    @State private var controller: SharedTriplanarMPRExampleController?
    @State private var didConfigureExample = false
    @State private var errorMessage: String?

    private let axes: [MTKCore.Axis] = [.axial, .coronal, .sagittal]

    var body: some View {
        Group {
            if let controller {
                TriplanarMPRContent(controller: controller, axes: axes)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to Prepare Triplanar Viewer",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Preparing triplanar MPR viewports...")
            }
        }
        .task {
            await configureExampleIfNeeded()
        }
        .onDisappear {
            let controller = controller
            Task {
                await controller?.shutdown()
                self.controller = nil
                didConfigureExample = false
            }
        }
    }

    @MainActor
    private func configureExampleIfNeeded() async {
        guard !didConfigureExample else { return }
        didConfigureExample = true
        errorMessage = nil

        do {
            let controller = try await SharedTriplanarMPRExampleController.make()

            let dataset = makeSampleDataset()

            // One dataset load produces one VolumeResourceHandle shared across
            // axial/coronal/sagittal viewports. Moving slice planes updates
            // viewport configuration only; it does not duplicate GPU volume data.
            try await controller.applyDataset(dataset)
            await controller.setSlicePosition(axis: .axial, normalizedPosition: 0.35)
            await controller.setSlicePosition(axis: .coronal, normalizedPosition: 0.50)
            await controller.setSlicePosition(axis: .sagittal, normalizedPosition: 0.65)
            self.controller = controller
        } catch {
            self.controller = nil
            didConfigureExample = false
            errorMessage = error.localizedDescription
        }
    }

    private func makeSampleDataset() -> VolumeDataset {
        let width = 384
        let height = 384
        let depth = 220
        let voxelCount = width * height * depth
        let bytesPerVoxel = VolumePixelFormat.int16Signed.bytesPerVoxel
        let voxels = Data(repeating: 0, count: voxelCount * bytesPerVoxel)

        return VolumeDataset(
            data: voxels,
            dimensions: VolumeDimensions(width: width, height: height, depth: depth),
            spacing: VolumeSpacing(x: 0.00075, y: 0.00075, z: 0.0010),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: -160...240
        )
    }
}

@MainActor
private struct TriplanarMPRContent: View {
    @ObservedObject var controller: SharedTriplanarMPRExampleController
    let axes: [MTKCore.Axis]

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(axes, id: \.self) { axis in
                    pane(for: axis)
                }
            }
            .padding(.horizontal)

            sliceControls

            if let handle = controller.sharedResourceHandle {
                Text(
                    "Shared VolumeResourceHandle: " +
                    "\(handle.metadata.dimensions.width)x" +
                    "\(handle.metadata.dimensions.height)x" +
                    "\(handle.metadata.dimensions.depth)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pane(for axis: MTKCore.Axis) -> some View {
        MetalViewportContainer(surface: controller.surface(for: axis)) {
            ZStack {
                OrientationOverlayView(transform: controller.displayTransform(for: axis))
                paneBadge(axisTitle(for: axis))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sliceControls: some View {
        VStack(spacing: 12) {
            ForEach(axes, id: \.self) { axis in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(axisTitle(for: axis)) Slice")
                        .font(.caption.weight(.semibold))
                    Slider(
                        value: Binding(
                            get: { Double(controller.normalizedPosition(for: axis)) },
                            set: { newValue in
                                Task {
                                    await controller.setSlicePosition(
                                        axis: axis,
                                        normalizedPosition: Float(newValue)
                                    )
                                }
                            }
                        ),
                        in: 0...1
                    )
                }
            }
        }
        .padding(.horizontal)
    }

    private func paneBadge(_ title: String) -> some View {
        VStack {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                Spacer()
            }
            Spacer()
        }
        .padding(8)
    }

}

@MainActor
private final class SharedTriplanarMPRExampleController: ObservableObject {
    @Published private(set) var sharedResourceHandle: VolumeResourceHandle?
    @Published private(set) var lastError: String?
    @Published private var displayTransformStore: [MTKCore.Axis: MPRDisplayTransform] = [
        .axial: .identity,
        .coronal: .identity,
        .sagittal: .identity
    ]
    @Published private var normalizedPositionStore: [MTKCore.Axis: Float] = [
        .axial: 0.5,
        .coronal: 0.5,
        .sagittal: 0.5
    ]

    private let engine: MTKRenderingEngine
    private let axialViewportID: ViewportID
    private let coronalViewportID: ViewportID
    private let sagittalViewportID: ViewportID

    private let axialSurface: MetalViewportSurface
    private let coronalSurface: MetalViewportSurface
    private let sagittalSurface: MetalViewportSurface

    private var window: ClosedRange<Int32> = -160...240

    static func make(initialViewportSize: CGSize = CGSize(width: 512, height: 512)) async throws
        -> SharedTriplanarMPRExampleController {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MTKRenderingEngine.EngineError.metalDeviceUnavailable
        }

        let engine = try await MTKRenderingEngine(device: device)
        let axialSurface = try MetalViewportSurface(device: device)
        let coronalSurface = try MetalViewportSurface(device: device)
        let sagittalSurface = try MetalViewportSurface(device: device)

        let axialViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .axial), initialSize: initialViewportSize, label: "Axial")
        )
        let coronalViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .coronal), initialSize: initialViewportSize, label: "Coronal")
        )
        let sagittalViewportID = try await engine.createViewport(
            ViewportDescriptor(type: .mpr(axis: .sagittal), initialSize: initialViewportSize, label: "Sagittal")
        )

        return SharedTriplanarMPRExampleController(
            engine: engine,
            axialViewportID: axialViewportID,
            coronalViewportID: coronalViewportID,
            sagittalViewportID: sagittalViewportID,
            axialSurface: axialSurface,
            coronalSurface: coronalSurface,
            sagittalSurface: sagittalSurface
        )
    }

    private init(engine: MTKRenderingEngine,
                 axialViewportID: ViewportID,
                 coronalViewportID: ViewportID,
                 sagittalViewportID: ViewportID,
                 axialSurface: MetalViewportSurface,
                 coronalSurface: MetalViewportSurface,
                 sagittalSurface: MetalViewportSurface) {
        self.engine = engine
        self.axialViewportID = axialViewportID
        self.coronalViewportID = coronalViewportID
        self.sagittalViewportID = sagittalViewportID
        self.axialSurface = axialSurface
        self.coronalSurface = coronalSurface
        self.sagittalSurface = sagittalSurface
    }

    func surface(for axis: MTKCore.Axis) -> MetalViewportSurface {
        switch axis {
        case .axial:
            return axialSurface
        case .coronal:
            return coronalSurface
        case .sagittal:
            return sagittalSurface
        }
    }

    func displayTransform(for axis: MTKCore.Axis) -> MPRDisplayTransform {
        displayTransformStore[axis] ?? .identity
    }

    func normalizedPosition(for axis: MTKCore.Axis) -> Float {
        normalizedPositionStore[axis] ?? 0.5
    }

    func applyDataset(_ dataset: VolumeDataset) async throws {
        // The engine acquires one shared handle here and retains it across the
        // three MPR viewports, matching the ADR resource-sharing model.
        let handle = try await engine.setVolume(
            dataset,
            for: [axialViewportID, coronalViewportID, sagittalViewportID]
        )
        sharedResourceHandle = handle
        window = dataset.recommendedWindow ?? dataset.intensityRange

        for axis in [MTKCore.Axis.axial, .coronal, .sagittal] {
            try await configureViewport(axis: axis)
        }

        try await renderAll()
    }

    func setSlicePosition(axis: MTKCore.Axis, normalizedPosition: Float) async {
        let clamped = min(max(normalizedPosition, 0), 1)
        normalizedPositionStore[axis] = clamped

        do {
            try await configureViewport(axis: axis)
            try await render(axis: axis)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func shutdown() async {
        await engine.destroyViewport(axialViewportID)
        await engine.destroyViewport(coronalViewportID)
        await engine.destroyViewport(sagittalViewportID)
    }

    private func configureViewport(axis: MTKCore.Axis) async throws {
        let viewportID = viewportID(for: axis)
        let normalizedPosition = normalizedPositionStore[axis] ?? 0.5
        try await engine.configure(viewportID, slicePosition: normalizedPosition, window: window)
        try await engine.configure(viewportID, slabThickness: 3, slabSteps: 7, blend: .single)
    }

    private func renderAll() async throws {
        for axis in [MTKCore.Axis.axial, .coronal, .sagittal] {
            try await render(axis: axis)
        }
    }

    private func render(axis: MTKCore.Axis) async throws {
        let viewportID = viewportID(for: axis)
        let frame = try await engine.render(viewportID)
        guard let mprFrame = frame.mprFrame else {
            throw MTKRenderingEngine.EngineError.renderTextureUnavailable
        }

        let transform = MPRDisplayTransformFactory.makeTransform(
            for: mprFrame.planeGeometry,
            axis: planeAxis(for: axis)
        )
        displayTransformStore[axis] = transform

        _ = try surface(for: axis).present(
            mprFrame: mprFrame,
            window: window,
            transform: transform
        )
    }

    private func viewportID(for axis: MTKCore.Axis) -> ViewportID {
        switch axis {
        case .axial:
            return axialViewportID
        case .coronal:
            return coronalViewportID
        case .sagittal:
            return sagittalViewportID
        }
    }

    private func planeAxis(for axis: MTKCore.Axis) -> MPRPlaneAxis {
        switch axis {
        case .axial:
            return .z
        case .coronal:
            return .y
        case .sagittal:
            return .x
        }
    }
}

/*
 This example is intentionally MPR-only. It does not create a 3D pane, does not
 use SceneKit, and does not upload one texture per anatomical plane. The shared
 `VolumeResourceHandle` keeps the axial/coronal/sagittal viewports on one GPU
 volume resource while slice changes only reconfigure viewport state. `CGImage`
 remains export-only and is not part of the interactive display path.
 */
