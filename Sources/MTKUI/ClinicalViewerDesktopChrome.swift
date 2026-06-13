//
//  ClinicalViewerDesktopChrome.swift
//  MTKUI
//
//  Desktop-native viewer chrome (issue #1212): persistent top toolbar
//  rendering ViewerCommandDescriptors with hover/help affordances, the
//  content surface, and a trailing inspector built from titled sections.
//  Pure multiplatform SwiftUI — no UIKit-only assumptions — so the same
//  composition also works on iPadOS when desktop idioms are preferred.
//  Menu integration: hosts bridge the same descriptors into their app-level
//  `.commands` menus via `ViewerCommandDescriptor.keyboardShortcut`.
//

import SwiftUI

/// Metrics for the desktop chrome. Exposed for tests.
public enum DesktopChromeMetrics {
    public static let inspectorWidth: CGFloat = 300
    public static let toolbarHeight: CGFloat = 44
}

/// A titled inspector region (tools, presets, MPR layout, annotations,
/// metadata, export…). Sections collapse independently.
public struct ViewerInspectorSection<SectionContent: View>: View {
    private let title: String
    private let content: SectionContent
    @State private var isExpanded = true

    public init(_ title: String, @ViewBuilder content: () -> SectionContent) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("ViewerInspectorSection.\(title)")
    }
}

/// Scrollable trailing inspector panel for desktop viewer composition.
public struct ViewerInspectorPanel<PanelContent: View>: View {
    private let content: PanelContent

    public init(@ViewBuilder content: () -> PanelContent) {
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: DesktopChromeMetrics.inspectorWidth)
        .background(.thinMaterial)
        .accessibilityIdentifier("ViewerInspectorPanel")
    }
}

/// Top command strip rendering viewer commands with hover/help affordances.
public struct ViewerDesktopToolbar: View {
    private let commands: [ViewerCommandDescriptor]
    private let activeMode: ClinicalViewerMode
    private let onCommand: (ViewerCommandID) -> Void

    public init(
        commands: [ViewerCommandDescriptor] = ViewerCommandDescriptor.defaultViewerCommands,
        activeMode: ClinicalViewerMode,
        onCommand: @escaping (ViewerCommandID) -> Void
    ) {
        self.commands = commands
        self.activeMode = activeMode
        self.onCommand = onCommand
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(commands) { command in
                ViewerToolbarButton(
                    command: command,
                    isActive: command.targetMode == activeMode,
                    action: { onCommand(command.id) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: DesktopChromeMetrics.toolbarHeight)
        .background(.thinMaterial)
        .accessibilityIdentifier("ViewerDesktopToolbar")
    }

    /// Test seam: exposes the dispatch callback without UI hit-testing.
    var onCommandForTesting: (ViewerCommandID) -> Void { onCommand }
}

/// Toolbar button with hover highlight and tooltip help.
struct ViewerToolbarButton: View {
    let command: ViewerCommandDescriptor
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(command.title, systemImage: command.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(command.title)
        .accessibilityIdentifier(command.accessibilityIdentifier)
        .accessibilityLabel(command.title)
    }

    private var backgroundColor: Color {
        if isActive { return Color.accentColor.opacity(0.30) }
        if isHovering { return Color.primary.opacity(0.10) }
        return .clear
    }
}

/// Desktop viewer chrome: toolbar on top, content center, trailing
/// inspector toggleable from the toolbar area.
///
/// ```swift
/// ClinicalViewerDesktopChrome(
///     mode: coordinator.mode,
///     onCommand: { handle($0) },
///     content: { ClinicalViewerSurface(coordinator: coordinator) },
///     inspector: {
///         ViewerInspectorSection("Window/Level") { MyWWLControls() }
///         ViewerInspectorSection("Export") { MyExportControls() }
///     }
/// )
/// ```
public struct ClinicalViewerDesktopChrome<Content: View, Inspector: View>: View {
    private let commands: [ViewerCommandDescriptor]
    private let mode: ClinicalViewerMode
    private let onCommand: (ViewerCommandID) -> Void
    private let content: Content
    private let inspector: Inspector

    @State private var isInspectorVisible: Bool

    public init(
        commands: [ViewerCommandDescriptor] = ViewerCommandDescriptor.defaultViewerCommands,
        mode: ClinicalViewerMode,
        initiallyShowsInspector: Bool = true,
        onCommand: @escaping (ViewerCommandID) -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self.commands = commands
        self.mode = mode
        self.onCommand = onCommand
        self.content = content()
        self.inspector = inspector()
        _isInspectorVisible = State(initialValue: initiallyShowsInspector)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ViewerDesktopToolbar(commands: commands, activeMode: mode, onCommand: onCommand)
                inspectorToggle
                    .padding(.trailing, 10)
                    .background(.thinMaterial)
            }
            Divider()
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isInspectorVisible {
                    Divider()
                    ViewerInspectorPanel { inspector }
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .environment(\.viewerLayoutClassOverride, .desktop)
        .animation(.easeInOut(duration: 0.2), value: isInspectorVisible)
        .accessibilityIdentifier("ClinicalViewerDesktopChrome")
    }

    private var inspectorToggle: some View {
        Button {
            isInspectorVisible.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isInspectorVisible ? "Hide Inspector" : "Show Inspector")
        .accessibilityIdentifier("ClinicalViewerDesktopChrome.inspectorToggle")
        .accessibilityLabel(isInspectorVisible ? "Hide inspector" : "Show inspector")
    }
}

// MARK: - Previews (no DICOM data required)

#if DEBUG
#Preview("Desktop chrome") {
    ClinicalViewerDesktopChrome(
        mode: .clinical,
        onCommand: { _ in },
        content: { LinearGradient(colors: [.black, .gray], startPoint: .top, endPoint: .bottom) },
        inspector: {
            ViewerInspectorSection("Window/Level") { Text("Controls") }
            ViewerInspectorSection("MPR Layout") { Text("Layout picker") }
            ViewerInspectorSection("Export") { Text("Export buttons") }
        }
    )
    .frame(width: 1280, height: 800)
}
#endif
