import CoreGraphics
import Foundation
import MTKCore
import simd

public enum ClinicalViewerMode: String, CaseIterable, Identifiable, Sendable {
    case single3D
    case clinical
    case stack2D

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .single3D:
            return "3D"
        case .clinical:
            return "MPR"
        case .stack2D:
            return "2D"
        }
    }
}

public enum Clinical2DTool: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case windowLevel
    case rotation
    case roi
    case sync
    case reslice
    case thickSlab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scroll:
            return "Scroll"
        case .windowLevel:
            return "WW/WL"
        case .rotation:
            return "Rotation"
        case .roi:
            return "ROI"
        case .sync:
            return "Sync"
        case .reslice:
            return "Reslice"
        case .thickSlab:
            return "Thick Slab"
        }
    }
}

public enum TwoDScreenLayout: String, CaseIterable, Identifiable, Sendable {
    case singleWindow
    case dual2x1
    case triple3x1
    case quadruple2x2

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .singleWindow:
            return "Single Window"
        case .dual2x1:
            return "Dual (2x1)"
        case .triple3x1:
            return "Triple (3x1)"
        case .quadruple2x2:
            return "Quadruple (2x2)"
        }
    }

    public var accessibilityIdentifier: String {
        "TwoDScreenLayout.\(rawValue)"
    }
}

public enum ThickSlabThicknessFormatter {
    public static func label(thickness: Double, spacingMillimeters: Double?) -> String {
        let resolvedThickness = thickness.isFinite ? max(thickness, 1) : 1
        if let spacingMillimeters,
           spacingMillimeters.isFinite,
           spacingMillimeters > 0 {
            return String(format: "%.2f mm", resolvedThickness * spacingMillimeters)
        }
        let slices = max(Int(resolvedThickness.rounded()), 1)
        return slices == 1 ? "1 slice" : "\(slices) slices"
    }
}

public enum TwoDImageSortMode: String, CaseIterable, Identifiable, Sendable {
    case instancePosition
    case instanceNumber
    case acquisitionTime
    case fileOrder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .instancePosition:
            return "Image position"
        case .instanceNumber:
            return "Instance number"
        case .acquisitionTime:
            return "Acquisition time"
        case .fileOrder:
            return "File order"
        }
    }
}

public enum TwoDScrollSpeedPreset: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .slow:
            return "Slow"
        case .normal:
            return "Normal"
        case .fast:
            return "Fast"
        }
    }

    public var speed: Double {
        switch self {
        case .slow:
            return 0.5
        case .normal:
            return 1.0
        case .fast:
            return 2.0
        }
    }
}

public struct TwoDScrollSettings: Equatable, Sendable {
    public var speed: Double
    public var loopThroughImages: Bool
    public var sortMode: TwoDImageSortMode
    public var showsOnScreenControls: Bool

    public init(speed: Double = 1.0,
                loopThroughImages: Bool = false,
                sortMode: TwoDImageSortMode = .instancePosition,
                showsOnScreenControls: Bool = false) {
        self.speed = speed.isFinite ? max(speed, 0.1) : 1.0
        self.loopThroughImages = loopThroughImages
        self.sortMode = sortMode
        self.showsOnScreenControls = showsOnScreenControls
    }

    public static let `default` = TwoDScrollSettings()

    public var dragPixelsPerStep: CGFloat {
        CGFloat(10.0 / max(speed, 0.1))
    }

    public var selectedSpeedPreset: TwoDScrollSpeedPreset? {
        TwoDScrollSpeedPreset.allCases.first { abs($0.speed - speed) < 0.0001 }
    }
}

public enum Clinical2DCLUT: String, CaseIterable, Identifiable, Sendable {
    case grayscale
    case invertedGrayscale

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grayscale:
            return "Grayscale"
        case .invertedGrayscale:
            return "Inverted grayscale"
        }
    }

    public var invertsBaseLuminance: Bool {
        self == .invertedGrayscale
    }
}

public struct TwoDWindowLevelState: Equatable, Sendable {
    public var window: Double
    public var level: Double
    public var presetID: String?
    public var isInverted: Bool
    public var clut: Clinical2DCLUT

    public init(window: Double = 400,
                level: Double = 40,
                presetID: String? = Volume3DWindowPreset.default.rawValue,
                isInverted: Bool = false,
                clut: Clinical2DCLUT = .grayscale) {
        self.window = window.isFinite ? max(window, 1) : 400
        self.level = level.isFinite ? level : 40
        self.presetID = presetID
        self.isInverted = isInverted
        self.clut = clut
    }

    public static let `default` = TwoDWindowLevelState()

    public var windowLevel: WindowLevelShift {
        WindowLevelShift(window: window, level: level)
    }

    public var selectedWindowPreset: Volume3DWindowPreset {
        guard let presetID,
              let preset = Volume3DWindowPreset(rawValue: presetID) else {
            return .other
        }
        return preset
    }

    public var effectivePresentationInversion: Bool {
        isInverted != clut.invertsBaseLuminance
    }

    public func applying(window: Double,
                         level: Double,
                         presetID: String?) -> TwoDWindowLevelState? {
        guard Self.isValidManualWindowLevel(window: window, level: level) else {
            return nil
        }
        return TwoDWindowLevelState(window: window,
                                    level: level,
                                    presetID: presetID,
                                    isInverted: isInverted,
                                    clut: clut)
    }

    public static func isValidManualWindowLevel(window: Double,
                                                level: Double) -> Bool {
        window.isFinite && level.isFinite && window >= 1
    }
}

public struct Viewer2DTransform: Equatable, Sendable {
    public var zoom: Double
    public var pan: SIMD2<Double>
    public var rotationRadians: Double
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool

    public init(zoom: Double = 1,
                pan: SIMD2<Double> = .zero,
                rotationRadians: Double = 0,
                isFlippedHorizontally: Bool = false,
                isFlippedVertically: Bool = false) {
        self.zoom = zoom
        self.pan = pan
        self.rotationRadians = rotationRadians
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
    }

    public static let identity = Viewer2DTransform()

    public var rotationDegrees: Double {
        get { rotationRadians * 180.0 / .pi }
        set { rotationRadians = newValue * .pi / 180.0 }
    }
}

public enum MPRScreenLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case hSplit2x1
    case hSplit1x2
    case vSplit3x1

    public var id: String { rawValue }

    public static let defaultLayout: MPRScreenLayout = .hSplit1x2

    public var title: String {
        switch self {
        case .hSplit2x1:
            return "Two Over One (2x1)"
        case .hSplit1x2:
            return "One Over Two (1x2)"
        case .vSplit3x1:
            return "Three Stacked (3x1)"
        }
    }

    public var accessibilityIdentifier: String {
        "MPRScreenLayout.\(rawValue)"
    }
}

public enum ClinicalViewerTransferQuickPreset: String, CaseIterable, Identifiable, Sendable {
    case softTissue
    case bone
    case lung
    case brain
    case abdomen
    case vascular
    case vrBone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .softTissue:
            return "Soft Tissue"
        case .bone:
            return "Bone"
        case .lung:
            return "Lung"
        case .brain:
            return "Brain"
        case .abdomen:
            return "Abdomen"
        case .vascular:
            return "Vascular"
        case .vrBone:
            return "VR Bone"
        }
    }

    public var systemImage: String {
        switch self {
        case .softTissue:
            return "figure.stand"
        case .bone:
            return "figure.walk"
        case .lung:
            return "lungs"
        case .brain:
            return "brain.head.profile"
        case .abdomen:
            return "cross.vial"
        case .vascular:
            return "waveform.path.ecg"
        case .vrBone:
            return "cube.transparent"
        }
    }

    public var preset: ClinicalTransferFunctionPreset {
        switch self {
        case .softTissue:
            return .ctSoftTissue
        case .bone:
            return .ctBone
        case .lung:
            return .ctLung
        case .brain:
            return .ctBrain
        case .abdomen:
            return .ctAbdomen
        case .vascular:
            return .ctVascular
        case .vrBone:
            return .ctVRBone
        }
    }
}

public enum ClinicalViewerWindowQuickPreset: String, CaseIterable, Identifiable, Sendable {
    case softTissue
    case brain
    case lung
    case bone
    case abdomen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .softTissue:
            return "Soft Tissue"
        case .brain:
            return "Brain"
        case .lung:
            return "Lung"
        case .bone:
            return "Bone"
        case .abdomen:
            return "Abdomen"
        }
    }

    public var systemImage: String {
        switch self {
        case .softTissue:
            return "figure.stand"
        case .brain:
            return "brain.head.profile"
        case .lung:
            return "lungs"
        case .bone:
            return "figure.walk"
        case .abdomen:
            return "cross.vial"
        }
    }

    public var windowLevelPreset: WindowLevelPreset {
        switch self {
        case .softTissue:
            return WindowLevelPresetLibrary.softTissue
        case .brain:
            return WindowLevelPresetLibrary.brain
        case .lung:
            return WindowLevelPresetLibrary.lung
        case .bone:
            return WindowLevelPresetLibrary.bone
        case .abdomen:
            return WindowLevelPresetLibrary.ct.first { $0.id == "weasis.ct-abdomen" } ?? WindowLevelPresetLibrary.softTissue
        }
    }
}

public enum ClinicalViewerCropAxis: String, CaseIterable, Identifiable, Sendable {
    case x
    case y
    case z

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.uppercased()
    }
}

public extension Axis {
    var clinicalDisplayName: String {
        switch self {
        case .axial:
            return "Axial"
        case .coronal:
            return "Coronal"
        case .sagittal:
            return "Sagittal"
        }
    }
}
