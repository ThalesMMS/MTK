@testable import MTKUI
import XCTest

final class ViewerChromeConfigurationTests: XCTestCase {
    private let factory = ViewerChromeConfigurationFactory()

    func testSingle3DToolbarContainsExpectedToolsInOrder() {
        let configuration = factory.configuration(for: .single3D)

        XCTAssertEqual(configuration.mode, .single3D)
        XCTAssertEqual(configuration.bottomTools.count, 5)
        XCTAssertEqual(configuration.bottomTools.map(\.id), [
            .orientation,
            .windowLevel,
            .rotation,
            .crop,
            .brush
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.title), [
            "Rotate",
            "WW/WL",
            "Tilt",
            "Crop",
            "Brush"
        ])
        XCTAssertEqual(configuration.defaultToolID, .orientation)
        XCTAssertEqual(configuration.optionsAction, .openMenu(.volume3DOptions))
    }

    func testSingle3DOptionsMenuMatchesReferenceLayout() throws {
        let configuration = factory.configuration(
            for: .single3D,
            isVolume3DImageAnnotationsVisible: false,
            isVolume3DShareEnabled: true
        )
        let menu = try XCTUnwrap(configuration.optionsMenu)

        XCTAssertEqual(configuration.optionsAction, .openMenu(.volume3DOptions))
        XCTAssertEqual(menu.accessibilityIdentifier, "Volume3DOptionsMenu")
        XCTAssertEqual(menu.entries.map(\.id), [
            "3d-options-image-annotations",
            "3d-options-vr-settings",
            "3d-options-screen-state",
            "3d-options-export",
            "3d-options-vr-save",
            "3d-options-create-ssd-mesh"
        ])

        let annotations = try XCTUnwrap(menu.items.first { $0.id == "3d-options-image-annotations" })
        let settings = try XCTUnwrap(menu.items.first { $0.id == "3d-options-vr-settings" })
        let mesh = try XCTUnwrap(menu.items.first { $0.id == "3d-options-create-ssd-mesh" })

        XCTAssertEqual(annotations.title, "Image Annotations")
        XCTAssertEqual(annotations.action, .toggle3DImageAnnotations)
        XCTAssertFalse(annotations.isSelected)
        XCTAssertNil(annotations.systemImage)
        XCTAssertEqual(settings.title, "VR Settings")
        XCTAssertEqual(settings.action, .openSettings(.volumeRenderSettings))
        XCTAssertEqual(mesh.title, "Create 3D mesh (SSD)")
        XCTAssertFalse(mesh.isEnabled)

        let screenState = try XCTUnwrap(menu.sections.first { $0.id == "3d-options-screen-state" })
        XCTAssertEqual(screenState.title, "VR screen state")
        XCTAssertEqual(screenState.accessibilityIdentifier, "Volume3DScreenStateMenu")
        XCTAssertEqual(screenState.items.map(\.title), [
            "Manage states",
            "Save new state"
        ])
        XCTAssertEqual(screenState.items.map(\.isEnabled), [false, false])

        let export = try XCTUnwrap(menu.sections.first { $0.id == "3d-options-export" })
        let share = try XCTUnwrap(export.items.first { $0.id == "3d-options-share-image" })
        XCTAssertEqual(export.title, "Export options")
        XCTAssertEqual(export.accessibilityIdentifier, "Volume3DExportOptionsMenu")
        XCTAssertEqual(share.title, "Share 3D Image")
        XCTAssertEqual(share.action, .share3DSnapshot)
        XCTAssertTrue(share.isEnabled)

        let save = try XCTUnwrap(menu.sections.first { $0.id == "3d-options-vr-save" })
        XCTAssertEqual(save.title, "VR save options...")
        XCTAssertEqual(save.accessibilityIdentifier, "Volume3DSaveOptionsMenu")
        XCTAssertEqual(save.items.map(\.title), [
            "Create new DICOM series from 3D",
            "Save image as DICOM"
        ])
        XCTAssertEqual(save.items.map(\.isEnabled), [false, false])
    }

    func testSingle3DOptionsMenuReflectsAnnotationAndShareAvailability() throws {
        let configuration = factory.configuration(
            for: .single3D,
            isVolume3DImageAnnotationsVisible: true,
            isVolume3DShareEnabled: false
        )
        let menu = try XCTUnwrap(configuration.optionsMenu)
        let annotations = try XCTUnwrap(menu.items.first { $0.id == "3d-options-image-annotations" })
        let export = try XCTUnwrap(menu.sections.first { $0.id == "3d-options-export" })
        let share = try XCTUnwrap(export.items.first { $0.id == "3d-options-share-image" })

        XCTAssertTrue(annotations.isSelected)
        XCTAssertEqual(annotations.systemImage, "checkmark")
        XCTAssertFalse(share.isEnabled)
    }

    func testSingle3DToolbarExposesStableVolumeToolAccessibilityIdentifiers() {
        let configuration = factory.configuration(for: .single3D)

        XCTAssertEqual(configuration.bottomTools.map(\.id), Volume3DTool.allCases.map(\.viewerToolID))
        XCTAssertEqual(configuration.bottomTools.map(\.accessibilityIdentifier), [
            "Volume3DTool.orientation",
            "Volume3DTool.windowLevel",
            "Volume3DTool.rotation",
            "Volume3DTool.crop",
            "Volume3DTool.brush"
        ])
    }

    func testSingle3DLongPressMenusExposeStableAccessibilityIdentifiers() throws {
        let configuration = factory.configuration(for: .single3D)

        for tool in configuration.bottomTools {
            let menu = try XCTUnwrap(tool.longPressMenu, "\(tool.id) should expose a long press menu.")
            for item in menu.items {
                XCTAssertEqual(item.accessibilityIdentifier, "ViewerToolMenuItem.\(item.id)")
            }
            for section in menu.sections {
                XCTAssertEqual(section.accessibilityIdentifier, "ViewerToolMenuSection.\(section.id)")
                for item in section.items {
                    XCTAssertEqual(item.accessibilityIdentifier, "ViewerToolMenuItem.\(item.id)")
                }
            }
        }
    }

    func testMPRToolbarUsesSharedDescriptorsAndMPRSettingsAction() {
        let configuration = factory.configuration(for: .clinical)

        XCTAssertEqual(configuration.mode, .clinical)
        XCTAssertEqual(MPRToolbarTool.allCases.map(\.viewerToolID), [
            .scroll,
            .windowLevel,
            .rotation,
            .roi,
            .thickSlab
        ])
        XCTAssertEqual(configuration.bottomTools.count, 5)
        XCTAssertEqual(configuration.bottomTools.map(\.id), [
            .scroll,
            .windowLevel,
            .rotation,
            .roi,
            .thickSlab
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.title), [
            "Scroll",
            "WW/WL",
            "Rotation",
            "ROI",
            "Thick Slab"
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.accessibilityIdentifier), [
            "MPRToolScroll",
            "MPRToolWindowLevel",
            "MPRToolRotation",
            "MPRToolROI",
            "MPRToolThickSlab"
        ])
        XCTAssertEqual(configuration.bottomTools.last?.tapAction, .openSettings(.mprThickSlab))
        XCTAssertEqual(configuration.optionsAction, .openMenu(.mprOptions))
        XCTAssertNil(configuration.optionsMenu?.title)
        XCTAssertEqual(configuration.optionsMenu?.sections.first?.accessibilityIdentifier, "MPRScreenLayoutMenu")
        XCTAssertEqual(configuration.optionsMenu?.entries.map(\.id), [
            "mpr-screen-layout",
            "mpr-options-image-annotations",
            "mpr-options-show-crosshair",
            "mpr-options-reset-views",
            "mpr-options-share"
        ])
        XCTAssertEqual(configuration.defaultToolID, .scroll)
    }

    func testMPRToolbarToolMapsScrollToSliceInteraction() {
        XCTAssertEqual(MPRToolbarTool.scroll.clinicalInteractionTool, .slice)
        XCTAssertEqual(MPRToolbarTool.windowLevel.clinicalInteractionTool, .windowLevel)
        XCTAssertEqual(MPRToolbarTool.rotation.clinicalInteractionTool, .rotation)
        XCTAssertEqual(MPRToolbarTool.roi.clinicalInteractionTool, .roi)
        XCTAssertNil(MPRToolbarTool.thickSlab.clinicalInteractionTool)
    }

    func testMPRScrollToolExposesSelectionMenu() throws {
        let configuration = factory.configuration(for: .clinical, selectedToolID: .windowLevel)
        let scroll = try XCTUnwrap(configuration.bottomTools.first { $0.id == .scroll })
        let select = try XCTUnwrap(scroll.longPressMenu?.items.first)

        XCTAssertEqual(scroll.accessibilityIdentifier, "MPRToolScroll")
        XCTAssertEqual(select.id, "mpr-scroll-select")
        XCTAssertEqual(select.title, "Select Scroll tool")
        XCTAssertEqual(select.action, .selectTool(.scroll))
    }

    func testMPRRotationToolExposesSelectionMenu() throws {
        let configuration = factory.configuration(for: .clinical)
        let rotation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .rotation })
        let item = try XCTUnwrap(rotation.longPressMenu?.items.first)

        XCTAssertEqual(rotation.accessibilityIdentifier, "MPRToolRotation")
        XCTAssertEqual(rotation.longPressMenu?.title, "Rotation")
        XCTAssertEqual(item.id, "mpr-rotation-select")
        XCTAssertEqual(item.title, "Select Rotation tool")
        XCTAssertEqual(item.action, .selectTool(.rotation))
    }

    func testMPRToolbarReflectsSelectedTool() {
        let configuration = factory.configuration(for: .clinical, selectedToolID: .roi)

        XCTAssertEqual(configuration.bottomTools.map(\.isSelected), [
            false,
            false,
            false,
            true,
            false
        ])
    }

    func testMPRWindowLevelAndROIMenusExposeContextualItems() throws {
        let configuration = factory.configuration(for: .clinical)
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let roi = try XCTUnwrap(configuration.bottomTools.first { $0.id == .roi })

        XCTAssertEqual(windowLevel.longPressMenu?.items.map(\.title), [
            "Default",
            "Abdomen",
            "Bone",
            "Brain",
            "Lungs",
            "Other",
            "Invert",
            "Set WW/WL Manually",
            "Select WW/WL tool"
        ])
        XCTAssertEqual(windowLevel.longPressMenu?.sections.map(\.title), ["CLUTs"])
        XCTAssertEqual(windowLevel.longPressMenu?.sections.first?.items.count, 29)
        XCTAssertEqual(roi.longPressMenu?.accessibilityIdentifier, "MPRROIToolMenu")
        XCTAssertEqual(roi.longPressMenu?.items.map(\.title), [
            "Distance",
            "Angle",
            "Cobb Angle",
            "Point",
            "Area",
            "Ellipse",
            "Polygon",
            "Curved Line",
            "Text",
            "Arrow",
            "Freehand",
            "Volume",
            "CTR",
            "Delete ROIs in View",
            "Delete All ROIs in Series"
        ])
    }

    func testMPRROIMenuUsesSharedKindsAndSemanticActions() throws {
        let configuration = factory.configuration(for: .clinical, selectedMPRROIKind: .arrow)
        let roi = try XCTUnwrap(configuration.bottomTools.first { $0.id == .roi })
        let items = try XCTUnwrap(roi.longPressMenu?.items)
        let kindItems = Array(items.prefix(ViewerROIKind.allCases.count))

        XCTAssertEqual(kindItems.map(\.id), ViewerROIKind.allCases.map { "mpr-roi-\($0.stableIdentifier)" })
        XCTAssertEqual(kindItems.map(\.action), ViewerROIKind.allCases.map { .setMPRROIKind($0) })
        XCTAssertEqual(kindItems.map(\.isEnabled), ViewerROIKind.allCases.map(\.supportsDrawnAnnotationMeasurement))
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == "mpr-roi-arrow" }).isSelected)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == "mpr-roi-angle" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.id == "mpr-roi-volume" }).isEnabled)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "mpr-roi-delete-view" }).action,
                       .deleteMPRROIsInView)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "mpr-roi-delete-series" }).action,
                       .deleteAllMPRROIs)
    }

    func testMPRWindowLevelMenuUsesSemanticActionsAndSelectionState() throws {
        let selectedCLUT = try XCTUnwrap(Volume3DCLUTPreset.allPresets.first { $0.id == "system-clut" })
        let configuration = factory.configuration(
            for: .clinical,
            selectedMPRWindowPreset: .brain,
            selectedMPRCLUTPreset: selectedCLUT,
            isMPRWindowInverted: true
        )
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let items = try XCTUnwrap(windowLevel.longPressMenu?.items)
        let clutItems = try XCTUnwrap(windowLevel.longPressMenu?.sections.first?.items)

        XCTAssertEqual(items.prefix(6).map(\.action), [
            .setMPRWindowPreset(.default),
            .setMPRWindowPreset(.abdomen),
            .setMPRWindowPreset(.bone),
            .setMPRWindowPreset(.brain),
            .setMPRWindowPreset(.lungs),
            .setMPRWindowPreset(.other)
        ])
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == "mpr-window-brain" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "mpr-window-invert" }).action, .toggleMPRWindowInvert)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.id == "mpr-window-invert" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "mpr-window-manual" }).action,
                       .openSettings(.mprWindowLevelManual))
        XCTAssertEqual(try XCTUnwrap(clutItems.first { $0.id == "mpr-clut-\(selectedCLUT.id)" }).action,
                       .setMPRCLUTPreset(selectedCLUT))
        XCTAssertTrue(try XCTUnwrap(clutItems.first { $0.id == "mpr-clut-\(selectedCLUT.id)" }).isSelected)
    }

    func testMPROptionsMenuReflectsLayoutAndOverlayState() throws {
        let configuration = factory.configuration(
            for: .clinical,
            selectedMPRScreenLayout: .vSplit3x1,
            isMPRAnnotationsVisible: false,
            isMPRCrosshairVisible: true
        )
        let menu = try XCTUnwrap(configuration.optionsMenu)
        let layoutSection = try XCTUnwrap(menu.sections.first)

        XCTAssertEqual(layoutSection.title, "Screen Layout")
        XCTAssertEqual(layoutSection.items.map(\.title), [
            "Two Over One (2x1)",
            "One Over Two (1x2)",
            "Three Stacked (3x1)"
        ])
        XCTAssertEqual(layoutSection.items.map(\.isSelected), [false, false, true])
        XCTAssertEqual(layoutSection.items.map(\.action), [
            .setMPRScreenLayout(.hSplit2x1),
            .setMPRScreenLayout(.hSplit1x2),
            .setMPRScreenLayout(.vSplit3x1)
        ])

        let annotations = try XCTUnwrap(menu.items.first { $0.id == "mpr-options-image-annotations" })
        let crosshair = try XCTUnwrap(menu.items.first { $0.id == "mpr-options-show-crosshair" })
        let reset = try XCTUnwrap(menu.items.first { $0.id == "mpr-options-reset-views" })
        let shareSection = try XCTUnwrap(menu.sections.first { $0.id == "mpr-options-share" })
        let shareSnapshot = try XCTUnwrap(shareSection.items.first { $0.id == "mpr-options-share-snapshot" })

        XCTAssertFalse(annotations.isSelected)
        XCTAssertEqual(annotations.action, .toggleMPRAnnotations)
        XCTAssertTrue(crosshair.isSelected)
        XCTAssertEqual(crosshair.action, .toggleMPRCrosshair)
        XCTAssertNil(menu.items.first { $0.id == "mpr-options-reset-active-view" })
        XCTAssertEqual(reset.title, "Reset Views")
        XCTAssertEqual(reset.action, .resetMPRViews)
        XCTAssertEqual(shareSection.title, "Share")
        XCTAssertEqual(shareSection.accessibilityIdentifier, "MPRShareMenu")
        XCTAssertEqual(shareSnapshot.title, "Export MPR Snapshot")
        XCTAssertEqual(shareSnapshot.action, .shareMPRSnapshot)
        XCTAssertFalse(shareSnapshot.isEnabled)
    }

    func testMPROptionsMenuEnablesShareWhenMPRSnapshotIsExportable() throws {
        let configuration = factory.configuration(
            for: .clinical,
            isMPRShareEnabled: true
        )
        let menu = try XCTUnwrap(configuration.optionsMenu)
        let shareSection = try XCTUnwrap(menu.sections.first { $0.id == "mpr-options-share" })
        let share = try XCTUnwrap(shareSection.items.first { $0.id == "mpr-options-share-snapshot" })

        XCTAssertEqual(share.action, .shareMPRSnapshot)
        XCTAssertTrue(share.isEnabled)
    }

    func testStack2DOptionsMenuMatchesCompactReference() throws {
        let configuration = factory.configuration(for: .stack2D)
        let menu = try XCTUnwrap(configuration.optionsMenu)

        XCTAssertEqual(configuration.optionsAction, .openMenu(.stack2DOptions))
        XCTAssertEqual(menu.accessibilityIdentifier, "Stack2DOptionsMenu")
        XCTAssertEqual(menu.entries.map(\.id), [
            "2d-options-screen-layout",
            "2d-options-image-annotations",
            "2d-options-reference-lines",
            "2d-options-bookmarks",
            "2d-options-metadata",
            "2d-options-share"
        ])

        let layout = try XCTUnwrap(menu.sections.first { $0.id == "2d-options-screen-layout" })
        XCTAssertEqual(layout.title, "Screen Layout")
        XCTAssertEqual(layout.items.map(\.title), [
            "Single Window",
            "Dual (2x1)",
            "Triple (3x1)",
            "Quadruple (2x2)"
        ])
        XCTAssertEqual(layout.items.map(\.action), [
            .set2DScreenLayout(.singleWindow),
            .set2DScreenLayout(.dual2x1),
            .set2DScreenLayout(.triple3x1),
            .set2DScreenLayout(.quadruple2x2)
        ])
        XCTAssertEqual(layout.items.map(\.isSelected), [true, false, false, false])
        XCTAssertEqual(layout.items.map(\.isEnabled), [true, true, true, true])

        let annotations = try XCTUnwrap(menu.items.first { $0.id == "2d-options-image-annotations" })
        let referenceLines = try XCTUnwrap(menu.items.first { $0.id == "2d-options-reference-lines" })
        let metadata = try XCTUnwrap(menu.items.first { $0.id == "2d-options-metadata" })

        XCTAssertEqual(annotations.title, "Image Annotations")
        XCTAssertEqual(annotations.action, .toggle2DImageAnnotations)
        XCTAssertTrue(annotations.isSelected)
        XCTAssertEqual(annotations.systemImage, "checkmark")
        XCTAssertEqual(referenceLines.title, "Show Reference Lines")
        XCTAssertEqual(referenceLines.action, .toggle2DReferenceLines)
        XCTAssertFalse(referenceLines.isEnabled)
        XCTAssertEqual(metadata.action, .show2DMetadata)

        let bookmarks = try XCTUnwrap(menu.sections.first { $0.id == "2d-options-bookmarks" })
        XCTAssertEqual(bookmarks.items.map(\.title), [
            "Add bookmark",
            "Bookmarks",
            "Show Bookmarks panel",
            "Delete all"
        ])
        XCTAssertEqual(bookmarks.items.map(\.action), [
            .add2DBookmark,
            .show2DBookmarks,
            .toggle2DBookmarksPanel,
            .deleteAll2DBookmarks
        ])
        XCTAssertEqual(bookmarks.items.map(\.isEnabled), [true, true, true, false])

        let share = try XCTUnwrap(menu.sections.first { $0.id == "2d-options-share" })
        XCTAssertEqual(share.items.map(\.title), ["Export image to JPEG"])
        XCTAssertEqual(share.items.first?.action, .share2DCurrentImage)
    }

    func testStack2DToolbarUsesClinical2DToolsetInOrder() throws {
        let configuration = factory.configuration(for: .stack2D)

        XCTAssertEqual(configuration.mode, .stack2D)
        XCTAssertEqual(Clinical2DTool.allCases.map(\.viewerToolID), [
            .scroll,
            .windowLevel,
            .rotation,
            .roi,
            .sync,
            .reslice,
            .thickSlab
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.id), [
            .scroll,
            .windowLevel,
            .rotation,
            .roi,
            .sync,
            .reslice,
            .thickSlab
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.title), [
            "Scroll",
            "WW/WL",
            "Rotation",
            "ROI",
            "Sync",
            "Reslice",
            "Thick Slab"
        ])
        XCTAssertEqual(configuration.bottomTools.map(\.accessibilityIdentifier), [
            "MTK2DToolScroll",
            "MTK2DToolWindowLevel",
            "MTK2DToolRotation",
            "MTK2DToolROI",
            "MTK2DToolSync",
            "MTK2DToolReslice",
            "MTK2DToolThickSlab"
        ])
        let thickSlab = try XCTUnwrap(configuration.bottomTools.last)
        XCTAssertEqual(thickSlab.id, .thickSlab)
        XCTAssertEqual(thickSlab.tapAction, .openSettings(.stack2DThickSlab))
        XCTAssertNil(thickSlab.longPressMenu)
        XCTAssertTrue(configuration.bottomTools.dropLast().allSatisfy { $0.longPressMenu != nil })
        XCTAssertEqual(configuration.optionsAction, .openMenu(.stack2DOptions))
        XCTAssertNotNil(configuration.optionsMenu)
    }

    func testStack2DToolbarReflectsSelectedTool() {
        let configuration = factory.configuration(for: .stack2D, selectedToolID: .sync)

        XCTAssertEqual(configuration.bottomTools.map(\.isSelected), [
            false,
            false,
            false,
            false,
            true,
            false,
            false
        ])
    }

    func testStack2DLongPressMenusExposeContextualItems() throws {
        let selectedCLUT = Clinical2DCLUT.invertedGrayscale
        let configuration = factory.configuration(
            for: .stack2D,
            selectedTwoDWindowPreset: .brain,
            selectedTwoDCLUTPreset: selectedCLUT,
            isTwoDWindowInverted: true,
            selectedTwoDROIKind: .arrow,
            isTwoDSyncEnabled: true,
            selectedTwoDResliceAxis: .sagittal
        )
        let scroll = try XCTUnwrap(configuration.bottomTools.first { $0.id == .scroll })
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let rotation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .rotation })
        let roi = try XCTUnwrap(configuration.bottomTools.first { $0.id == .roi })
        let sync = try XCTUnwrap(configuration.bottomTools.first { $0.id == .sync })
        let reslice = try XCTUnwrap(configuration.bottomTools.first { $0.id == .reslice })

        XCTAssertEqual(scroll.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuScroll")
        XCTAssertEqual(scroll.longPressMenu?.sections.map(\.title), ["Scroll speed", "Sort images by"])
        XCTAssertEqual(scroll.longPressMenu?.sections.first?.items.map(\.id), [
            "2d-scroll-speed-slow",
            "2d-scroll-speed-normal",
            "2d-scroll-speed-fast"
        ])
        XCTAssertTrue(try XCTUnwrap(scroll.longPressMenu?.sections.first?.items.first { $0.id == "2d-scroll-speed-normal" }).isSelected)
        XCTAssertEqual(scroll.longPressMenu?.sections.last?.items.map(\.id), [
            "2d-scroll-sort-instancePosition",
            "2d-scroll-sort-instanceNumber",
            "2d-scroll-sort-acquisitionTime",
            "2d-scroll-sort-fileOrder"
        ])
        XCTAssertTrue(try XCTUnwrap(scroll.longPressMenu?.sections.last?.items.first { $0.id == "2d-scroll-sort-instancePosition" }).isSelected)
        XCTAssertEqual(scroll.longPressMenu?.items.map(\.id), [
            "2d-scroll-loop",
            "2d-scroll-on-screen-controls",
            "2d-scroll-select"
        ])
        XCTAssertEqual(windowLevel.longPressMenu?.items.map(\.title), [
            "Default",
            "Abdomen",
            "Bone",
            "Brain",
            "Lungs",
            "Endoscopy",
            "Other",
            "Invert",
            "Set WW/WL Manually",
            "Select WW/WL tool"
        ])
        XCTAssertEqual(windowLevel.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuWindowLevel")
        XCTAssertTrue(try XCTUnwrap(windowLevel.longPressMenu?.items.first { $0.id == "2d-window-brain" }).isSelected)
        XCTAssertTrue(try XCTUnwrap(windowLevel.longPressMenu?.items.first { $0.id == "2d-window-invert" }).isSelected)
        XCTAssertEqual(windowLevel.longPressMenu?.sections.map(\.title), ["CLUTs"])
        XCTAssertEqual(windowLevel.longPressMenu?.sections.first?.items.map(\.id), [
            "2d-clut-grayscale",
            "2d-clut-invertedGrayscale"
        ])
        XCTAssertTrue(try XCTUnwrap(windowLevel.longPressMenu?.sections.first?.items.first { $0.id == "2d-clut-invertedGrayscale" }).isSelected)
        XCTAssertEqual(rotation.longPressMenu?.items.map(\.id), [
            "2d-rotation-cw",
            "2d-rotation-ccw",
            "2d-rotation-flip-horizontal",
            "2d-rotation-flip-vertical",
            "2d-rotation-reset",
            "2d-rotation-select"
        ])
        XCTAssertEqual(rotation.longPressMenu?.items.map(\.title), [
            "Rotate 90° CW",
            "Rotate 90° CCW",
            "Flip Horizontal",
            "Flip Vertical",
            "Reset",
            "Select Rotation tool"
        ])
        XCTAssertEqual(rotation.longPressMenu?.items.map(\.action), [
            .rotate2DByDegrees(90),
            .rotate2DByDegrees(-90),
            .flip2DHorizontal,
            .flip2DVertical,
            .reset2DTransform,
            .selectTool(.rotation)
        ])
        XCTAssertEqual(rotation.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuRotation")
        XCTAssertEqual(roi.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuROI")
        XCTAssertEqual(roi.longPressMenu?.items.map(\.id), [
            "2d-roi-distance",
            "2d-roi-angle",
            "2d-roi-cobb-angle",
            "2d-roi-point",
            "2d-roi-area",
            "2d-roi-ellipse",
            "2d-roi-closed-path",
            "2d-roi-curved-line",
            "2d-roi-text",
            "2d-roi-arrow",
            "2d-roi-scribble",
            "2d-roi-volume",
            "2d-roi-ctr",
            "2d-roi-delete-view",
            "2d-roi-delete-series"
        ])
        XCTAssertTrue(try XCTUnwrap(roi.longPressMenu?.items.first { $0.id == "2d-roi-arrow" }).isSelected)
        XCTAssertFalse(try XCTUnwrap(roi.longPressMenu?.items.first { $0.id == "2d-roi-volume" }).isEnabled)
        XCTAssertEqual(sync.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuSync")
        XCTAssertEqual(sync.longPressMenu?.items.map(\.id), [
            "2d-sync-transform",
            "2d-sync-window",
            "2d-sync-location",
            "2d-sync-same-study"
        ])
        XCTAssertEqual(sync.longPressMenu?.items.map(\.action), [
            .set2DSyncOption(.transforms, false),
            .set2DSyncOption(.windowLevel, false),
            .set2DSyncOption(.location, true),
            .set2DSyncOption(.sameStudy, false)
        ])
        XCTAssertTrue(try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-transform" }).isSelected)
        XCTAssertTrue(try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-window" }).isSelected)
        XCTAssertTrue(try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-same-study" }).isSelected)
        XCTAssertFalse(try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-location" }).isEnabled)
        XCTAssertEqual(reslice.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuReslice")
        XCTAssertEqual(reslice.longPressMenu?.items.map(\.id), [
            "2d-reslice-sagittal",
            "2d-reslice-coronal",
            "2d-reslice-axial"
        ])
        XCTAssertEqual(reslice.longPressMenu?.items.map(\.action), [
            .set2DResliceAxis(.sagittal),
            .set2DResliceAxis(.coronal),
            .set2DResliceAxis(.axial)
        ])
        XCTAssertTrue(try XCTUnwrap(reslice.longPressMenu?.items.first { $0.id == "2d-reslice-sagittal" }).isSelected)
    }

    func testStack2DSyncMenuEnablesLocationSyncWhenCapabilityAllowsIt() throws {
        let configuration = factory.configuration(
            for: .stack2D,
            twoDSyncState: ViewerSyncState(syncTransforms: true,
                                           syncWindowLevel: true,
                                           syncLocation: true,
                                           syncSameStudy: true),
            isTwoDLocationSyncEnabled: true
        )
        let sync = try XCTUnwrap(configuration.bottomTools.first { $0.id == .sync })
        let location = try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-location" })

        XCTAssertEqual(location.action, .set2DSyncOption(.location, false))
        XCTAssertTrue(location.isEnabled)
        XCTAssertTrue(location.isSelected)
        XCTAssertEqual(location.systemImage, "checkmark")
    }

    func testMPR3DAndFuture2DChromeConfigurationsStayIndependent() {
        let single3D = factory.configuration(for: .single3D)
        let mpr = factory.configuration(for: .clinical)
        let stack2D = factory.configuration(for: .stack2D)

        XCTAssertEqual(single3D.optionsAction, .openMenu(.volume3DOptions))
        XCTAssertNotNil(single3D.optionsMenu)
        XCTAssertEqual(mpr.optionsAction, .openMenu(.mprOptions))
        XCTAssertNotNil(mpr.optionsMenu)
        XCTAssertEqual(stack2D.optionsAction, .openMenu(.stack2DOptions))
        XCTAssertNotNil(stack2D.optionsMenu)

        XCTAssertEqual(single3D.bottomTools.map(\.id), Volume3DTool.allCases.map(\.viewerToolID))
        XCTAssertEqual(mpr.bottomTools.map(\.id), MPRTool.allCases.map(\.viewerToolID))
        XCTAssertNotEqual(mpr.bottomTools.map(\.id), stack2D.bottomTools.map(\.id))
    }

    func testChromeStateClearsTransientStateWhenModeChanges() {
        let single3D = factory.configuration(for: .single3D)
        let mpr = factory.configuration(for: .clinical)
        var state = ViewerChromeState()

        state.prepareForMode(.single3D, configuration: single3D)
        state.toggleOptions(single3D.optionsAction, in: single3D)
        state.toggleMenu(for: single3D.bottomTools[0], in: single3D)
        state.activateTool(single3D.bottomTools[3], in: single3D)

        XCTAssertEqual(state.activeOverlay, .crop3D)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)

        state.prepareForMode(.clinical, configuration: mpr)

        XCTAssertNil(state.activeToolMenu)
        XCTAssertNil(state.activeSettingsSheet)
        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertNil(state.activeOverlay)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
        XCTAssertEqual(state.selectedToolID(for: .clinical), .scroll)
    }

    func testDismissingVolumeRenderSettingsPreservesSelected3DTool() throws {
        let configuration = factory.configuration(for: .single3D)
        let settings = try XCTUnwrap(configuration.optionsMenu?.items.first { $0.id == "3d-options-vr-settings" })
        var state = ViewerChromeState()

        state.prepareForMode(.single3D, configuration: configuration)
        state.activateTool(configuration.bottomTools[3], in: configuration)
        state.toggleOptions(configuration.optionsAction, in: configuration)
        state.activateMenuItem(settings, in: configuration)
        state.dismissPresentedChrome()

        XCTAssertNil(state.activeSettingsSheet)
        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
    }

    func testMPROptionsTerminalItemsDismissDedicatedMenu() throws {
        let configuration = factory.configuration(for: .clinical)
        let resetViews = try XCTUnwrap(configuration.optionsMenu?.items.first { $0.id == "mpr-options-reset-views" })
        var state = ViewerChromeState()

        state.prepareForMode(.clinical, configuration: configuration)
        state.toggleOptions(configuration.optionsAction, in: configuration)

        XCTAssertEqual(state.activeOptionsMenu, .mprOptions)
        XCTAssertNil(state.activeSettingsSheet)

        state.activateMenuItem(resetViews, in: configuration)

        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertNil(state.activeSettingsSheet)
        XCTAssertEqual(state.selectedToolID(for: .clinical), .scroll)
    }

    func testStack2DOptionsTerminalItemsDismissDedicatedMenu() throws {
        let configuration = factory.configuration(for: .stack2D)
        let annotations = try XCTUnwrap(configuration.optionsMenu?.items.first { $0.id == "2d-options-image-annotations" })
        var state = ViewerChromeState()

        state.prepareForMode(.stack2D, configuration: configuration)
        state.toggleOptions(configuration.optionsAction, in: configuration)

        XCTAssertEqual(state.activeOptionsMenu, .stack2DOptions)
        XCTAssertNil(state.activeSettingsSheet)

        state.activateMenuItem(annotations, in: configuration)

        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertNil(state.activeSettingsSheet)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .scroll)
    }

    func testStack2DMenuActionsSelectModeScopedTools() throws {
        let configuration = factory.configuration(for: .stack2D)
        let scroll = try XCTUnwrap(configuration.bottomTools.first { $0.id == .scroll })
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let roi = try XCTUnwrap(configuration.bottomTools.first { $0.id == .roi })
        let sync = try XCTUnwrap(configuration.bottomTools.first { $0.id == .sync })
        let reslice = try XCTUnwrap(configuration.bottomTools.first { $0.id == .reslice })
        var state = ViewerChromeState()

        state.prepareForMode(.stack2D, configuration: configuration)
        state.activateMenuItem(try XCTUnwrap(scroll.longPressMenu?.sections.first?.items.first { $0.id == "2d-scroll-speed-fast" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .scroll)
        XCTAssertNil(state.activeToolMenu)

        state.toggleMenu(for: windowLevel, in: configuration)
        XCTAssertEqual(state.activeToolMenu, .windowLevel)
        state.activateMenuItem(try XCTUnwrap(windowLevel.longPressMenu?.items.first { $0.id == "2d-window-brain" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .windowLevel)
        XCTAssertNil(state.activeToolMenu)

        state.activateMenuItem(try XCTUnwrap(windowLevel.longPressMenu?.items.first { $0.id == "2d-window-manual" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .windowLevel)
        XCTAssertEqual(state.activeSettingsSheet, .stack2DWindowLevelManual)

        state.activateMenuItem(try XCTUnwrap(roi.longPressMenu?.items.first { $0.id == "2d-roi-arrow" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .roi)

        state.activateMenuItem(try XCTUnwrap(sync.longPressMenu?.items.first { $0.id == "2d-sync-same-study" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .sync)

        state.activateMenuItem(try XCTUnwrap(reslice.longPressMenu?.items.first { $0.id == "2d-reslice-coronal" }),
                               in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .reslice)
    }

    func testStack2DResliceToolCanBeDisabledForNonVolumetricDatasets() throws {
        let configuration = factory.configuration(
            for: .stack2D,
            selectedToolID: .reslice,
            isTwoDResliceEnabled: false,
            twoDResliceDisabledMessage: "2D reslice requires a volumetric dataset."
        )
        let reslice = try XCTUnwrap(configuration.bottomTools.first { $0.id == .reslice })
        var state = ViewerChromeState()

        XCTAssertFalse(reslice.isEnabled)
        XCTAssertEqual(reslice.disabledMessage, "2D reslice requires a volumetric dataset.")
        XCTAssertEqual(configuration.defaultToolID, .scroll)

        state.prepareForMode(.stack2D, configuration: configuration)
        state.activateTool(reslice, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .scroll)

        state.toggleMenu(for: reslice, in: configuration)
        XCTAssertNil(state.activeToolMenu)
        XCTAssertTrue(reslice.longPressMenu?.items.allSatisfy { !$0.isEnabled } == true)
    }

    func testStack2DThickSlabToolCanBeDisabledForSingleSliceStacks() throws {
        let message = "Thick Slab requires a stack with adjacent slices."
        let configuration = factory.configuration(
            for: .stack2D,
            selectedToolID: .thickSlab,
            isTwoDThickSlabEnabled: false,
            twoDThickSlabDisabledMessage: message
        )
        let thickSlab = try XCTUnwrap(configuration.bottomTools.first { $0.id == .thickSlab })
        var state = ViewerChromeState()

        XCTAssertFalse(thickSlab.isEnabled)
        XCTAssertEqual(thickSlab.disabledMessage, message)
        XCTAssertEqual(thickSlab.tapAction, .openSettings(.stack2DThickSlab))
        XCTAssertEqual(configuration.defaultToolID, .scroll)

        state.prepareForMode(.stack2D, configuration: configuration)
        state.activateTool(thickSlab, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .stack2D), .scroll)
        XCTAssertNil(state.activeSettingsSheet)
    }

    func testStack2DScrollMenuReflectsScrollSettings() throws {
        let settings = TwoDScrollSettings(speed: TwoDScrollSpeedPreset.fast.speed,
                                          loopThroughImages: true,
                                          sortMode: .fileOrder,
                                          showsOnScreenControls: true)
        let configuration = factory.configuration(for: .stack2D,
                                                  twoDScrollSettings: settings)
        let scroll = try XCTUnwrap(configuration.bottomTools.first { $0.id == .scroll })
        let speedItems = try XCTUnwrap(scroll.longPressMenu?.sections.first?.items)
        let sortItems = try XCTUnwrap(scroll.longPressMenu?.sections.last?.items)

        XCTAssertEqual(scroll.longPressMenu?.accessibilityIdentifier, "MTK2DToolMenuScroll")
        XCTAssertTrue(try XCTUnwrap(speedItems.first { $0.id == "2d-scroll-speed-fast" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(speedItems.first { $0.id == "2d-scroll-speed-fast" }).action,
                       .set2DScrollSpeed(TwoDScrollSpeedPreset.fast.speed))
        XCTAssertTrue(try XCTUnwrap(sortItems.first { $0.id == "2d-scroll-sort-fileOrder" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(sortItems.first { $0.id == "2d-scroll-sort-fileOrder" }).action,
                       .set2DImageSortMode(.fileOrder))
        XCTAssertTrue(try XCTUnwrap(scroll.longPressMenu?.items.first { $0.id == "2d-scroll-loop" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(scroll.longPressMenu?.items.first { $0.id == "2d-scroll-loop" }).action,
                       .set2DLoopThroughImages(false))
        XCTAssertTrue(try XCTUnwrap(scroll.longPressMenu?.items.first { $0.id == "2d-scroll-on-screen-controls" }).isSelected)
        XCTAssertEqual(try XCTUnwrap(scroll.longPressMenu?.items.first { $0.id == "2d-scroll-on-screen-controls" }).action,
                       .set2DOnScreenControls(false))
    }

    func testMPRLongPressMenuDoesNotTriggerShortTapSelection() throws {
        let configuration = factory.configuration(for: .clinical)
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let presetItem = try XCTUnwrap(windowLevel.longPressMenu?.items.first)
        var state = ViewerChromeState()

        state.prepareForMode(.clinical, configuration: configuration)
        state.toggleMenu(for: windowLevel, in: configuration)

        XCTAssertEqual(state.activeToolMenu, .windowLevel)
        XCTAssertEqual(state.selectedToolID(for: .clinical), .scroll)

        state.activateMenuItem(presetItem, in: configuration)

        XCTAssertNil(state.activeToolMenu)
        XCTAssertEqual(state.selectedToolID(for: .clinical), .windowLevel)
    }

    func testMPRThickSlabToolOpensDedicatedSheet() throws {
        let configuration = factory.configuration(for: .clinical)
        let thickSlab = try XCTUnwrap(configuration.bottomTools.first { $0.id == .thickSlab })
        var state = ViewerChromeState()

        state.prepareForMode(.clinical, configuration: configuration)
        state.activateTool(thickSlab, in: configuration)

        XCTAssertEqual(state.selectedToolID(for: .clinical), .thickSlab)
        XCTAssertEqual(state.activeSettingsSheet, .mprThickSlab)
        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertNil(state.activeToolMenu)
    }

    func testStack2DThickSlabToolOpensDedicatedSheet() throws {
        let configuration = factory.configuration(for: .stack2D)
        let thickSlab = try XCTUnwrap(configuration.bottomTools.first { $0.id == .thickSlab })
        var state = ViewerChromeState()

        state.prepareForMode(.stack2D, configuration: configuration)
        state.activateTool(thickSlab, in: configuration)

        XCTAssertEqual(state.selectedToolID(for: .stack2D), .thickSlab)
        XCTAssertEqual(state.activeSettingsSheet, .stack2DThickSlab)
        XCTAssertNil(state.activeOptionsMenu)
        XCTAssertNil(state.activeToolMenu)
    }

    func testLongPressMenusAreDataDriven() throws {
        let configuration = factory.configuration(for: .single3D)
        let orientation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .orientation })
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let rotation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .rotation })
        let crop = try XCTUnwrap(configuration.bottomTools.first { $0.id == .crop })
        let brush = try XCTUnwrap(configuration.bottomTools.first { $0.id == .brush })

        XCTAssertEqual(orientation.longPressMenu?.items.map(\.id), [
            "volume3d-orientation-anterior",
            "volume3d-orientation-posterior",
            "volume3d-orientation-superior",
            "volume3d-orientation-inferior",
            "volume3d-orientation-left",
            "volume3d-orientation-right",
            "volume3d-orientation-default",
            "volume3d-orientation-select"
        ])
        XCTAssertEqual(orientation.longPressMenu?.items.map(\.title), [
            "Anterior",
            "Posterior",
            "Superior",
            "Inferior",
            "Left",
            "Right",
            "Default orientation",
            "Select Orientation tool"
        ])
        XCTAssertEqual(windowLevel.longPressMenu?.items.map(\.title), [
            "Default",
            "Abdomen",
            "Bone",
            "Brain",
            "Lungs",
            "Endoscopy",
            "Other",
            "Select WW/WL tool"
        ])
        XCTAssertEqual(windowLevel.longPressMenu?.sections.map(\.title), ["CLUTs"])
        XCTAssertEqual(windowLevel.longPressMenu?.sections.first?.items.count, 29)
        XCTAssertEqual(rotation.longPressMenu?.title, "Tilt")
        XCTAssertEqual(rotation.longPressMenu?.items.map(\.id), [
            "volume3d-rotation-model",
            "volume3d-rotation-cropBox",
            "volume3d-rotation-reset",
            "volume3d-rotation-select-crop"
        ])
        XCTAssertEqual(rotation.longPressMenu?.items.map(\.title), [
            "Model tilt",
            "Cropping box tilt",
            "Reset",
            "Select Crop tool"
        ])
        XCTAssertEqual(crop.longPressMenu?.items.map(\.id), [
            "volume3d-crop-reset",
            "volume3d-crop-select"
        ])
        XCTAssertEqual(crop.longPressMenu?.items.map(\.title), [
            "Reset",
            "Select Crop tool"
        ])
        XCTAssertEqual(brush.longPressMenu?.title, "Brush size (40 mm)")
        XCTAssertEqual(brush.longPressMenu?.items.map(\.id), [
            "volume3d-brush-size-decrease",
            "volume3d-brush-size-increase",
            "volume3d-brush-mode-erase",
            "volume3d-brush-mode-restore",
            "volume3d-brush-reset-volume",
            "volume3d-brush-select"
        ])
        XCTAssertEqual(brush.longPressMenu?.items.map(\.title), [
            "Smaller",
            "Larger",
            "Erase",
            "Restore",
            "Reset volume",
            "Select Brush tool"
        ])
    }

    func testOrientationMenuActionsSelectOrientationToolInChromeState() throws {
        let configuration = factory.configuration(for: .single3D)
        let orientation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .orientation })
        let orientationItem = try XCTUnwrap(orientation.longPressMenu?.items.first)
        let resetItem = try XCTUnwrap(orientation.longPressMenu?.items.first { $0.id == "volume3d-orientation-default" })
        var state = ViewerChromeState()

        state.activateTool(configuration.bottomTools[2], in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .rotation)

        state.activateMenuItem(orientationItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .orientation)

        state.activateTool(configuration.bottomTools[2], in: configuration)
        state.activateMenuItem(resetItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .orientation)
    }

    func testWindowLevelMenuActionsSelectWindowLevelToolInChromeState() throws {
        let configuration = factory.configuration(for: .single3D)
        let windowLevel = try XCTUnwrap(configuration.bottomTools.first { $0.id == .windowLevel })
        let presetItem = try XCTUnwrap(windowLevel.longPressMenu?.items.first)
        let clutItem = try XCTUnwrap(windowLevel.longPressMenu?.sections.first?.items.first)
        var state = ViewerChromeState()

        state.activateTool(configuration.bottomTools[2], in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .rotation)

        state.activateMenuItem(presetItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .windowLevel)

        state.activateTool(configuration.bottomTools[2], in: configuration)
        state.activateMenuItem(clutItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .windowLevel)
    }

    func testTiltMenuActionsSelectTiltToolAndCropShortcut() throws {
        let configuration = factory.configuration(for: .single3D)
        let rotation = try XCTUnwrap(configuration.bottomTools.first { $0.id == .rotation })
        let modelItem = try XCTUnwrap(rotation.longPressMenu?.items.first { $0.id == "volume3d-rotation-model" })
        let cropBoxItem = try XCTUnwrap(rotation.longPressMenu?.items.first { $0.id == "volume3d-rotation-cropBox" })
        let resetItem = try XCTUnwrap(rotation.longPressMenu?.items.first { $0.id == "volume3d-rotation-reset" })
        let selectCropItem = try XCTUnwrap(rotation.longPressMenu?.items.first { $0.id == "volume3d-rotation-select-crop" })
        var state = ViewerChromeState()

        XCTAssertEqual(modelItem.systemImage, "checkmark")
        XCTAssertTrue(modelItem.isEnabled)
        XCTAssertNil(cropBoxItem.systemImage)
        XCTAssertFalse(cropBoxItem.isEnabled)

        state.activateTool(configuration.bottomTools[1], in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .windowLevel)

        state.activateMenuItem(cropBoxItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .windowLevel)

        state.activateMenuItem(modelItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .rotation)

        state.activateTool(configuration.bottomTools[1], in: configuration)
        state.activateMenuItem(resetItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .rotation)

        state.activateMenuItem(selectCropItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
        XCTAssertNil(state.activeOverlay)
    }

    func testCropMenuResetSelectsCropToolAndClearsOverlayState() throws {
        let configuration = factory.configuration(for: .single3D)
        let crop = try XCTUnwrap(configuration.bottomTools.first { $0.id == .crop })
        let resetItem = try XCTUnwrap(crop.longPressMenu?.items.first { $0.id == "volume3d-crop-reset" })
        let selectItem = try XCTUnwrap(crop.longPressMenu?.items.first { $0.id == "volume3d-crop-select" })
        var state = ViewerChromeState()

        state.activateTool(configuration.bottomTools[3], in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
        XCTAssertEqual(state.activeOverlay, .crop3D)

        state.activateMenuItem(resetItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
        XCTAssertNil(state.activeOverlay)

        state.activateTool(configuration.bottomTools[1], in: configuration)
        state.activateMenuItem(selectItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .crop)
        XCTAssertNil(state.activeOverlay)
    }

    func testBrushMenuActionsSelectBrushToolAndClearOverlayState() throws {
        let configuration = factory.configuration(for: .single3D)
        let brush = try XCTUnwrap(configuration.bottomTools.first { $0.id == .brush })
        let sizeItem = try XCTUnwrap(brush.longPressMenu?.items.first { $0.id == "volume3d-brush-size-increase" })
        let modeItem = try XCTUnwrap(brush.longPressMenu?.items.first { $0.id == "volume3d-brush-mode-restore" })
        let resetItem = try XCTUnwrap(brush.longPressMenu?.items.first { $0.id == "volume3d-brush-reset-volume" })
        let selectItem = try XCTUnwrap(brush.longPressMenu?.items.first { $0.id == "volume3d-brush-select" })
        var state = ViewerChromeState()

        state.activateTool(configuration.bottomTools[4], in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .brush)
        XCTAssertEqual(state.activeOverlay, .brush3D)

        state.activateMenuItem(sizeItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .brush)
        XCTAssertNil(state.activeOverlay)

        state.activateMenuItem(modeItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .brush)
        XCTAssertNil(state.activeOverlay)

        state.activateMenuItem(resetItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .brush)
        XCTAssertNil(state.activeOverlay)

        state.activateTool(configuration.bottomTools[1], in: configuration)
        state.activateMenuItem(selectItem, in: configuration)
        XCTAssertEqual(state.selectedToolID(for: .single3D), .brush)
        XCTAssertNil(state.activeOverlay)
    }
}
