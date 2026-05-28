import Foundation
import MTKCore
import simd

public enum Volume3DAnatomicalOrientation: String, CaseIterable, Equatable, Identifiable, Sendable {
    case anterior
    case posterior
    case superior
    case inferior
    case left
    case right

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anterior:
            return "Anterior"
        case .posterior:
            return "Posterior"
        case .superior:
            return "Superior"
        case .inferior:
            return "Inferior"
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }

    public var anatomicalLabel: AnatomicalAxisLabel {
        switch self {
        case .anterior:
            return .anterior
        case .posterior:
            return .posterior
        case .superior:
            return .superior
        case .inferior:
            return .inferior
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    public var lpsDirection: SIMD3<Float> {
        Self.lpsDirection(for: anatomicalLabel)
    }

    public var preferredUpLPSDirection: SIMD3<Float> {
        switch self {
        case .superior, .inferior:
            return Self.lpsDirection(for: .anterior)
        case .anterior, .posterior, .left, .right:
            return Self.lpsDirection(for: .superior)
        }
    }

    public func cameraAxes(for dataset: VolumeDataset) -> (normal: SIMD3<Float>, up: SIMD3<Float>) {
        let renderGeometry = VolumeRenderGeometry.make(for: dataset)
        return (
            normal: renderGeometry.textureDirection(forWorldDirection: lpsDirection),
            up: renderGeometry.textureDirection(forWorldDirection: preferredUpLPSDirection)
        )
    }

    private static func lpsDirection(for label: AnatomicalAxisLabel) -> SIMD3<Float> {
        var direction = SIMD3<Float>.zero
        direction[label.lpsAxis] = label.isPositiveLPS ? 1 : -1
        return direction
    }
}

public enum Volume3DOrientationMenu {
    public static var menu: ViewerToolMenu {
        ViewerToolMenu(
            title: "Orientation",
            items: Volume3DAnatomicalOrientation.allCases.map(menuItem)
                + [
                    ViewerToolMenuItem(id: "volume3d-orientation-default",
                                       title: "Default orientation",
                                       systemImage: "arrow.counterclockwise",
                                       action: .reset3DOrientation),
                    ViewerToolMenuItem(id: "volume3d-orientation-select",
                                       title: "Select Orientation tool",
                                       systemImage: "viewfinder",
                                       action: .selectTool(.orientation))
                ]
        )
    }

    private static func menuItem(for orientation: Volume3DAnatomicalOrientation) -> ViewerToolMenuItem {
        ViewerToolMenuItem(id: "volume3d-orientation-\(orientation.rawValue)",
                           title: orientation.title,
                           systemImage: nil,
                           action: .set3DOrientation(orientation))
    }
}
