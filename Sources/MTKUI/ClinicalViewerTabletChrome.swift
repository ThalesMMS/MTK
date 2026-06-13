//
//  ClinicalViewerTabletChrome.swift
//  MTKUI
//
//  Reusable large-screen viewer chrome (issue #1211): wraps a clinical
//  viewer surface/grid with a header strip (title, mode menu, dock toggle)
//  and an adaptive control dock — a trailing side dock on tablet/desktop
//  windows, a bottom dock on narrow windows — without depending on any
//  demo-shell view models. The dock content (tools, presets, annotations,
//  window/level, slab, export controls) is supplied by the host app.
//

import SwiftUI

/// How the control dock is presented for a resolved layout class.
public enum TabletChromeDockPresentation: String, Sendable, Equatable {
    /// Trailing side dock/inspector (tablet and desktop windows).
    case sideDock
    /// Bottom dock strip (compact phone and narrow windows).
    case bottomDock

    /// The presentation for a layout class. Pure and testable.
    public static func presentation(for layoutClass: ViewerLayoutClass) -> TabletChromeDockPresentation {
        switch layoutClass {
        case .tablet, .desktop:
            return .sideDock
        case .compactPhone, .compactTablet:
            return .bottomDock
        }
    }
}

/// Layout metrics for the tablet chrome. Exposed for tests.
public enum TabletChromeMetrics {
    public static let sideDockWidth: CGFloat = 320
    public static let bottomDockMaxHeight: CGFloat = 260
    /// Minimum touch-friendly hit target.
    public static let controlHitTarget: CGFloat = 44
}

/// Large-touch-screen viewer chrome wrapping `ClinicalViewerSurface` /
/// `ClinicalViewportGrid` content.
///
/// ```swift
/// ClinicalViewerTabletChrome(
///     title: "CT Chest",
///     mode: coordinator.mode,
///     onSelectMode: { coordinator.mode = $0 },
///     content: { ClinicalViewerSurface(coordinator: coordinator) },
///     dock: { MyToolControls() }
/// )
/// ```
public struct ClinicalViewerTabletChrome<Content: View, Dock: View>: View {
    private let title: String
    private let mode: ClinicalViewerMode
    private let onSelectMode: (ClinicalViewerMode) -> Void
    private let content: Content
    private let dock: Dock

    @State private var isDockVisible: Bool
    @Environment(\.viewerLayoutClassOverride) private var layoutClassOverride
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif

    public init(
        title: String,
        mode: ClinicalViewerMode,
        onSelectMode: @escaping (ClinicalViewerMode) -> Void,
        initiallyShowsDock: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder dock: () -> Dock
    ) {
        self.title = title
        self.mode = mode
        self.onSelectMode = onSelectMode
        self.content = content()
        self.dock = dock()
        _isDockVisible = State(initialValue: initiallyShowsDock)
    }

    public var body: some View {
        GeometryReader { proxy in
            let layoutClass = resolvedLayoutClass(for: proxy.size)
            let presentation = TabletChromeDockPresentation.presentation(for: layoutClass)

            VStack(spacing: 0) {
                header(layoutClass: layoutClass)

                switch presentation {
                case .sideDock:
                    HStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if isDockVisible {
                            Divider()
                            dockPanel(width: TabletChromeMetrics.sideDockWidth)
                                .transition(.move(edge: .trailing))
                        }
                    }
                case .bottomDock:
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if isDockVisible {
                        Divider()
                        dockPanel(maxHeight: min(
                            TabletChromeMetrics.bottomDockMaxHeight,
                            proxy.size.height * 0.4
                        ))
                        .transition(.move(edge: .bottom))
                    }
                }
            }
            .environment(\.viewerLayoutClassOverride, layoutClass)
            .animation(.easeInOut(duration: 0.2), value: isDockVisible)
        }
        .accessibilityIdentifier("ClinicalViewerTabletChrome")
    }

    // MARK: - Pieces

    private func header(layoutClass: ViewerLayoutClass) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 8)

            ClinicalViewportModeMenu(currentMode: mode, onSelect: onSelectMode)

            Button {
                isDockVisible.toggle()
            } label: {
                Image(systemName: isDockVisible ? "sidebar.trailing" : "slider.horizontal.3")
                    .frame(
                        width: TabletChromeMetrics.controlHitTarget,
                        height: TabletChromeMetrics.controlHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .viewerHoverHighlight()
            .accessibilityIdentifier("ClinicalViewerTabletChrome.dockToggle")
            .accessibilityLabel(isDockVisible ? "Hide controls" : "Show controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func dockPanel(width: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        ScrollView(width != nil ? .vertical : .horizontal, showsIndicators: false) {
            dock
                .padding(12)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(.thinMaterial)
        .accessibilityIdentifier("ClinicalViewerTabletChrome.dock")
    }

    private func resolvedLayoutClass(for size: CGSize) -> ViewerLayoutClass {
        if let layoutClassOverride {
            return layoutClassOverride
        }
#if os(iOS)
        let context = ViewerLayoutContext(
            size: size,
            horizontalSizeClassIsCompact: horizontalSizeClass.map { $0 == .compact },
            verticalSizeClassIsCompact: verticalSizeClass.map { $0 == .compact }
        )
#else
        let context = ViewerLayoutContext(size: size)
#endif
        return ViewerLayoutClassResolver.resolve(context)
    }
}

// MARK: - Previews (no DICOM data required)

#if DEBUG
private struct TabletChromePreviewDock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tools").font(.headline)
            ForEach(["Window/Level", "Slab Thickness", "Annotations", "Export"], id: \.self) { tool in
                Label(tool, systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: TabletChromeMetrics.controlHitTarget)
            }
        }
    }
}

#Preview("Tablet — side dock") {
    ClinicalViewerTabletChrome(
        title: "CT Chest",
        mode: .clinical,
        onSelectMode: { _ in },
        content: { LinearGradient(colors: [.black, .gray], startPoint: .top, endPoint: .bottom) },
        dock: { TabletChromePreviewDock() }
    )
    .viewerLayoutClass(.tablet)
    .frame(width: 1024, height: 768)
}

#Preview("Narrow split — bottom dock") {
    ClinicalViewerTabletChrome(
        title: "CT Chest",
        mode: .stack2D,
        onSelectMode: { _ in },
        content: { LinearGradient(colors: [.black, .gray], startPoint: .top, endPoint: .bottom) },
        dock: { TabletChromePreviewDock() }
    )
    .viewerLayoutClass(.compactTablet)
    .frame(width: 600, height: 800)
}
#endif
