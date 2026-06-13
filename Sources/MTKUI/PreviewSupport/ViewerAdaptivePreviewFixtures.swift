//
//  ViewerAdaptivePreviewFixtures.swift
//  MTKUI
//
//  Shared preview/regression fixtures for adaptive viewer UI
//  (issue #1215). The representative window sizes are used both by SwiftUI
//  previews and by the regression tests, so the preview matrix and the
//  tested matrix can never drift apart. The mock content needs no DICOM
//  data or GPU.
//

import SwiftUI

/// Representative window dimensions for adaptive-UI previews and tests.
public enum ViewerPreviewWindows {
    /// iPhone portrait.
    public static let compactPhone = CGSize(width: 390, height: 844)
    /// iPad full-screen landscape.
    public static let iPadFullLandscape = CGSize(width: 1180, height: 820)
    /// iPad split view / narrow Stage Manager window.
    public static let iPadSplitNarrow = CGSize(width: 600, height: 820)
    /// macOS desktop window.
    public static let macDesktop = CGSize(width: 1280, height: 800)

    /// The full preview matrix with the layout class each window resolves
    /// to (size-class hints included where a real environment would
    /// provide them).
    public static let matrix: [(name: String, size: CGSize, context: ViewerLayoutContext, expected: ViewerLayoutClass)] = [
        (
            "compactPhone", compactPhone,
            ViewerLayoutContext(
                size: compactPhone,
                horizontalSizeClassIsCompact: true,
                verticalSizeClassIsCompact: false,
                prefersDesktopIdioms: false
            ),
            .compactPhone
        ),
        (
            "iPadFullLandscape", iPadFullLandscape,
            ViewerLayoutContext(
                size: iPadFullLandscape,
                horizontalSizeClassIsCompact: false,
                verticalSizeClassIsCompact: false,
                prefersDesktopIdioms: false
            ),
            .tablet
        ),
        (
            "iPadSplitNarrow", iPadSplitNarrow,
            ViewerLayoutContext(
                size: iPadSplitNarrow,
                horizontalSizeClassIsCompact: false,
                verticalSizeClassIsCompact: false,
                prefersDesktopIdioms: false
            ),
            .compactTablet
        ),
        (
            "macDesktop", macDesktop,
            ViewerLayoutContext(size: macDesktop, prefersDesktopIdioms: true),
            .desktop
        )
    ]
}

/// GPU-free stand-in for a diagnostic viewport in previews.
public struct ViewerPreviewViewportPlaceholder: View {
    private let label: String

    public init(label: String = "Viewport") {
        self.label = label
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(white: 0.25)], startPoint: .top, endPoint: .bottom)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Mock dock/inspector controls for chrome previews.
public struct ViewerPreviewDockControls: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tools").font(.headline)
            ForEach(["Window/Level", "Slab Thickness", "MPR Layout", "Annotations", "Export"], id: \.self) { tool in
                Label(tool, systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: TabletChromeMetrics.controlHitTarget)
            }
        }
    }
}

// MARK: - Preview matrix

#if DEBUG
#Preview("Compact phone (390×844)") {
    ClinicalViewerTabletChrome(
        title: "CT Chest",
        mode: .stack2D,
        onSelectMode: { _ in },
        content: { ViewerPreviewViewportPlaceholder() },
        dock: { ViewerPreviewDockControls() }
    )
    .viewerLayoutClass(.compactPhone)
    .frame(width: ViewerPreviewWindows.compactPhone.width,
           height: ViewerPreviewWindows.compactPhone.height)
}

#Preview("iPad full landscape (1180×820)") {
    ClinicalViewerTabletChrome(
        title: "CT Chest",
        mode: .clinical,
        onSelectMode: { _ in },
        content: { ViewerPreviewViewportPlaceholder(label: "MPR Grid") },
        dock: { ViewerPreviewDockControls() }
    )
    .viewerLayoutClass(.tablet)
    .frame(width: ViewerPreviewWindows.iPadFullLandscape.width,
           height: ViewerPreviewWindows.iPadFullLandscape.height)
}

#Preview("iPad split / Stage Manager (600×820)") {
    ClinicalViewerTabletChrome(
        title: "CT Chest",
        mode: .clinical,
        onSelectMode: { _ in },
        content: { ViewerPreviewViewportPlaceholder(label: "MPR Grid") },
        dock: { ViewerPreviewDockControls() }
    )
    .viewerLayoutClass(.compactTablet)
    .frame(width: ViewerPreviewWindows.iPadSplitNarrow.width,
           height: ViewerPreviewWindows.iPadSplitNarrow.height)
}

#Preview("macOS desktop (1280×800)") {
    ClinicalViewerDesktopChrome(
        mode: .clinical,
        onCommand: { _ in },
        content: { ViewerPreviewViewportPlaceholder(label: "MPR Grid") },
        inspector: {
            ViewerInspectorSection("Window/Level") { Text("Controls") }
            ViewerInspectorSection("MPR Layout") { Text("Layout picker") }
            ViewerInspectorSection("Export") { Text("Export buttons") }
        }
    )
    .frame(width: ViewerPreviewWindows.macDesktop.width,
           height: ViewerPreviewWindows.macDesktop.height)
}
#endif
