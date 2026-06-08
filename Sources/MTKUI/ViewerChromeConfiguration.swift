import Foundation
import MTKCore

public enum ViewerToolID: String, CaseIterable, Identifiable, Sendable {
    case orientation
    case windowLevel
    case rotation
    case crop
    case brush
    case scroll
    case roi
    case thickSlab
    case sync
    case reslice

    public var id: String { rawValue }
}

public enum Volume3DTool: String, CaseIterable, Identifiable, Sendable {
    case orientation
    case windowLevel
    case rotation
    case crop
    case brush

    public var id: String { rawValue }

    public var viewerToolID: ViewerToolID {
        switch self {
        case .orientation:
            return .orientation
        case .windowLevel:
            return .windowLevel
        case .rotation:
            return .rotation
        case .crop:
            return .crop
        case .brush:
            return .brush
        }
    }

    public var accessibilityIdentifier: String {
        "Volume3DTool.\(rawValue)"
    }
}

public enum MPRToolbarTool: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case windowLevel
    case rotation
    case roi
    case thickSlab

    public var id: String { rawValue }

    public init?(viewerToolID: ViewerToolID) {
        switch viewerToolID {
        case .scroll:
            self = .scroll
        case .windowLevel:
            self = .windowLevel
        case .rotation:
            self = .rotation
        case .roi:
            self = .roi
        case .thickSlab:
            self = .thickSlab
        default:
            return nil
        }
    }

    public var viewerToolID: ViewerToolID {
        switch self {
        case .scroll:
            return .scroll
        case .windowLevel:
            return .windowLevel
        case .rotation:
            return .rotation
        case .roi:
            return .roi
        case .thickSlab:
            return .thickSlab
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .scroll:
            return "MPRToolScroll"
        case .windowLevel:
            return "MPRToolWindowLevel"
        case .rotation:
            return "MPRToolRotation"
        case .roi:
            return "MPRToolROI"
        case .thickSlab:
            return "MPRToolThickSlab"
        }
    }

    public var clinicalInteractionTool: ClinicalMPRInteractionTool? {
        switch self {
        case .scroll:
            return .slice
        case .windowLevel:
            return .windowLevel
        case .rotation:
            return .rotation
        case .roi:
            return .roi
        case .thickSlab:
            return nil
        }
    }
}

public typealias MPRTool = MPRToolbarTool

public extension Clinical2DTool {
    init?(viewerToolID: ViewerToolID) {
        switch viewerToolID {
        case .scroll:
            self = .scroll
        case .windowLevel:
            self = .windowLevel
        case .rotation:
            self = .rotation
        case .roi:
            self = .roi
        case .sync:
            self = .sync
        case .reslice:
            self = .reslice
        case .thickSlab:
            self = .thickSlab
        default:
            return nil
        }
    }

    var viewerToolID: ViewerToolID {
        switch self {
        case .scroll:
            return .scroll
        case .windowLevel:
            return .windowLevel
        case .rotation:
            return .rotation
        case .roi:
            return .roi
        case .sync:
            return .sync
        case .reslice:
            return .reslice
        case .thickSlab:
            return .thickSlab
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .scroll:
            return "MTK2DToolScroll"
        case .windowLevel:
            return "MTK2DToolWindowLevel"
        case .rotation:
            return "MTK2DToolRotation"
        case .roi:
            return "MTK2DToolROI"
        case .sync:
            return "MTK2DToolSync"
        case .reslice:
            return "MTK2DToolReslice"
        case .thickSlab:
            return "MTK2DToolThickSlab"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll:
            return "square.stack.3d.down.forward"
        case .windowLevel:
            return "sun.max"
        case .rotation:
            return "crop.rotate"
        case .roi:
            return "ruler"
        case .sync:
            return "link"
        case .reslice:
            return "brain.head.profile"
        case .thickSlab:
            return "square.3.layers.3d"
        }
    }
}

public enum MPRWindowPreset: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case abdomen
    case bone
    case brain
    case lungs
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default:
            return "Default"
        case .abdomen:
            return "Abdomen"
        case .bone:
            return "Bone"
        case .brain:
            return "Brain"
        case .lungs:
            return "Lungs"
        case .other:
            return "Other"
        }
    }

    public var quickPreset: ClinicalViewerWindowQuickPreset? {
        switch self {
        case .abdomen:
            return .abdomen
        case .bone:
            return .bone
        case .brain:
            return .brain
        case .lungs:
            return .lung
        case .default, .other:
            return nil
        }
    }
}

public enum ViewerChromeOverlayID: String, Sendable {
    case crop3D
    case brush3D
}

public enum ViewerOptionsMenuID: String, Sendable {
    case volume3DOptions
    case mprOptions
    case stack2DOptions
}

public enum ViewerSettingsSheetID: String, Sendable {
    case volumeRenderSettings
    case mprSettings
    case mprWindowLevelManual
    case mprThickSlab
    case stack2DSettings
    case stack2DWindowLevelManual
    case stack2DThickSlab
}

public enum ViewerToolAction: Equatable, Sendable {
    case selectTool(ViewerToolID)
    case activateOverlay(ViewerChromeOverlayID)
    case set3DOrientation(Volume3DAnatomicalOrientation)
    case reset3DOrientation
    case set3DWindowPreset(Volume3DWindowPreset)
    case set3DCLUTPreset(Volume3DCLUTPreset)
    case set3DRotationTarget(Volume3DRotationTarget)
    case reset3DRotation
    case reset3DCropClip
    case set3DBrushMode(VolumeBrushMode)
    case adjust3DBrushSize(Double)
    case reset3DBrushVolume
    case toggle3DImageAnnotations
    case share3DSnapshot
    case setMPRScreenLayout(MPRScreenLayout)
    case toggleMPRAnnotations
    case toggleMPRCrosshair
    case resetActiveMPRView
    case resetMPRViews
    case shareMPRSnapshot
    case setMPRWindowPreset(MPRWindowPreset)
    case setMPRCLUTPreset(Volume3DCLUTPreset)
    case toggleMPRWindowInvert
    case setMPRROIKind(ViewerROIKind)
    case deleteMPRROIsInView
    case deleteAllMPRROIs
    case set2DScrollSpeed(Double)
    case set2DImageSortMode(TwoDImageSortMode)
    case set2DLoopThroughImages(Bool)
    case set2DOnScreenControls(Bool)
    case set2DWindowPreset(Volume3DWindowPreset)
    case set2DCLUTPreset(Clinical2DCLUT)
    case toggle2DWindowInvert
    case rotate2DByDegrees(Double)
    case flip2DHorizontal
    case flip2DVertical
    case reset2DTransform
    case set2DROIKind(ViewerROIKind)
    case delete2DROIsInView
    case deleteAll2DROIs
    case set2DSyncEnabled(Bool)
    case set2DSyncOption(ViewerSyncOption, Bool)
    case set2DResliceAxis(MTKCore.Axis)
    case set2DScreenLayout(TwoDScreenLayout)
    case toggle2DImageAnnotations
    case toggle2DReferenceLines
    case add2DBookmark
    case show2DBookmarks
    case toggle2DBookmarksPanel
    case deleteAll2DBookmarks
    case show2DMetadata
    case share2DCurrentImage
    case openSettings(ViewerSettingsSheetID)
    case none
}

public enum ViewerOptionsAction: Equatable, Sendable {
    case openSettings(ViewerSettingsSheetID)
    case openMenu(ViewerOptionsMenuID)
    case none
}

public struct ViewerToolMenuItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let action: ViewerToolAction
    public let isEnabled: Bool
    public let isSelected: Bool

    public init(id: String,
                title: String,
                systemImage: String? = nil,
                action: ViewerToolAction,
                isEnabled: Bool = true,
                isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }

    public var accessibilityIdentifier: String {
        "ViewerToolMenuItem.\(id)"
    }
}

public struct ViewerToolMenu: Equatable, Sendable {
    public let title: String?
    public let entries: [ViewerToolMenuEntry]
    public let accessibilityIdentifier: String?

    public init(title: String? = nil,
                items: [ViewerToolMenuItem],
                accessibilityIdentifier: String? = nil) {
        self.title = title
        self.entries = items.map(ViewerToolMenuEntry.item)
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public init(title: String? = nil,
                entries: [ViewerToolMenuEntry],
                accessibilityIdentifier: String? = nil) {
        self.title = title
        self.entries = entries
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var items: [ViewerToolMenuItem] {
        entries.compactMap { entry in
            if case .item(let item) = entry {
                return item
            }
            return nil
        }
    }

    public var sections: [ViewerToolMenuSection] {
        entries.compactMap { entry in
            if case .section(let section) = entry {
                return section
            }
            return nil
        }
    }
}

public enum ViewerToolMenuEntry: Identifiable, Equatable, Sendable {
    case item(ViewerToolMenuItem)
    case section(ViewerToolMenuSection)

    public var id: String {
        switch self {
        case .item(let item):
            return item.id
        case .section(let section):
            return section.id
        }
    }
}

public struct ViewerToolMenuSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let maximumVisibleItems: Int?
    public let items: [ViewerToolMenuItem]
    private let explicitAccessibilityIdentifier: String?

    public init(id: String,
                title: String,
                systemImage: String? = nil,
                maximumVisibleItems: Int? = nil,
                accessibilityIdentifier: String? = nil,
                items: [ViewerToolMenuItem]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.maximumVisibleItems = maximumVisibleItems
        self.explicitAccessibilityIdentifier = accessibilityIdentifier
        self.items = items
    }

    public var accessibilityIdentifier: String {
        explicitAccessibilityIdentifier ?? "ViewerToolMenuSection.\(id)"
    }
}

public struct ViewerToolDescriptor: Identifiable, Equatable, Sendable {
    public let id: ViewerToolID
    public let icon: String
    public let title: String
    public let accessibilityIdentifier: String?
    public let isSelected: Bool
    public let isEnabled: Bool
    public let disabledMessage: String?
    public let tapAction: ViewerToolAction
    public let longPressMenu: ViewerToolMenu?

    public init(id: ViewerToolID,
                icon: String,
                title: String,
                accessibilityIdentifier: String? = nil,
                isSelected: Bool = false,
                isEnabled: Bool = true,
                disabledMessage: String? = nil,
                tapAction: ViewerToolAction,
                longPressMenu: ViewerToolMenu? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.disabledMessage = disabledMessage
        self.tapAction = tapAction
        self.longPressMenu = longPressMenu
    }
}

public struct ViewerChromeConfiguration: Equatable, Sendable {
    public let mode: ClinicalViewerMode
    public let bottomTools: [ViewerToolDescriptor]
    public let optionsAction: ViewerOptionsAction
    public let optionsMenu: ViewerToolMenu?

    public init(mode: ClinicalViewerMode,
                bottomTools: [ViewerToolDescriptor],
                optionsAction: ViewerOptionsAction,
                optionsMenu: ViewerToolMenu? = nil) {
        self.mode = mode
        self.bottomTools = bottomTools
        self.optionsAction = optionsAction
        self.optionsMenu = optionsMenu
    }

    public var defaultToolID: ViewerToolID? {
        bottomTools.first { $0.isSelected && $0.isEnabled }?.id
            ?? bottomTools.first(where: \.isEnabled)?.id
            ?? bottomTools.first?.id
    }
}

public struct ViewerChromeConfigurationFactory: Sendable {
    public init() {}

    public func configuration(for mode: ClinicalViewerMode,
                              selectedToolID: ViewerToolID? = nil,
                              selected3DWindowPreset: Volume3DWindowPreset = .default,
                              selected3DCLUTPreset: Volume3DCLUTPreset = .defaultPreset,
                              selected3DRotationTarget: Volume3DRotationTarget = .model,
                              volumeBrushState: VolumeBrushState = VolumeBrushState(),
                              isVolume3DImageAnnotationsVisible: Bool = true,
                              isVolume3DShareEnabled: Bool = false,
                              selectedMPRScreenLayout: MPRScreenLayout = .defaultLayout,
                              selectedMPRWindowPreset: MPRWindowPreset = .default,
                              selectedMPRCLUTPreset: Volume3DCLUTPreset = .defaultPreset,
                              isMPRWindowInverted: Bool = false,
                              selectedMPRROIKind: ViewerROIKind = .distance,
                              isMPRAnnotationsVisible: Bool = true,
                              isMPRCrosshairVisible: Bool = true,
                              isMPRShareEnabled: Bool = false,
                              selectedTwoDWindowPreset: Volume3DWindowPreset = .default,
                              selectedTwoDCLUTPreset: Clinical2DCLUT = .grayscale,
                              isTwoDWindowInverted: Bool = false,
                              selectedTwoDROIKind: ViewerROIKind = .distance,
                              isTwoDSyncEnabled: Bool = false,
                              twoDSyncState: ViewerSyncState? = nil,
                              isTwoDLocationSyncEnabled: Bool = false,
                              twoDScrollSettings: TwoDScrollSettings = .default,
                              selectedTwoDScreenLayout: TwoDScreenLayout = .singleWindow,
                              enabledTwoDScreenLayouts: Set<TwoDScreenLayout> = [.singleWindow],
                              isTwoDImageAnnotationsVisible: Bool = true,
                              isTwoDReferenceLinesVisible: Bool = false,
                              isTwoDReferenceLinesEnabled: Bool = false,
                              isTwoDBookmarksPanelVisible: Bool = false,
                              canDeleteAllTwoDBookmarks: Bool = false,
                              selectedTwoDResliceAxis: MTKCore.Axis = .axial,
                              isTwoDResliceEnabled: Bool = true,
                              twoDResliceDisabledMessage: String? = nil,
                              isTwoDThickSlabEnabled: Bool = true,
                              twoDThickSlabDisabledMessage: String? = nil) -> ViewerChromeConfiguration {
        switch mode {
        case .single3D:
            return single3DConfiguration(selectedToolID: selectedToolID,
                                         selectedWindowPreset: selected3DWindowPreset,
                                         selectedCLUTPreset: selected3DCLUTPreset,
                                         selectedRotationTarget: selected3DRotationTarget,
                                         volumeBrushState: volumeBrushState,
                                         isImageAnnotationsVisible: isVolume3DImageAnnotationsVisible,
                                         isShareEnabled: isVolume3DShareEnabled)
        case .clinical:
            return mprConfiguration(selectedToolID: selectedToolID,
                                    selectedScreenLayout: selectedMPRScreenLayout,
                                    selectedWindowPreset: selectedMPRWindowPreset,
                                    selectedCLUTPreset: selectedMPRCLUTPreset,
                                    isWindowInverted: isMPRWindowInverted,
                                    selectedROIKind: selectedMPRROIKind,
                                    isAnnotationsVisible: isMPRAnnotationsVisible,
                                    isCrosshairVisible: isMPRCrosshairVisible,
                                    isShareEnabled: isMPRShareEnabled)
        case .stack2D:
            return stack2DConfiguration(selectedToolID: selectedToolID,
                                        selectedWindowPreset: selectedTwoDWindowPreset,
                                        selectedCLUTPreset: selectedTwoDCLUTPreset,
                                        isWindowInverted: isTwoDWindowInverted,
                                        selectedROIKind: selectedTwoDROIKind,
                                        syncState: twoDSyncState ?? Self.legacySyncState(isEnabled: isTwoDSyncEnabled),
                                        isLocationSyncEnabled: isTwoDLocationSyncEnabled,
                                        scrollSettings: twoDScrollSettings,
                                        selectedScreenLayout: selectedTwoDScreenLayout,
                                        enabledScreenLayouts: enabledTwoDScreenLayouts,
                                        isImageAnnotationsVisible: isTwoDImageAnnotationsVisible,
                                        isReferenceLinesVisible: isTwoDReferenceLinesVisible,
                                        isReferenceLinesEnabled: isTwoDReferenceLinesEnabled,
                                        isBookmarksPanelVisible: isTwoDBookmarksPanelVisible,
                                        canDeleteAllBookmarks: canDeleteAllTwoDBookmarks,
                                        selectedResliceAxis: selectedTwoDResliceAxis,
                                        isResliceEnabled: isTwoDResliceEnabled,
                                        resliceDisabledMessage: twoDResliceDisabledMessage,
                                        isThickSlabEnabled: isTwoDThickSlabEnabled,
                                        thickSlabDisabledMessage: twoDThickSlabDisabledMessage)
        }
    }

    private static func legacySyncState(isEnabled: Bool) -> ViewerSyncState {
        ViewerSyncState(syncTransforms: isEnabled,
                        syncWindowLevel: isEnabled,
                        syncLocation: false,
                        syncSameStudy: true)
    }

    private func single3DConfiguration(selectedToolID: ViewerToolID?,
                                       selectedWindowPreset: Volume3DWindowPreset,
                                       selectedCLUTPreset: Volume3DCLUTPreset,
                                       selectedRotationTarget: Volume3DRotationTarget,
                                       volumeBrushState: VolumeBrushState,
                                       isImageAnnotationsVisible: Bool,
                                       isShareEnabled: Bool) -> ViewerChromeConfiguration {
        let selected = selectedToolID ?? .orientation
        return ViewerChromeConfiguration(
            mode: .single3D,
            bottomTools: [
                volume3DTool(.orientation,
                             icon: "rotate.3d",
                             title: "Rotate",
                             selected: selected,
                             menu: orientationMenu),
                volume3DTool(.windowLevel,
                             icon: "sun.max",
                             title: "WW/WL",
                             selected: selected,
                             menu: volume3DWindowLevelMenu(selectedWindowPreset: selectedWindowPreset,
                                                           selectedCLUTPreset: selectedCLUTPreset)),
                volume3DTool(.rotation,
                             icon: "gyroscope",
                             title: "Tilt",
                             selected: selected,
                             menu: volume3DRotationMenu(selectedTarget: selectedRotationTarget)),
                volume3DTool(.crop,
                             icon: "crop",
                             title: "Crop",
                             selected: selected,
                             action: .activateOverlay(.crop3D),
                             menu: Volume3DCropToolMenu.menu),
                volume3DTool(.brush,
                             icon: "paintbrush",
                             title: "Brush",
                             selected: selected,
                             action: .activateOverlay(.brush3D),
                             menu: Volume3DBrushToolMenu.menu(state: volumeBrushState))
            ],
            optionsAction: .openMenu(.volume3DOptions),
            optionsMenu: volume3DOptionsMenu(isImageAnnotationsVisible: isImageAnnotationsVisible,
                                             isShareEnabled: isShareEnabled)
        )
    }

    private func mprConfiguration(selectedToolID: ViewerToolID?,
                                  selectedScreenLayout: MPRScreenLayout,
                                  selectedWindowPreset: MPRWindowPreset,
                                  selectedCLUTPreset: Volume3DCLUTPreset,
                                  isWindowInverted: Bool,
                                  selectedROIKind: ViewerROIKind,
                                  isAnnotationsVisible: Bool,
                                  isCrosshairVisible: Bool,
                                  isShareEnabled: Bool) -> ViewerChromeConfiguration {
        let selected = selectedToolID ?? .scroll
        return ViewerChromeConfiguration(
            mode: .clinical,
            bottomTools: [
                mprTool(.scroll,
                        icon: "square.stack.3d.down.forward",
                        title: "Scroll",
                        selected: selected,
                        menu: mprScrollMenu),
                mprTool(.windowLevel,
                        icon: "sun.max",
                        title: "WW/WL",
                        selected: selected,
                        menu: mprWindowLevelMenu(selectedWindowPreset: selectedWindowPreset,
                                                 selectedCLUTPreset: selectedCLUTPreset,
                                                 isWindowInverted: isWindowInverted)),
                mprTool(.rotation,
                        icon: "crop.rotate",
                        title: "Rotation",
                        selected: selected,
                        menu: mprRotationMenu),
                mprTool(.roi, icon: "ruler", title: "ROI", selected: selected, menu: mprROIMenu(selectedKind: selectedROIKind)),
                mprTool(.thickSlab,
                        icon: "square.3.layers.3d",
                        title: "Thick Slab",
                        selected: selected,
                        action: .openSettings(.mprThickSlab))
            ],
            optionsAction: .openMenu(.mprOptions),
            optionsMenu: mprOptionsMenu(selectedScreenLayout: selectedScreenLayout,
                                        isAnnotationsVisible: isAnnotationsVisible,
                                        isCrosshairVisible: isCrosshairVisible,
                                        isShareEnabled: isShareEnabled)
        )
    }

    private func stack2DConfiguration(selectedToolID: ViewerToolID?,
                                      selectedWindowPreset: Volume3DWindowPreset,
                                      selectedCLUTPreset: Clinical2DCLUT,
                                      isWindowInverted: Bool,
                                      selectedROIKind: ViewerROIKind,
                                      syncState: ViewerSyncState,
                                      isLocationSyncEnabled: Bool,
                                      scrollSettings: TwoDScrollSettings,
                                      selectedScreenLayout: TwoDScreenLayout,
                                      enabledScreenLayouts: Set<TwoDScreenLayout>,
                                      isImageAnnotationsVisible: Bool,
                                      isReferenceLinesVisible: Bool,
                                      isReferenceLinesEnabled: Bool,
                                      isBookmarksPanelVisible: Bool,
                                      canDeleteAllBookmarks: Bool,
                                      selectedResliceAxis: MTKCore.Axis,
                                      isResliceEnabled: Bool,
                                      resliceDisabledMessage: String?,
                                      isThickSlabEnabled: Bool,
                                      thickSlabDisabledMessage: String?) -> ViewerChromeConfiguration {
        let selected = selectedToolID ?? .scroll
        return ViewerChromeConfiguration(
            mode: .stack2D,
            bottomTools: [
                twoDTool(.scroll,
                         selected: selected,
                         menu: stack2DScrollMenu(settings: scrollSettings)),
                twoDTool(.windowLevel,
                         selected: selected,
                         menu: stack2DWindowLevelMenu(selectedWindowPreset: selectedWindowPreset,
                                                      selectedCLUTPreset: selectedCLUTPreset,
                                                      isWindowInverted: isWindowInverted)),
                twoDTool(.rotation,
                         selected: selected,
                         menu: stack2DRotationMenu),
                twoDTool(.roi,
                         selected: selected,
                         menu: stack2DROIMenu(selectedKind: selectedROIKind)),
                twoDTool(.sync,
                         selected: selected,
                         menu: stack2DSyncMenu(state: syncState,
                                               isLocationSyncEnabled: isLocationSyncEnabled)),
                twoDTool(.reslice,
                         selected: selected,
                         isEnabled: isResliceEnabled,
                         disabledMessage: resliceDisabledMessage,
                         menu: stack2DResliceMenu(selectedAxis: selectedResliceAxis,
                                                  isEnabled: isResliceEnabled)),
                twoDTool(.thickSlab,
                         selected: selected,
                         isEnabled: isThickSlabEnabled,
                         disabledMessage: thickSlabDisabledMessage,
                         action: .openSettings(.stack2DThickSlab))
            ],
            optionsAction: .openMenu(.stack2DOptions),
            optionsMenu: stack2DOptionsMenu(selectedScreenLayout: selectedScreenLayout,
                                            enabledScreenLayouts: enabledScreenLayouts,
                                            isImageAnnotationsVisible: isImageAnnotationsVisible,
                                            isReferenceLinesVisible: isReferenceLinesVisible,
                                            isReferenceLinesEnabled: isReferenceLinesEnabled,
                                            isBookmarksPanelVisible: isBookmarksPanelVisible,
                                            canDeleteAllBookmarks: canDeleteAllBookmarks)
        )
    }

    private func volume3DTool(_ volumeTool: Volume3DTool,
                              icon: String,
                              title: String,
                              selected: ViewerToolID,
                              action: ViewerToolAction? = nil,
                              menu: ViewerToolMenu? = nil) -> ViewerToolDescriptor {
        tool(volumeTool.viewerToolID,
             icon: icon,
             title: title,
             selected: selected,
             action: action,
             menu: menu,
             accessibilityIdentifier: volumeTool.accessibilityIdentifier)
    }

    private func mprTool(_ mprTool: MPRTool,
                         icon: String,
                         title: String,
                         selected: ViewerToolID,
                         action: ViewerToolAction? = nil,
                         menu: ViewerToolMenu? = nil) -> ViewerToolDescriptor {
        tool(mprTool.viewerToolID,
             icon: icon,
             title: title,
             selected: selected,
             action: action,
             menu: menu,
             accessibilityIdentifier: mprTool.accessibilityIdentifier)
    }

    private func twoDTool(_ twoDTool: Clinical2DTool,
                          selected: ViewerToolID,
                          isEnabled: Bool = true,
                          disabledMessage: String? = nil,
                          action: ViewerToolAction? = nil,
                          menu: ViewerToolMenu? = nil) -> ViewerToolDescriptor {
        tool(twoDTool.viewerToolID,
             icon: twoDTool.systemImage,
             title: twoDTool.title,
             selected: selected,
             isEnabled: isEnabled,
             disabledMessage: disabledMessage,
             action: action,
             menu: menu,
             accessibilityIdentifier: twoDTool.accessibilityIdentifier)
    }

    private func tool(_ id: ViewerToolID,
                      icon: String,
                      title: String,
                      selected: ViewerToolID,
                      isEnabled: Bool = true,
                      disabledMessage: String? = nil,
                      action: ViewerToolAction? = nil,
                      menu: ViewerToolMenu? = nil,
                      accessibilityIdentifier: String? = nil) -> ViewerToolDescriptor {
        ViewerToolDescriptor(id: id,
                             icon: icon,
                             title: title,
                             accessibilityIdentifier: accessibilityIdentifier,
                             isSelected: id == selected,
                             isEnabled: isEnabled,
                             disabledMessage: disabledMessage,
                             tapAction: action ?? .selectTool(id),
                             longPressMenu: menu)
    }

    private var orientationMenu: ViewerToolMenu {
        Volume3DOrientationMenu.menu
    }

    private var windowLevelMenu: ViewerToolMenu {
        ViewerToolMenu(title: "WW/WL", items: [
            ViewerToolMenuItem(id: "ww-wl-soft-tissue", title: "Soft Tissue", systemImage: "figure.stand", action: .selectTool(.windowLevel)),
            ViewerToolMenuItem(id: "ww-wl-bone", title: "Bone", systemImage: "figure.walk", action: .selectTool(.windowLevel)),
            ViewerToolMenuItem(id: "ww-wl-lung", title: "Lung", systemImage: "lungs", action: .selectTool(.windowLevel))
        ])
    }

    private func stack2DScrollMenu(settings: TwoDScrollSettings) -> ViewerToolMenu {
        ViewerToolMenu(entries: [
            .section(ViewerToolMenuSection(
                id: "2d-scroll-speed",
                title: "Scroll speed",
                systemImage: "speedometer",
                items: TwoDScrollSpeedPreset.allCases.map { preset in
                    ViewerToolMenuItem(id: "2d-scroll-speed-\(preset.rawValue)",
                                       title: preset.title,
                                       systemImage: preset == settings.selectedSpeedPreset ? "checkmark" : nil,
                                       action: .set2DScrollSpeed(preset.speed),
                                       isSelected: preset == settings.selectedSpeedPreset)
                }
            )),
            .section(ViewerToolMenuSection(
                id: "2d-scroll-sort",
                title: "Sort images by",
                systemImage: "arrow.up.arrow.down",
                items: TwoDImageSortMode.allCases.map { mode in
                    ViewerToolMenuItem(id: "2d-scroll-sort-\(mode.rawValue)",
                                       title: mode.title,
                                       systemImage: mode == settings.sortMode ? "checkmark" : nil,
                                       action: .set2DImageSortMode(mode),
                                       isSelected: mode == settings.sortMode)
                }
            )),
            .item(ViewerToolMenuItem(id: "2d-scroll-loop",
                                     title: "Loop through images",
                                     systemImage: settings.loopThroughImages ? "checkmark" : "repeat",
                                     action: .set2DLoopThroughImages(!settings.loopThroughImages),
                                     isSelected: settings.loopThroughImages)),
            .item(ViewerToolMenuItem(id: "2d-scroll-on-screen-controls",
                                     title: "On-screen controls",
                                     systemImage: settings.showsOnScreenControls ? "checkmark" : "rectangle.bottomthird.inset.filled",
                                     action: .set2DOnScreenControls(!settings.showsOnScreenControls),
                                     isSelected: settings.showsOnScreenControls)),
            .item(ViewerToolMenuItem(id: "2d-scroll-select",
                                     title: "Select Scroll tool",
                                     systemImage: Clinical2DTool.scroll.systemImage,
                                     action: .selectTool(.scroll)))
        ], accessibilityIdentifier: "MTK2DToolMenuScroll")
    }

    private func stack2DWindowLevelMenu(selectedWindowPreset: Volume3DWindowPreset,
                                        selectedCLUTPreset: Clinical2DCLUT,
                                        isWindowInverted: Bool) -> ViewerToolMenu {
        var entries: [ViewerToolMenuEntry] = Volume3DWindowPreset.allCases.map { preset in
            .item(ViewerToolMenuItem(id: "2d-window-\(preset.rawValue)",
                                     title: preset.displayName,
                                     systemImage: preset == selectedWindowPreset ? "checkmark" : nil,
                                     action: .set2DWindowPreset(preset),
                                     isSelected: preset == selectedWindowPreset))
        }
        entries.append(
            .section(
                ViewerToolMenuSection(
                    id: "2d-window-cluts",
                    title: "CLUTs",
                    items: Clinical2DCLUT.allCases.map { preset in
                        ViewerToolMenuItem(id: "2d-clut-\(preset.rawValue)",
                                           title: preset.title,
                                           systemImage: preset == selectedCLUTPreset ? "checkmark" : nil,
                                           action: .set2DCLUTPreset(preset),
                                           isSelected: preset == selectedCLUTPreset)
                    }
                )
            )
        )
        entries.append(contentsOf: [
            .item(ViewerToolMenuItem(id: "2d-window-invert",
                                     title: "Invert",
                                     systemImage: isWindowInverted ? "checkmark" : nil,
                                     action: .toggle2DWindowInvert,
                                     isSelected: isWindowInverted)),
            .item(ViewerToolMenuItem(id: "2d-window-manual",
                                     title: "Set WW/WL Manually",
                                     action: .openSettings(.stack2DWindowLevelManual))),
            .item(ViewerToolMenuItem(id: "2d-window-select",
                                     title: "Select WW/WL tool",
                                     systemImage: Clinical2DTool.windowLevel.systemImage,
                                     action: .selectTool(.windowLevel)))
        ])
        return ViewerToolMenu(title: "WW/WL",
                              entries: entries,
                              accessibilityIdentifier: "MTK2DToolMenuWindowLevel")
    }

    private var stack2DRotationMenu: ViewerToolMenu {
        ViewerToolMenu(title: "Rotation", items: [
            ViewerToolMenuItem(id: "2d-rotation-cw",
                               title: "Rotate 90° CW",
                               systemImage: "rotate.right",
                               action: .rotate2DByDegrees(90)),
            ViewerToolMenuItem(id: "2d-rotation-ccw",
                               title: "Rotate 90° CCW",
                               systemImage: "rotate.left",
                               action: .rotate2DByDegrees(-90)),
            ViewerToolMenuItem(id: "2d-rotation-flip-horizontal",
                               title: "Flip Horizontal",
                               systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               action: .flip2DHorizontal),
            ViewerToolMenuItem(id: "2d-rotation-flip-vertical",
                               title: "Flip Vertical",
                               systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                               action: .flip2DVertical),
            ViewerToolMenuItem(id: "2d-rotation-reset",
                               title: "Reset",
                               systemImage: "arrow.counterclockwise",
                               action: .reset2DTransform),
            ViewerToolMenuItem(id: "2d-rotation-select",
                               title: "Select Rotation tool",
                               systemImage: Clinical2DTool.rotation.systemImage,
                               action: .selectTool(.rotation))
        ], accessibilityIdentifier: "MTK2DToolMenuRotation")
    }

    private func stack2DROIMenu(selectedKind: ViewerROIKind) -> ViewerToolMenu {
        var entries = ViewerROIKind.allCases.map { kind in
            ViewerToolMenuEntry.item(
                ViewerToolMenuItem(id: "2d-roi-\(kind.stableIdentifier)",
                                   title: kind.displayName,
                                   systemImage: kind == selectedKind ? "checkmark" : kind.systemImage,
                                   action: .set2DROIKind(kind),
                                   isEnabled: kind.supportsDrawnAnnotationMeasurement,
                                   isSelected: kind == selectedKind)
            )
        }
        entries.append(contentsOf: [
            .item(ViewerToolMenuItem(id: "2d-roi-delete-view",
                                     title: "Delete ROIs in View",
                                     systemImage: "trash",
                                     action: .delete2DROIsInView)),
            .item(ViewerToolMenuItem(id: "2d-roi-delete-series",
                                     title: "Delete All ROIs in Series",
                                     systemImage: "trash.slash",
                                     action: .deleteAll2DROIs))
        ])
        return ViewerToolMenu(entries: entries, accessibilityIdentifier: "MTK2DToolMenuROI")
    }

    private func stack2DSyncMenu(state: ViewerSyncState,
                                 isLocationSyncEnabled: Bool) -> ViewerToolMenu {
        ViewerToolMenu(items: [
            ViewerToolMenuItem(id: "2d-sync-transform",
                               title: "Sync image transforms",
                               systemImage: state.syncTransforms ? "checkmark" : nil,
                               action: .set2DSyncOption(.transforms, !state.syncTransforms),
                               isSelected: state.syncTransforms),
            ViewerToolMenuItem(id: "2d-sync-window",
                               title: "Sync WW/WL",
                               systemImage: state.syncWindowLevel ? "checkmark" : nil,
                               action: .set2DSyncOption(.windowLevel, !state.syncWindowLevel),
                               isSelected: state.syncWindowLevel),
            ViewerToolMenuItem(id: "2d-sync-location",
                               title: "Sync images (location)",
                               systemImage: state.syncLocation ? "checkmark" : nil,
                               action: .set2DSyncOption(.location, !state.syncLocation),
                               isEnabled: isLocationSyncEnabled,
                               isSelected: state.syncLocation),
            ViewerToolMenuItem(id: "2d-sync-same-study",
                               title: "Sync images (same study)",
                               systemImage: state.syncSameStudy ? "checkmark" : nil,
                               action: .set2DSyncOption(.sameStudy, !state.syncSameStudy),
                               isSelected: state.syncSameStudy)
        ], accessibilityIdentifier: "MTK2DToolMenuSync")
    }

    private func stack2DResliceMenu(selectedAxis: MTKCore.Axis,
                                    isEnabled: Bool) -> ViewerToolMenu {
        ViewerToolMenu(items: [
            stack2DResliceItem(.sagittal, selectedAxis: selectedAxis, isEnabled: isEnabled),
            stack2DResliceItem(.coronal, selectedAxis: selectedAxis, isEnabled: isEnabled),
            stack2DResliceItem(.axial, selectedAxis: selectedAxis, isEnabled: isEnabled)
        ], accessibilityIdentifier: "MTK2DToolMenuReslice")
    }

    private func stack2DResliceItem(_ axis: MTKCore.Axis,
                                    selectedAxis: MTKCore.Axis,
                                    isEnabled: Bool) -> ViewerToolMenuItem {
        ViewerToolMenuItem(id: "2d-reslice-\(stack2DAxisIdentifier(axis))",
                           title: axis.clinicalDisplayName,
                           systemImage: axis == selectedAxis ? "checkmark" : nil,
                           action: .set2DResliceAxis(axis),
                           isEnabled: isEnabled,
                           isSelected: axis == selectedAxis)
    }

    private func stack2DAxisIdentifier(_ axis: MTKCore.Axis) -> String {
        switch axis {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }

    private func mprWindowLevelMenu(selectedWindowPreset: MPRWindowPreset,
                                    selectedCLUTPreset: Volume3DCLUTPreset,
                                    isWindowInverted: Bool) -> ViewerToolMenu {
        var entries: [ViewerToolMenuEntry] = MPRWindowPreset.allCases.map { preset in
            .item(ViewerToolMenuItem(id: "mpr-window-\(preset.rawValue)",
                                     title: preset.displayName,
                                     systemImage: preset == selectedWindowPreset ? "checkmark" : nil,
                                     action: .setMPRWindowPreset(preset),
                                     isSelected: preset == selectedWindowPreset))
        }
        entries.append(
            .section(
                ViewerToolMenuSection(
                    id: "mpr-window-cluts",
                    title: "CLUTs",
                    maximumVisibleItems: 12,
                    items: Volume3DCLUTPreset.allPresets.map { preset in
                        ViewerToolMenuItem(id: "mpr-clut-\(preset.id)",
                                           title: preset.displayName,
                                           systemImage: preset == selectedCLUTPreset ? "checkmark" : nil,
                                           action: .setMPRCLUTPreset(preset),
                                           isSelected: preset == selectedCLUTPreset)
                    }
                )
            )
        )
        entries.append(contentsOf: [
            .item(ViewerToolMenuItem(id: "mpr-window-invert",
                                     title: "Invert",
                                     systemImage: isWindowInverted ? "checkmark" : nil,
                                     action: .toggleMPRWindowInvert,
                                     isSelected: isWindowInverted)),
            .item(ViewerToolMenuItem(id: "mpr-window-manual",
                                     title: "Set WW/WL Manually",
                                     action: .openSettings(.mprWindowLevelManual))),
            .item(ViewerToolMenuItem(id: "mpr-window-select",
                                     title: "Select WW/WL tool",
                                     systemImage: "sun.max",
                                     action: .selectTool(.windowLevel)))
        ])
        return ViewerToolMenu(title: "WW/WL", entries: entries)
    }

    private var mprScrollMenu: ViewerToolMenu {
        ViewerToolMenu(items: [
            ViewerToolMenuItem(id: "mpr-scroll-select",
                               title: "Select Scroll tool",
                               systemImage: "square.stack.3d.down.forward",
                               action: .selectTool(.scroll))
        ])
    }

    private var mprRotationMenu: ViewerToolMenu {
        ViewerToolMenu(title: "Rotation", items: [
            ViewerToolMenuItem(id: "mpr-rotation-select",
                               title: "Select Rotation tool",
                               systemImage: "crop.rotate",
                               action: .selectTool(.rotation))
        ])
    }

    private func mprROIMenu(selectedKind: ViewerROIKind) -> ViewerToolMenu {
        var entries = ViewerROIKind.allCases.map { kind in
            ViewerToolMenuEntry.item(
                ViewerToolMenuItem(id: "mpr-roi-\(kind.stableIdentifier)",
                                   title: kind.displayName,
                                   systemImage: kind == selectedKind ? "checkmark" : kind.systemImage,
                                   action: .setMPRROIKind(kind),
                                   isEnabled: kind.supportsDrawnAnnotationMeasurement,
                                   isSelected: kind == selectedKind)
            )
        }
        entries.append(contentsOf: [
            .item(ViewerToolMenuItem(id: "mpr-roi-delete-view",
                                     title: "Delete ROIs in View",
                                     systemImage: "trash",
                                     action: .deleteMPRROIsInView)),
            .item(ViewerToolMenuItem(id: "mpr-roi-delete-series",
                                     title: "Delete All ROIs in Series",
                                     systemImage: "trash.slash",
                                     action: .deleteAllMPRROIs))
        ])
        return ViewerToolMenu(entries: entries, accessibilityIdentifier: "MPRROIToolMenu")
    }

    private func mprOptionsMenu(selectedScreenLayout: MPRScreenLayout,
                                isAnnotationsVisible: Bool,
                                isCrosshairVisible: Bool,
                                isShareEnabled: Bool) -> ViewerToolMenu {
        ViewerToolMenu(entries: [
            .section(ViewerToolMenuSection(
                id: "mpr-screen-layout",
                title: "Screen Layout",
                systemImage: "rectangle.split.2x1",
                accessibilityIdentifier: "MPRScreenLayoutMenu",
                items: MPRScreenLayout.allCases.map { layout in
                    ViewerToolMenuItem(
                        id: "mpr-layout-\(layout.rawValue)",
                        title: layout.title,
                        systemImage: layout == selectedScreenLayout ? "checkmark" : nil,
                        action: .setMPRScreenLayout(layout),
                        isSelected: layout == selectedScreenLayout
                    )
                }
            )),
            .item(ViewerToolMenuItem(id: "mpr-options-image-annotations",
                                     title: "Image Annotations",
                                     systemImage: isAnnotationsVisible ? "checkmark" : nil,
                                     action: .toggleMPRAnnotations,
                                     isSelected: isAnnotationsVisible)),
            .item(ViewerToolMenuItem(id: "mpr-options-show-crosshair",
                                     title: "Show Crosshair",
                                     systemImage: isCrosshairVisible ? "checkmark" : nil,
                                     action: .toggleMPRCrosshair,
                                     isSelected: isCrosshairVisible)),
            .item(ViewerToolMenuItem(id: "mpr-options-reset-views",
                                     title: "Reset Views",
                                     systemImage: "arrow.triangle.2.circlepath",
                                     action: .resetMPRViews)),
            .section(ViewerToolMenuSection(
                id: "mpr-options-share",
                title: "Share",
                systemImage: "square.and.arrow.up",
                accessibilityIdentifier: "MPRShareMenu",
                items: [
                    ViewerToolMenuItem(
                        id: "mpr-options-share-snapshot",
                        title: "Export MPR Snapshot",
                        systemImage: "photo",
                        action: .shareMPRSnapshot,
                        isEnabled: isShareEnabled
                    )
                ]
            ))
        ], accessibilityIdentifier: "MPROptionsMenu")
    }

    private func stack2DOptionsMenu(selectedScreenLayout: TwoDScreenLayout,
                                    enabledScreenLayouts: Set<TwoDScreenLayout>,
                                    isImageAnnotationsVisible: Bool,
                                    isReferenceLinesVisible: Bool,
                                    isReferenceLinesEnabled: Bool,
                                    isBookmarksPanelVisible: Bool,
                                    canDeleteAllBookmarks: Bool) -> ViewerToolMenu {
        ViewerToolMenu(entries: [
            .section(ViewerToolMenuSection(
                id: "2d-options-screen-layout",
                title: "Screen Layout",
                systemImage: "rectangle.split.2x1",
                accessibilityIdentifier: "Stack2DScreenLayoutMenu",
                items: TwoDScreenLayout.allCases.map { layout in
                    ViewerToolMenuItem(
                        id: "2d-layout-\(layout.rawValue)",
                        title: layout.title,
                        systemImage: layout == selectedScreenLayout ? "checkmark" : nil,
                        action: .set2DScreenLayout(layout),
                        isEnabled: enabledScreenLayouts.contains(layout),
                        isSelected: layout == selectedScreenLayout
                    )
                }
            )),
            .item(ViewerToolMenuItem(id: "2d-options-image-annotations",
                                     title: "Image Annotations",
                                     systemImage: isImageAnnotationsVisible ? "checkmark" : nil,
                                     action: .toggle2DImageAnnotations,
                                     isSelected: isImageAnnotationsVisible)),
            .item(ViewerToolMenuItem(id: "2d-options-reference-lines",
                                     title: "Show Reference Lines",
                                     systemImage: isReferenceLinesVisible ? "checkmark" : nil,
                                     action: .toggle2DReferenceLines,
                                     isEnabled: isReferenceLinesEnabled,
                                     isSelected: isReferenceLinesVisible)),
            .section(ViewerToolMenuSection(
                id: "2d-options-bookmarks",
                title: "Bookmarks",
                systemImage: "bookmark",
                items: [
                    ViewerToolMenuItem(id: "2d-bookmark-add",
                                       title: "Add bookmark",
                                       systemImage: "bookmark.fill",
                                       action: .add2DBookmark),
                    ViewerToolMenuItem(id: "2d-bookmarks-open",
                                       title: "Bookmarks",
                                       systemImage: "bookmarks",
                                       action: .show2DBookmarks),
                    ViewerToolMenuItem(id: "2d-bookmarks-panel",
                                       title: "Show Bookmarks panel",
                                       systemImage: isBookmarksPanelVisible ? "checkmark" : nil,
                                       action: .toggle2DBookmarksPanel,
                                       isSelected: isBookmarksPanelVisible),
                    ViewerToolMenuItem(id: "2d-bookmarks-delete-all",
                                       title: "Delete all",
                                       systemImage: "trash",
                                       action: .deleteAll2DBookmarks,
                                       isEnabled: canDeleteAllBookmarks)
                ]
            )),
            .item(ViewerToolMenuItem(id: "2d-options-metadata",
                                     title: "Metadata",
                                     systemImage: "list.bullet.rectangle",
                                     action: .show2DMetadata)),
            .section(ViewerToolMenuSection(
                id: "2d-options-share",
                title: "Share",
                systemImage: "square.and.arrow.up",
                items: [
                    ViewerToolMenuItem(id: "2d-share-jpeg",
                                       title: "Export image to JPEG",
                                       systemImage: "photo",
                                       action: .share2DCurrentImage)
                ]
            ))
        ], accessibilityIdentifier: "Stack2DOptionsMenu")
    }

    private func volume3DOptionsMenu(isImageAnnotationsVisible: Bool,
                                     isShareEnabled: Bool) -> ViewerToolMenu {
        ViewerToolMenu(entries: [
            .item(ViewerToolMenuItem(id: "3d-options-image-annotations",
                                     title: "Image Annotations",
                                     systemImage: isImageAnnotationsVisible ? "checkmark" : nil,
                                     action: .toggle3DImageAnnotations,
                                     isSelected: isImageAnnotationsVisible)),
            .item(ViewerToolMenuItem(id: "3d-options-vr-settings",
                                     title: "VR Settings",
                                     systemImage: "slider.horizontal.3",
                                     action: .openSettings(.volumeRenderSettings))),
            .section(ViewerToolMenuSection(
                id: "3d-options-screen-state",
                title: "VR screen state",
                systemImage: "square.stack.3d.up",
                accessibilityIdentifier: "Volume3DScreenStateMenu",
                items: [
                    ViewerToolMenuItem(id: "3d-options-manage-states",
                                       title: "Manage states",
                                       systemImage: "folder",
                                       action: .none,
                                       isEnabled: false),
                    ViewerToolMenuItem(id: "3d-options-save-new-state",
                                       title: "Save new state",
                                       systemImage: "plus",
                                       action: .none,
                                       isEnabled: false)
                ]
            )),
            .section(ViewerToolMenuSection(
                id: "3d-options-export",
                title: "Export options",
                systemImage: "square.and.arrow.up",
                accessibilityIdentifier: "Volume3DExportOptionsMenu",
                items: [
                    ViewerToolMenuItem(id: "3d-options-share-image",
                                       title: "Share 3D Image",
                                       systemImage: "photo",
                                       action: .share3DSnapshot,
                                       isEnabled: isShareEnabled)
                ]
            )),
            .section(ViewerToolMenuSection(
                id: "3d-options-vr-save",
                title: "VR save options...",
                systemImage: "externaldrive",
                accessibilityIdentifier: "Volume3DSaveOptionsMenu",
                items: [
                    ViewerToolMenuItem(id: "3d-options-new-dicom-series",
                                       title: "Create new DICOM series from 3D",
                                       systemImage: "square.stack.3d.up",
                                       action: .none,
                                       isEnabled: false),
                    ViewerToolMenuItem(id: "3d-options-save-image-dicom",
                                       title: "Save image as DICOM",
                                       systemImage: "doc.badge.plus",
                                       action: .none,
                                       isEnabled: false)
                ]
            )),
            .item(ViewerToolMenuItem(id: "3d-options-create-ssd-mesh",
                                     title: "Create 3D mesh (SSD)",
                                     systemImage: "cube",
                                     action: .none,
                                     isEnabled: false))
        ], accessibilityIdentifier: "Volume3DOptionsMenu")
    }

    private func volume3DWindowLevelMenu(selectedWindowPreset: Volume3DWindowPreset,
                                         selectedCLUTPreset: Volume3DCLUTPreset) -> ViewerToolMenu {
        Volume3DWindowLevelToolMenu.menu(selectedWindowPreset: selectedWindowPreset,
                                         selectedCLUTPreset: selectedCLUTPreset)
    }

    private func volume3DRotationMenu(selectedTarget: Volume3DRotationTarget) -> ViewerToolMenu {
        Volume3DRotationToolMenu.menu(selectedTarget: selectedTarget)
    }

}

public struct ViewerChromeState: Equatable, Sendable {
    public private(set) var activeMode: ClinicalViewerMode?
    public var selectedTools: [ClinicalViewerMode: ViewerToolID]
    public var activeToolMenu: ViewerToolID?
    public var activeSettingsSheet: ViewerSettingsSheetID?
    public var activeOptionsMenu: ViewerOptionsMenuID?
    public var activeOverlay: ViewerChromeOverlayID?

    public init(activeMode: ClinicalViewerMode? = nil,
                selectedTools: [ClinicalViewerMode: ViewerToolID] = [:],
                activeToolMenu: ViewerToolID? = nil,
                activeSettingsSheet: ViewerSettingsSheetID? = nil,
                activeOptionsMenu: ViewerOptionsMenuID? = nil,
                activeOverlay: ViewerChromeOverlayID? = nil) {
        self.activeMode = activeMode
        self.selectedTools = selectedTools
        self.activeToolMenu = activeToolMenu
        self.activeSettingsSheet = activeSettingsSheet
        self.activeOptionsMenu = activeOptionsMenu
        self.activeOverlay = activeOverlay
    }

    public func selectedToolID(for mode: ClinicalViewerMode) -> ViewerToolID? {
        selectedTools[mode]
    }

    public mutating func prepareForMode(_ mode: ClinicalViewerMode,
                                        configuration: ViewerChromeConfiguration) {
        if activeMode != mode {
            resetTransientState()
            activeMode = mode
        }
        if selectedTools[mode] == nil {
            selectedTools[mode] = configuration.defaultToolID
        }
    }

    public mutating func activateTool(_ tool: ViewerToolDescriptor,
                                      in configuration: ViewerChromeConfiguration) {
        guard tool.isEnabled else { return }
        activeMode = configuration.mode
        selectedTools[configuration.mode] = tool.id
        activeToolMenu = nil
        activeSettingsSheet = nil
        activeOptionsMenu = nil
        apply(tool.tapAction, mode: configuration.mode)
    }

    public mutating func toggleMenu(for tool: ViewerToolDescriptor,
                                    in configuration: ViewerChromeConfiguration) {
        guard tool.isEnabled, tool.longPressMenu != nil else { return }
        activeMode = configuration.mode
        activeSettingsSheet = nil
        activeOptionsMenu = nil
        activeToolMenu = activeToolMenu == tool.id ? nil : tool.id
    }

    public mutating func activateMenuItem(_ item: ViewerToolMenuItem,
                                          in configuration: ViewerChromeConfiguration) {
        guard item.isEnabled else { return }
        activeMode = configuration.mode
        activeToolMenu = nil
        activeSettingsSheet = nil
        activeOptionsMenu = nil
        apply(item.action, mode: configuration.mode)
    }

    public mutating func toggleOptions(_ action: ViewerOptionsAction,
                                       in configuration: ViewerChromeConfiguration) {
        activeMode = configuration.mode
        activeToolMenu = nil
        activeOverlay = nil
        switch action {
        case .openSettings(let sheet):
            activeOptionsMenu = nil
            activeSettingsSheet = activeSettingsSheet == sheet ? nil : sheet
        case .openMenu(let menu):
            activeSettingsSheet = nil
            activeOptionsMenu = activeOptionsMenu == menu ? nil : menu
        case .none:
            activeSettingsSheet = nil
            activeOptionsMenu = nil
        }
    }

    public mutating func dismissPresentedChrome() {
        resetTransientState()
    }

    private mutating func apply(_ action: ViewerToolAction,
                                mode: ClinicalViewerMode) {
        switch action {
        case .selectTool(let id):
            selectedTools[mode] = id
            activeOverlay = nil
        case .activateOverlay(let overlay):
            activeOverlay = overlay
        case .set3DOrientation, .reset3DOrientation:
            selectedTools[mode] = .orientation
            activeOverlay = nil
        case .set3DWindowPreset, .set3DCLUTPreset:
            selectedTools[mode] = .windowLevel
            activeOverlay = nil
        case .set3DRotationTarget, .reset3DRotation:
            selectedTools[mode] = .rotation
            activeOverlay = nil
        case .reset3DCropClip:
            selectedTools[mode] = .crop
            activeOverlay = nil
        case .set3DBrushMode, .adjust3DBrushSize, .reset3DBrushVolume:
            selectedTools[mode] = .brush
            activeOverlay = nil
        case .toggle3DImageAnnotations, .share3DSnapshot:
            activeOverlay = nil
        case .setMPRScreenLayout, .toggleMPRAnnotations, .toggleMPRCrosshair,
             .resetActiveMPRView, .resetMPRViews, .shareMPRSnapshot:
            activeOverlay = nil
        case .setMPRWindowPreset, .setMPRCLUTPreset, .toggleMPRWindowInvert:
            selectedTools[mode] = .windowLevel
            activeOverlay = nil
        case .setMPRROIKind, .deleteMPRROIsInView, .deleteAllMPRROIs:
            selectedTools[mode] = .roi
            activeOverlay = nil
        case .set2DScrollSpeed, .set2DImageSortMode, .set2DLoopThroughImages, .set2DOnScreenControls:
            selectedTools[mode] = .scroll
            activeOverlay = nil
        case .set2DWindowPreset, .set2DCLUTPreset, .toggle2DWindowInvert:
            selectedTools[mode] = .windowLevel
            activeOverlay = nil
        case .rotate2DByDegrees, .flip2DHorizontal, .flip2DVertical, .reset2DTransform:
            selectedTools[mode] = .rotation
            activeOverlay = nil
        case .set2DROIKind, .delete2DROIsInView, .deleteAll2DROIs:
            selectedTools[mode] = .roi
            activeOverlay = nil
        case .set2DSyncEnabled, .set2DSyncOption:
            selectedTools[mode] = .sync
            activeOverlay = nil
        case .set2DResliceAxis:
            selectedTools[mode] = .reslice
            activeOverlay = nil
        case .set2DScreenLayout, .toggle2DImageAnnotations, .toggle2DReferenceLines,
             .add2DBookmark, .show2DBookmarks, .toggle2DBookmarksPanel,
             .deleteAll2DBookmarks, .show2DMetadata, .share2DCurrentImage:
            activeOverlay = nil
        case .openSettings(let sheet):
            if sheet == .mprWindowLevelManual || sheet == .stack2DWindowLevelManual {
                selectedTools[mode] = .windowLevel
            }
            activeSettingsSheet = sheet
            activeOptionsMenu = nil
            activeOverlay = nil
        case .none:
            activeOverlay = nil
        }
    }

    private mutating func resetTransientState() {
        activeToolMenu = nil
        activeSettingsSheet = nil
        activeOptionsMenu = nil
        activeOverlay = nil
    }
}
