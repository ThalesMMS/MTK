import Foundation
import MTKCore

public enum ClinicalViewerMode: String, CaseIterable, Identifiable, Sendable {
    case single3D
    case clinical

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .single3D:
            return "3D"
        case .clinical:
            return "MPR"
        }
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
