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
                    showsCompactChrome: false
                )
                .accessibilityIdentifier("MTKClinicalViewerGrid")
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
