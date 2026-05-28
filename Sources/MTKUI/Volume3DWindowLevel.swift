import Foundation
import MTKCore

public enum Volume3DWindowPreset: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case abdomen
    case bone
    case brain
    case lungs
    case endoscopy
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
        case .endoscopy:
            return "Endoscopy"
        case .other:
            return "Other"
        }
    }

    public var clinicalTransferFunctionPreset: ClinicalTransferFunctionPreset {
        switch self {
        case .default, .other:
            return .ctSoftTissue
        case .abdomen:
            return .ctAbdomen
        case .bone:
            return .ctBone
        case .brain:
            return .ctBrain
        case .lungs:
            return .ctLung
        case .endoscopy:
            return .ctVRBone
        }
    }

    public var windowLevelPreset: WindowLevelPreset? {
        switch self {
        case .default, .other:
            return nil
        case .abdomen:
            return WindowLevelPresetLibrary.preset(withId: "weasis.ct-abdomen") ?? WindowLevelPresetLibrary.softTissue
        case .bone:
            return WindowLevelPresetLibrary.bone
        case .brain:
            return WindowLevelPresetLibrary.brain
        case .lungs:
            return WindowLevelPresetLibrary.lung
        case .endoscopy:
            return WindowLevelPresetLibrary.bone
        }
    }

    public var usesPlaceholderMapping: Bool {
        switch self {
        case .other:
            return true
        case .default, .abdomen, .bone, .brain, .lungs, .endoscopy:
            return false
        }
    }

    public static func preset(for transferPreset: ClinicalTransferFunctionPreset) -> Volume3DWindowPreset {
        switch transferPreset {
        case .ctSoftTissue:
            return .default
        case .ctAbdomen:
            return .abdomen
        case .ctBone:
            return .bone
        case .ctBrain:
            return .brain
        case .ctLung, .ctMinIPLung:
            return .lungs
        case .ctVRBone:
            return .endoscopy
        case .ctVascular, .ctPulmonaryArteries, .ctAngioMIP, .mrAngioMIP:
            return .other
        }
    }
}

public struct Volume3DCLUTPreset: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case currentTransferFunction
        case generatedPalette([TransferFunction.RGBAColor])
    }

    public let id: String
    public let displayName: String
    public let source: Source

    public init(id: String,
                displayName: String,
                source: Source) {
        self.id = id
        self.displayName = displayName
        self.source = source
    }

    public func transferFunction(basedOn base: TransferFunction) -> TransferFunction {
        switch source {
        case .currentTransferFunction:
            return base
        case .generatedPalette(let colors):
            guard colors.count >= 2 else { return base }
            var copy = base
            copy.name = base.name.isEmpty ? displayName : "\(base.name) \(displayName)"
            copy.colourPoints = Self.colourPoints(colors: colors,
                                                  minimumValue: base.minimumValue,
                                                  maximumValue: base.maximumValue)
            return copy
        }
    }

    public static let defaultPreset = Volume3DCLUTPreset(
        id: "default",
        displayName: "Default",
        source: .currentTransferFunction
    )

    public static let allPresets: [Volume3DCLUTPreset] = [
        defaultPreset,
        preset("system-clut", "System CLUT", [.black, .white]),
        preset("shades-of-gray", "Shades of Gray", [.black, .white]),
        preset("legacy", "Legacy", [.black, .warmGray, .boneWhite]),
        preset("looking-glass", "Looking Glass", [.black, .blue, .cyan, .white]),
        preset("thin-air", "Thin Air", [.black, .deepBlue, .cyan, .white]),
        preset("vessels-in-the-wind", "Vessels in the Wind", [.black, .darkRed, .orange, .yellowWhite]),
        preset("4colors", "4Colors", [.blue, .cyan, .yellow, .red]),
        preset("french", "French", [.blue, .white, .red]),
        preset("blue-skin", "Blue Skin", [.black, .deepBlue, .skin, .white]),
        preset("flow", "Flow", [.deepBlue, .cyan, .green, .yellow]),
        preset("gelight", "Amber Light", [.black, .purple, .orange, .white]),
        preset("redhot", "RedHot", [.black, .darkRed, .red, .yellowWhite]),
        preset("greenhue", "GreenHue", [.black, .green, .mint, .white]),
        preset("neon", "Neon", [.black, .purple, .cyan, .green]),
        preset("perfusion", "Perfusion", [.deepBlue, .cyan, .yellow, .red]),
        preset("brain", "Brain", [.black, .purple, .skin, .white]),
        preset("muscles-and-bones", "Muscles & Bones", [.darkRed, .skin, .boneWhite, .white]),
        preset("purple-dream", "Purple Dream", [.black, .purple, .pink, .white]),
        preset("rainbow-1", "Rainbow 1", [.blue, .cyan, .green, .yellow, .red]),
        preset("rainbow-2", "Rainbow 2", [.purple, .blue, .green, .orange, .red]),
        preset("rainbow-3", "Rainbow 3", [.black, .blue, .cyan, .yellowWhite, .red]),
        preset("red-vessels", "Red Vessels", [.black, .darkRed, .red, .white]),
        preset("retro", "Retro", [.black, .brown, .orange, .cream]),
        preset("transparent-1", "Transparent 1", [.black, .cyan, .white]),
        preset("transparent-2", "Transparent 2", [.black, .green, .white]),
        preset("r3volutiond", "R3volutionD", [.black, .blue, .purple, .red, .white]),
        preset("ua", "UA", [.deepBlue, .green, .orange, .white]),
        preset("calibration", "Calibration", [.black, .white, .black, .white])
    ]

    private static func preset(_ id: String,
                               _ displayName: String,
                               _ colors: [TransferFunction.RGBAColor]) -> Volume3DCLUTPreset {
        Volume3DCLUTPreset(id: id,
                           displayName: displayName,
                           source: .generatedPalette(colors))
    }

    private static func colourPoints(colors: [TransferFunction.RGBAColor],
                                     minimumValue: Float,
                                     maximumValue: Float) -> [TransferFunction.ColorPoint] {
        let span = maximumValue - minimumValue
        let denominator = max(colors.count - 1, 1)
        return colors.enumerated().map { index, color in
            let fraction = Float(index) / Float(denominator)
            return TransferFunction.ColorPoint(dataValue: minimumValue + span * fraction,
                                               colourValue: color)
        }
    }
}

public enum Volume3DWindowLevelToolMenu {
    public static func menu(selectedWindowPreset: Volume3DWindowPreset = .default,
                            selectedCLUTPreset: Volume3DCLUTPreset = .defaultPreset) -> ViewerToolMenu {
        var entries: [ViewerToolMenuEntry] = Volume3DWindowPreset.allCases.map { preset in
            .item(windowPresetItem(for: preset, selectedPreset: selectedWindowPreset))
        }
        entries.append(
            .section(
                ViewerToolMenuSection(
                    id: "volume3d-window-cluts",
                    title: "CLUTs",
                    maximumVisibleItems: 12,
                    items: Volume3DCLUTPreset.allPresets.map { preset in
                        clutItem(for: preset, selectedPreset: selectedCLUTPreset)
                    }
                )
            )
        )
        entries.append(
            .item(
                ViewerToolMenuItem(id: "volume3d-window-select",
                                   title: "Select WW/WL tool",
                                   systemImage: "sun.max",
                                   action: .selectTool(.windowLevel))
            )
        )
        return ViewerToolMenu(title: "WW/WL", entries: entries)
    }

    private static func windowPresetItem(for preset: Volume3DWindowPreset,
                                         selectedPreset: Volume3DWindowPreset) -> ViewerToolMenuItem {
        ViewerToolMenuItem(id: "volume3d-window-\(preset.rawValue)",
                           title: preset.displayName,
                           systemImage: preset == selectedPreset ? "checkmark" : nil,
                           action: .set3DWindowPreset(preset))
    }

    private static func clutItem(for preset: Volume3DCLUTPreset,
                                 selectedPreset: Volume3DCLUTPreset) -> ViewerToolMenuItem {
        ViewerToolMenuItem(id: "volume3d-clut-\(preset.id)",
                           title: preset.displayName,
                           systemImage: preset == selectedPreset ? "checkmark" : nil,
                           action: .set3DCLUTPreset(preset))
    }
}

private extension TransferFunction.RGBAColor {
    static let black = TransferFunction.RGBAColor(r: 0, g: 0, b: 0, a: 1)
    static let white = TransferFunction.RGBAColor(r: 1, g: 1, b: 1, a: 1)
    static let boneWhite = TransferFunction.RGBAColor(r: 0.92, g: 0.86, b: 0.72, a: 1)
    static let warmGray = TransferFunction.RGBAColor(r: 0.45, g: 0.42, b: 0.38, a: 1)
    static let cream = TransferFunction.RGBAColor(r: 0.88, g: 0.82, b: 0.65, a: 1)
    static let brown = TransferFunction.RGBAColor(r: 0.42, g: 0.24, b: 0.13, a: 1)
    static let skin = TransferFunction.RGBAColor(r: 0.88, g: 0.58, b: 0.42, a: 1)
    static let darkRed = TransferFunction.RGBAColor(r: 0.34, g: 0.02, b: 0.02, a: 1)
    static let red = TransferFunction.RGBAColor(r: 0.92, g: 0.05, b: 0.04, a: 1)
    static let orange = TransferFunction.RGBAColor(r: 0.95, g: 0.42, b: 0.08, a: 1)
    static let yellow = TransferFunction.RGBAColor(r: 0.96, g: 0.9, b: 0.12, a: 1)
    static let yellowWhite = TransferFunction.RGBAColor(r: 1, g: 0.94, b: 0.54, a: 1)
    static let green = TransferFunction.RGBAColor(r: 0.08, g: 0.75, b: 0.26, a: 1)
    static let mint = TransferFunction.RGBAColor(r: 0.58, g: 1, b: 0.76, a: 1)
    static let cyan = TransferFunction.RGBAColor(r: 0.05, g: 0.82, b: 0.95, a: 1)
    static let blue = TransferFunction.RGBAColor(r: 0.08, g: 0.22, b: 0.9, a: 1)
    static let deepBlue = TransferFunction.RGBAColor(r: 0.02, g: 0.05, b: 0.24, a: 1)
    static let purple = TransferFunction.RGBAColor(r: 0.46, g: 0.14, b: 0.78, a: 1)
    static let pink = TransferFunction.RGBAColor(r: 0.95, g: 0.28, b: 0.68, a: 1)
}
