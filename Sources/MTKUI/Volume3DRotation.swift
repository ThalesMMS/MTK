import Foundation

public enum Volume3DRotationTarget: String, CaseIterable, Identifiable, Sendable {
    case model
    case cropBox

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .model:
            return "Model rotation"
        case .cropBox:
            return "Cropping box rotation"
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .model:
            return true
        case .cropBox:
            return false
        }
    }
}

public enum Volume3DRotationToolMenu {
    public static func menu(selectedTarget: Volume3DRotationTarget = .model) -> ViewerToolMenu {
        ViewerToolMenu(title: "Rotation", items: [
            targetItem(for: .model, selectedTarget: selectedTarget),
            targetItem(for: .cropBox, selectedTarget: selectedTarget),
            ViewerToolMenuItem(id: "volume3d-rotation-reset",
                               title: "Reset",
                               systemImage: "arrow.counterclockwise",
                               action: .reset3DRotation),
            ViewerToolMenuItem(id: "volume3d-rotation-select-crop",
                               title: "Select Crop tool",
                               systemImage: "crop",
                               action: .selectTool(.crop))
        ])
    }

    private static func targetItem(for target: Volume3DRotationTarget,
                                   selectedTarget: Volume3DRotationTarget) -> ViewerToolMenuItem {
        ViewerToolMenuItem(id: "volume3d-rotation-\(target.rawValue)",
                           title: target.displayName,
                           systemImage: target == selectedTarget ? "checkmark" : nil,
                           action: .set3DRotationTarget(target),
                           isEnabled: target.isEnabled)
    }
}
