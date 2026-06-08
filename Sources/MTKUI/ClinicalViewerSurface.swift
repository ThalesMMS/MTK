#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import MTKCore
import SwiftUI

@MainActor
public struct ClinicalViewerSurface: View {
    @ObservedObject private var coordinator: ClinicalViewerCoordinator

    public init(coordinator: ClinicalViewerCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if !coordinator.isMetalAvailable {
                unavailableView
            } else if coordinator.mode == .single3D, let viewport = coordinator.volumeViewport3D {
#if os(iOS)
                MetalViewportContainer(
                    surface: viewport.metalSurface,
                    native3DInteraction: NativeVolume3DInteraction(
                        viewport: viewport,
                        interactionMode: coordinator.interactionMode
                    )
                )
                .accessibilityIdentifier("MTKClinicalViewerSingle3D")
#else
                MetalViewportContainer(surface: viewport.metalSurface)
                    .accessibilityIdentifier("MTKClinicalViewerSingle3D")
#endif
            } else if coordinator.mode == .clinical, let session = coordinator.clinicalViewportSession {
                ClinicalViewportGrid(
                    session: session,
                    viewportOverlay: coordinator.showDebugOverlay
                        ? { snapshot in AnyView(ClinicalViewportDebugOverlay(snapshot: snapshot)) }
                        : nil,
                    interactionMode: coordinator.interactionMode,
                    screenLayout: coordinator.selectedMPRScreenLayout,
                    showsAnnotations: coordinator.isMPRAnnotationsVisible,
                    showsCrosshair: coordinator.isMPRCrosshairVisible,
                    showsCompactChrome: false
                )
                .accessibilityIdentifier("MTKClinicalViewerGrid")
                .accessibilityValue(coordinator.selectedMPRScreenLayout.title)
            } else if coordinator.mode == .stack2D, let viewport = coordinator.stack2DViewport {
                ZStack {
                    Color.black
                    MetalViewportContainer(surface: viewport.metalSurface) {
                        ZStack {
                            Clinical2DViewportOverlay(state: twoDOverlayState(for: viewport))
                                .allowsHitTesting(false)
                            Clinical2DInteractionOverlay(
                                surface: viewport.metalSurface,
                                tool: coordinator.twoDTool,
                                axis: viewport.axis,
                                sliceIndex: coordinator.twoDSliceIndex,
                                roiKind: coordinator.twoDROIKind,
                                transform: coordinator.twoDTransform,
                                router: Clinical2DInteractionRouter(
                                    scrollDragPixelsPerStep: coordinator.twoDScrollSettings.dragPixelsPerStep,
                                    isScrollDirectionInverted: true
                                ),
                                handlers: twoDInteractionHandlers
                            )
                            if coordinator.twoDTool == .scroll,
                               coordinator.twoDScrollSettings.showsOnScreenControls {
                                twoDScrollControls
                            }
                        }
                    }
                    Color.clear
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("MTKClinicalViewer2D")
                        .accessibilityLabel("2D viewport")
                        .accessibilityValue(viewport.axis.clinicalDisplayName)
                        .allowsHitTesting(false)
                }
            } else if let message = coordinator.errorMessage {
                messageView(message)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.65))
        .task {
            coordinator.ensureActiveViewport()
        }
    }

    private var unavailableView: some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 28, weight: .bold))
                Text("Metal not available on this device.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("The clinical viewer requires MTKRenderingEngine and Metal-native surfaces.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func messageView(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
        }
    }

    private func twoDOverlayState(for viewport: StackViewport) -> Clinical2DViewportOverlayState {
        let metadata = coordinator.dataset?.imageData.clinicalMetadata
        return Clinical2DViewportOverlayState(
            axis: viewport.axis,
            subjectName: metadata?.patientName,
            studyTitle: metadata?.studyDescription,
            seriesTitle: metadata?.seriesDescription,
            imageSize: twoDImageSize(for: viewport),
            windowLevel: coordinator.twoDWindowLevel,
            sliceIndex: coordinator.twoDSliceIndex,
            sliceCount: coordinator.twoDSliceCount,
            zoom: coordinator.twoDTransform.zoom,
            pan: coordinator.twoDTransform.pan,
            angleDegrees: coordinator.twoDTransform.rotationRadians * 180.0 / .pi,
            isFlippedHorizontally: coordinator.twoDTransform.isFlippedHorizontally,
            isFlippedVertically: coordinator.twoDTransform.isFlippedVertically,
            slabThicknessMillimeters: twoDSlabThicknessMillimeters(for: viewport),
            locationMillimeters: twoDLocationMillimeters(for: viewport),
            activeTool: coordinator.twoDTool,
            roiKind: coordinator.twoDROIKind,
            roiAnnotations: coordinator.twoDROIAnnotations,
            showsCrosshair: coordinator.isTwoDSyncEnabled || coordinator.twoDTool == .reslice,
            hudSettings: coordinator.twoDHUDSettings,
            metadataSample: twoDMetadataSample(for: viewport),
            metadataOverlaySettings: coordinator.twoDMetadataOverlaySettings
        )
    }

    private var twoDInteractionHandlers: Clinical2DInteractionHandlers {
        Clinical2DInteractionHandlers(
            beginInteraction: { _ in
                coordinator.beginTwoDInteraction()
            },
            endInteraction: { _ in
                coordinator.endTwoDInteraction()
            },
            scrollSlices: { steps in
                coordinator.scrollTwoD(by: steps)
            },
            adjustWindowLevel: { delta in
                coordinator.adjustTwoDWindowLevel(screenDelta: delta)
            },
            rotate: { radians in
                coordinator.rotateTwoD(byRadians: radians)
            },
            pan: { deltaNormalized in
                coordinator.panTwoD(deltaNormalized: deltaNormalized)
            },
            zoom: { factor, anchor in
                coordinator.zoomTwoD(factor: factor, anchor: anchor)
            },
            commitROI: { interaction in
                coordinator.handleTwoDROIInteraction(interaction)
            }
        )
    }

    private var twoDScrollControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    coordinator.scrollTwoD(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous image")
                .accessibilityIdentifier("Clinical2DScrollPreviousButton")

                Button {
                    coordinator.scrollTwoD(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next image")
                .accessibilityIdentifier("Clinical2DScrollNextButton")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.62), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Clinical2DScrollControls")
        }
        .padding(.horizontal, 16)
    }

    private func twoDImageSize(for viewport: StackViewport) -> MPRImageAnnotationSize? {
        guard let dimensions = viewport.state.dataset?.dimensions else { return nil }
        switch viewport.axis {
        case .axial:
            return MPRImageAnnotationSize(width: dimensions.width, height: dimensions.height)
        case .coronal:
            return MPRImageAnnotationSize(width: dimensions.width, height: dimensions.depth)
        case .sagittal:
            return MPRImageAnnotationSize(width: dimensions.height, height: dimensions.depth)
        }
    }

    private func twoDSliceSpacingMillimeters(for viewport: StackViewport) -> Double? {
        guard let spacing = viewport.state.dataset?.spacing else { return nil }
        switch viewport.axis {
        case .axial:
            return spacing.z
        case .coronal:
            return spacing.y
        case .sagittal:
            return spacing.x
        }
    }

    private func twoDSlabThicknessMillimeters(for viewport: StackViewport) -> Double? {
        coordinator.twoDSlabThicknessMillimeters ?? twoDSliceSpacingMillimeters(for: viewport)
    }

    private func twoDLocationMillimeters(for viewport: StackViewport) -> Double? {
        guard let thickness = twoDSliceSpacingMillimeters(for: viewport),
              viewport.sliceCount > 0 else {
            return nil
        }
        return Double(viewport.sliceIndex) * thickness
    }

    private func twoDMetadataSample(for viewport: StackViewport) -> ClinicalViewportMetadataSample? {
        guard let dataset = coordinator.dataset else { return nil }
        let dimensions = dataset.dimensions
        let sliceIndex = min(max(viewport.sliceIndex, 0), max(viewport.sliceCount - 1, 0))
        let voxel: SIMD3<Int32>
        switch viewport.axis {
        case .axial:
            voxel = SIMD3<Int32>(
                Int32(max(dimensions.width - 1, 0) / 2),
                Int32(max(dimensions.height - 1, 0) / 2),
                Int32(sliceIndex)
            )
        case .coronal:
            voxel = SIMD3<Int32>(
                Int32(max(dimensions.width - 1, 0) / 2),
                Int32(sliceIndex),
                Int32(max(dimensions.depth - 1, 0) / 2)
            )
        case .sagittal:
            voxel = SIMD3<Int32>(
                Int32(sliceIndex),
                Int32(max(dimensions.height - 1, 0) / 2),
                Int32(max(dimensions.depth - 1, 0) / 2)
            )
        }

        guard let intensity = try? VolumePicking.sampleIntensity(in: dataset, atVoxelIndex: voxel) else {
            return nil
        }
        let worldPoint = VolumePicking.worldPoint(
            forVoxelIndex: SIMD3<Float>(Float(voxel.x), Float(voxel.y), Float(voxel.z)),
            in: dataset
        )
        let scalarSamples = (try? VolumePicking.sampleScalarVolumes(in: coordinator.volumeLayers,
                                                                    atBaseWorldPoint: worldPoint)) ?? []
        let doseSamples = coordinator.rtDoseOverlays.compactMap { overlay -> RTDoseSample? in
            guard overlay.volumeLayer.isVisible,
                  overlay.volumeLayer.clampedOpacity > 0 else {
                return nil
            }
            return try? overlay.sampleDose(atBaseWorldPoint: worldPoint)
        }
        return ClinicalViewportMetadataSample(intensity: intensity,
                                              scalarSamples: scalarSamples,
                                              doseSamples: doseSamples)
    }
}

public struct ClinicalViewportDebugOverlay: View {
    public let snapshot: ClinicalViewportDebugSnapshot

    public init(snapshot: ClinicalViewportDebugSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("id", value: String(describing: snapshot.viewportID))
            row("type", value: snapshot.viewportType)
            row("mode", value: snapshot.renderMode)
            row("dataset", value: snapshot.datasetHandle ?? "nil")
            row("volume", value: snapshot.volumeTextureLabel ?? "nil")
            row("output", value: snapshot.outputTextureLabel ?? "nil")
            row("pass", value: snapshot.lastPassExecuted ?? "none")
            row("present", value: snapshot.presentationStatus)
            if let lastError = snapshot.lastError {
                row("error", value: lastError)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.72))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func row(_ title: String, value: String) -> some View {
        Text("\(title): \(value)")
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

public struct ClinicalProfilingHUD: View {
    @ObservedObject private var coordinator: ClinicalViewerCoordinator

    public init(coordinator: ClinicalViewerCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("MPR HUD", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))

            row("Render", value: formatMilliseconds(coordinator.hudRenderTimeMilliseconds))
            row("Present", value: formatMilliseconds(coordinator.hudPresentationTimeMilliseconds))
            row("Upload", value: formatMilliseconds(coordinator.hudUploadTimeMilliseconds))
            row("GPU mem", value: formatBytes(coordinator.hudMemoryBytes))

            if let snapshotMetrics = coordinator.lastSnapshotMetrics {
                row("Snapshot", value: formatMilliseconds(snapshotMetrics.readbackMilliseconds))
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "waiting" }
        return String(format: "%.2f ms", value)
    }

    private func formatBytes(_ bytes: Int?) -> String {
        guard let bytes else { return "waiting" }
        let mib = Double(max(0, bytes)) / 1_048_576.0
        if mib >= 1024 {
            return String(format: "%.2f GiB", mib / 1024.0)
        }
        return String(format: "%.1f MiB", mib)
    }
}
#endif
