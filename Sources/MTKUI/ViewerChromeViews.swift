#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI

public enum ViewerToolbarMenuPlacement: Sendable, Equatable {
    case above
    case below
}

public struct ViewerBottomToolbar: View {
    private let configuration: ViewerChromeConfiguration
    private let activeMenuToolID: ViewerToolID?
    private let onToolTap: (ViewerToolDescriptor) -> Void
    private let onToolLongPress: (ViewerToolDescriptor) -> Void
    private let onMenuItemTap: (ViewerToolMenuItem) -> Void
    private let trailingAccessory: AnyView?
    private let menuPlacement: ViewerToolbarMenuPlacement

    public init(configuration: ViewerChromeConfiguration,
                activeMenuToolID: ViewerToolID?,
                onToolTap: @escaping (ViewerToolDescriptor) -> Void,
                onToolLongPress: @escaping (ViewerToolDescriptor) -> Void,
                onMenuItemTap: @escaping (ViewerToolMenuItem) -> Void,
                trailingAccessory: AnyView? = nil,
                menuPlacement: ViewerToolbarMenuPlacement = .above) {
        self.configuration = configuration
        self.activeMenuToolID = activeMenuToolID
        self.onToolTap = onToolTap
        self.onToolLongPress = onToolLongPress
        self.onMenuItemTap = onMenuItemTap
        self.trailingAccessory = trailingAccessory
        self.menuPlacement = menuPlacement
    }

    public var body: some View {
        VStack(spacing: 8) {
            if menuPlacement == .above { activeMenuView }

            HStack(spacing: 14) {
                ForEach(configuration.bottomTools) { tool in
                    toolButton(tool)
                }
                if let trailingAccessory {
                    trailingAccessory
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.58), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }

            if menuPlacement == .below { activeMenuView }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(toolbarAccessibilityIdentifier)
    }

    @ViewBuilder
    private var activeMenuView: some View {
        if let activeMenu = activeMenu {
            ViewerFloatingToolMenu(toolID: activeMenu.toolID,
                                   menu: activeMenu.menu,
                                   onItemTap: onMenuItemTap)
                .transition(.move(edge: menuPlacement == .above ? .bottom : .top).combined(with: .opacity))
        }
    }

    private var toolbarAccessibilityIdentifier: String {
        switch configuration.mode {
        case .single3D:
            return "Volume3DBottomToolbar"
        case .clinical:
            return "MPRBottomToolbar"
        case .stack2D:
            return "MTKViewerBottomToolbar"
        }
    }

    private var activeMenu: (toolID: ViewerToolID, menu: ViewerToolMenu)? {
        guard let activeMenuToolID,
              let tool = configuration.bottomTools.first(where: { $0.id == activeMenuToolID }) else {
            return nil
        }
        guard let menu = tool.longPressMenu else { return nil }
        return (activeMenuToolID, menu)
    }

    private func toolButton(_ tool: ViewerToolDescriptor) -> some View {
        ViewerToolbarToolButton(tool: tool,
                                onTap: onToolTap,
                                onLongPress: onToolLongPress)
    }
}

public struct MPRBottomToolbar: View {
    private let configuration: ViewerChromeConfiguration
    private let activeMenuToolID: ViewerToolID?
    private let onToolTap: (ViewerToolDescriptor) -> Void
    private let onToolLongPress: (ViewerToolDescriptor) -> Void
    private let onMenuItemTap: (ViewerToolMenuItem) -> Void
    private let trailingAccessory: AnyView?
    private let menuPlacement: ViewerToolbarMenuPlacement

    public init(configuration: ViewerChromeConfiguration,
                activeMenuToolID: ViewerToolID?,
                onToolTap: @escaping (ViewerToolDescriptor) -> Void,
                onToolLongPress: @escaping (ViewerToolDescriptor) -> Void,
                onMenuItemTap: @escaping (ViewerToolMenuItem) -> Void,
                trailingAccessory: AnyView? = nil,
                menuPlacement: ViewerToolbarMenuPlacement = .above) {
        self.configuration = configuration
        self.activeMenuToolID = activeMenuToolID
        self.onToolTap = onToolTap
        self.onToolLongPress = onToolLongPress
        self.onMenuItemTap = onMenuItemTap
        self.trailingAccessory = trailingAccessory
        self.menuPlacement = menuPlacement
    }

    public var body: some View {
        ViewerBottomToolbar(configuration: configuration,
                            activeMenuToolID: activeMenuToolID,
                            onToolTap: onToolTap,
                            onToolLongPress: onToolLongPress,
                            onMenuItemTap: onMenuItemTap,
                            trailingAccessory: trailingAccessory,
                            menuPlacement: menuPlacement)
    }
}

private struct ViewerToolbarToolButton: View {
    let tool: ViewerToolDescriptor
    let onTap: (ViewerToolDescriptor) -> Void
    let onLongPress: (ViewerToolDescriptor) -> Void
    @State private var suppressTapAfterLongPress = false
    @State private var longPressSuppressionResetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !consumeLongPressTapSuppression() else {
                return
            }
            onTap(tool)
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tool.isSelected ? Color.accentColor : Color.white.opacity(0.9))
                .opacity(tool.isEnabled ? 1 : 0.42)
                .frame(width: 42, height: 38)
                .background {
                    Circle()
                        .fill(tool.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .overlay {
                    Circle()
                        .strokeBorder(tool.isSelected ? Color.accentColor.opacity(0.82) : Color.clear,
                                      lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!tool.isEnabled)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35, maximumDistance: 24)
                .onEnded { _ in
                    handleToolLongPress()
                }
        )
        .onDisappear {
            longPressSuppressionResetTask?.cancel()
            longPressSuppressionResetTask = nil
        }
        .accessibilityLabel(tool.title)
        .accessibilityValue(toolAccessibilityValue)
        .accessibilityIdentifier(tool.accessibilityIdentifier ?? "ViewerTool.\(tool.id.rawValue)")
        .accessibilityAddTraits(tool.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            guard tool.isEnabled else { return }
            onTap(tool)
        }
        .help(tool.disabledMessage ?? tool.title)
    }

    private func handleToolLongPress() {
        guard tool.isEnabled else { return }
        longPressSuppressionResetTask?.cancel()
        longPressSuppressionResetTask = nil
        suppressTapAfterLongPress = true
        onLongPress(tool)
        scheduleLongPressSuppressionResetIfNeeded(after: 2_000_000_000)
    }

    private func consumeLongPressTapSuppression() -> Bool {
        guard suppressTapAfterLongPress else { return false }
        suppressTapAfterLongPress = false
        longPressSuppressionResetTask?.cancel()
        longPressSuppressionResetTask = nil
        return true
    }

    private func scheduleLongPressSuppressionResetIfNeeded(after delay: UInt64) {
        guard suppressTapAfterLongPress else { return }
        longPressSuppressionResetTask?.cancel()
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            suppressTapAfterLongPress = false
            longPressSuppressionResetTask = nil
        }
        longPressSuppressionResetTask = task
    }

    private var toolAccessibilityValue: String {
        if !tool.isEnabled {
            if let disabledMessage = tool.disabledMessage, !disabledMessage.isEmpty {
                return "Unavailable: \(disabledMessage)"
            }
            return "Unavailable"
        }
        return tool.isSelected ? "Selected" : ""
    }
}

public struct ViewerOptionsButton: View {
    private let isPresented: Bool
    private let action: () -> Void

    public init(isPresented: Bool,
                action: @escaping () -> Void) {
        self.isPresented = isPresented
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: isPresented ? "slider.horizontal.3" : "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPresented ? "Hide options" : "Show options")
        .help(isPresented ? "Hide options" : "Show options")
    }
}

private struct ViewerFloatingToolMenu: View {
    let toolID: ViewerToolID
    let menu: ViewerToolMenu
    let onItemTap: (ViewerToolMenuItem) -> Void

    var body: some View {
        ViewerChromeMenu(accessibilityIdentifier: menu.accessibilityIdentifier ?? "ViewerToolMenu.\(toolID.rawValue)",
                         menu: menu,
                         onItemTap: onItemTap)
    }
}

public struct ViewerChromeMenu: View {
    private let accessibilityIdentifier: String
    private let menu: ViewerToolMenu
    private let onItemTap: (ViewerToolMenuItem) -> Void
    @State private var expandedSectionIDs: Set<String> = []

    public init(accessibilityIdentifier: String,
                menu: ViewerToolMenu,
                onItemTap: @escaping (ViewerToolMenuItem) -> Void) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.menu = menu
        self.onItemTap = onItemTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = menu.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }

            ForEach(Array(menu.entries.enumerated()), id: \.element.id) { index, entry in
                menuEntry(entry)

                if index < menu.entries.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.14))
                }
            }
        }
        .frame(minWidth: 190, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func menuEntry(_ entry: ViewerToolMenuEntry) -> some View {
        switch entry {
        case .item(let item):
            menuItemButton(item)
        case .section(let section):
            menuSection(section)
        }
    }

    private func menuItemButton(_ item: ViewerToolMenuItem) -> some View {
        Button {
            onItemTap(item)
        } label: {
            menuRow(title: item.title, systemImage: item.systemImage)
                .opacity(item.isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityLabel(item.title)
        .accessibilityValue(itemAccessibilityValue(item))
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    private func menuSection(_ section: ViewerToolMenuSection) -> some View {
        let isExpanded = expandedSectionIDs.contains(section.id)
        return VStack(alignment: .leading, spacing: 0) {
            menuRow(title: section.title,
                    systemImage: section.systemImage,
                    trailingSystemImage: isExpanded ? "chevron.down" : "chevron.right")
            .contentShape(Rectangle())
            .onTapGesture {
                toggleSection(section.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(section.title)
            .accessibilityIdentifier(section.accessibilityIdentifier)
            .accessibilityAction {
                toggleSection(section.id)
            }

            if isExpanded {
                sectionItems(section)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sectionItems(_ section: ViewerToolMenuSection) -> some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                menuItemButton(item)
                if index < section.items.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.1))
                        .padding(.leading, 14)
                }
            }
        }

        if let maximumVisibleItems = section.maximumVisibleItems,
           section.items.count > maximumVisibleItems {
            ScrollView(.vertical, showsIndicators: true) {
                content
            }
            .frame(maxHeight: CGFloat(max(maximumVisibleItems, 1)) * 42)
        } else {
            content
        }
    }

    private func menuRow(title: String,
                         systemImage: String?,
                         trailingSystemImage: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let systemImage = systemImage {
                Image(systemName: systemImage)
                    .frame(width: 18)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 10)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toggleSection(_ id: String) {
        var nextExpandedSectionIDs = expandedSectionIDs
        if nextExpandedSectionIDs.contains(id) {
            nextExpandedSectionIDs.remove(id)
        } else {
            nextExpandedSectionIDs.insert(id)
        }
        expandedSectionIDs = nextExpandedSectionIDs
    }

    private func itemAccessibilityValue(_ item: ViewerToolMenuItem) -> String {
        if !item.isEnabled {
            return "Unavailable"
        }
        return item.isSelected ? "Selected" : ""
    }
}
#endif
