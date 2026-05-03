//  SnapshotExportControlView.swift
//  MTKUI
//  Simple, reusable snapshot export control for SwiftUI.
//
//  This view intentionally does not present a file exporter UI.
//  Downstream apps decide whether to use ShareLink, fileExporter, or custom persistence.
//
//  Thales Matheus Mendonça Santos — April 2026

#if canImport(SwiftUI)
import SwiftUI

/// A small SwiftUI control for triggering a snapshot export action.
///
/// `SnapshotExportControlView` is a reusable button-style control that triggers an async snapshot
/// capture/export action provided by the downstream app.
///
/// This view **does not** perform snapshot capture on its own and does not require `MTKCore`.
/// The caller supplies the action (typically calling into `VolumeViewportController` to request
/// a `VolumeRenderFrame` snapshot via `TextureSnapshotExporter`, then presenting export UI).
///
/// - Important: This control is UI-only; it intentionally avoids coupling MTKUI to any particular
///   export flow (file exporter vs share sheet vs custom storage).
public struct SnapshotExportControlView: View {
    private let title: String
    private let systemImage: String
    private let style: any VolumetricUIStyle
    private let isEnabled: Bool
    private let isInProgress: Bool
    private let action: () async -> Void

    /// Creates a snapshot export control.
    ///
    /// - Parameters:
    ///   - title: Button label text. Defaults to "Export PNG".
    ///   - systemImage: SF Symbol name. Defaults to "square.and.arrow.up".
    ///   - style: Visual style configuration. Defaults to ``DefaultVolumetricUIStyle``.
    ///   - isEnabled: Whether the button is enabled. Defaults to `true`.
    ///   - isInProgress: Shows a small progress indicator when `true`. Defaults to `false`.
    ///   - action: Async action invoked when the user taps the control.
    public init(
        title: String = "Export PNG",
        systemImage: String = "square.and.arrow.up",
        style: any VolumetricUIStyle = DefaultVolumetricUIStyle(),
        isEnabled: Bool = true,
        isInProgress: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isEnabled = isEnabled
        self.isInProgress = isInProgress
        self.action = action
    }

    @available(*, deprecated, message: "use init(title:systemImage:style:isEnabled:isInProgress:action:)")
    public init(
        actionLabel: String,
        onExport: @escaping () async -> Void,
        errorMessage: String? = nil
    ) {
        _ = errorMessage
        self.init(title: actionLabel,
                  systemImage: "square.and.arrow.up",
                  style: DefaultVolumetricUIStyle(),
                  isEnabled: true,
                  isInProgress: false,
                  action: onExport)
    }

    @available(*, deprecated, message: "use init(title:systemImage:style:isEnabled:isInProgress:action:)")
    public init(
        isEnabled: Bool = true,
        isInProgress: Bool = false,
        errorMessage: String?,
        actionLabel: String,
        systemImage: String = "square.and.arrow.up",
        onExport: @escaping () async -> Void
    ) {
        _ = errorMessage
        self.init(title: actionLabel,
                  systemImage: systemImage,
                  style: DefaultVolumetricUIStyle(),
                  isEnabled: isEnabled,
                  isInProgress: isInProgress,
                  action: onExport)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snapshot")
                .font(.headline)

            Button {
                Task { await action() }
            } label: {
                Label(title, systemImage: systemImage)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .disabled(!isEnabled || isInProgress)

            if isInProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(style.overlayBackground.cornerRadius(8))
        .foregroundStyle(style.overlayForeground)
        .accessibilityIdentifier("VolumetricSnapshotControls")
    }
}
#endif
