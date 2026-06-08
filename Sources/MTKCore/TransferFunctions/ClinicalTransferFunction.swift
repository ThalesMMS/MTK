//
//  ClinicalTransferFunction.swift
//  MTKCore
//
//  Public clinical transfer-function metadata, rendering intent, and presets.
//

import Foundation
import simd

public enum ClinicalTransferFunctionModality: String, Codable, CaseIterable, Sendable {
    case ct
    case mr
    case unknown
}

public enum ClinicalTransferFunctionTissue: String, Codable, CaseIterable, Sendable {
    case general
    case lung
    case bone
    case softTissue
    case vascular
    case fat
    case cardiac
    case hepatic
    case neurological
}

public enum ClinicalTransferFunctionRenderMode: String, Codable, CaseIterable, Sendable {
    case dvr
    case mip
    case minip
    case aip

    public var compositing: VolumeRenderRequest.Compositing {
        switch self {
        case .dvr:
            return .frontToBack
        case .mip:
            return .maximumIntensity
        case .minip:
            return .minimumIntensity
        case .aip:
            return .averageIntensity
        }
    }
}

public struct TransferFunctionMetadata: Codable, Equatable, Sendable {
    public var identifier: String
    public var displayName: String
    public var modality: ClinicalTransferFunctionModality
    public var tissue: ClinicalTransferFunctionTissue
    public var clinicalUse: String?
    public var source: String?
    public var tags: [String]

    public init(identifier: String,
                displayName: String,
                modality: ClinicalTransferFunctionModality,
                tissue: ClinicalTransferFunctionTissue,
                clinicalUse: String? = nil,
                source: String? = nil,
                tags: [String] = []) {
        self.identifier = identifier
        self.displayName = displayName
        self.modality = modality
        self.tissue = tissue
        self.clinicalUse = clinicalUse
        self.source = source
        self.tags = tags
    }
}

public struct TransferFunctionRenderingIntent: Codable, Equatable, Sendable {
    public var mode: ClinicalTransferFunctionRenderMode
    public var lightingEnabled: Bool?
    public var projectionsUseTransferFunction: Bool?

    public init(mode: ClinicalTransferFunctionRenderMode,
                lightingEnabled: Bool? = nil,
                projectionsUseTransferFunction: Bool? = nil) {
        self.mode = mode
        self.lightingEnabled = lightingEnabled
        self.projectionsUseTransferFunction = projectionsUseTransferFunction
    }
}

public struct GradientOpacityFunction: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var gradientMagnitude: Float
        public var opacity: Float

        public init(gradientMagnitude: Float, opacity: Float) {
            self.gradientMagnitude = gradientMagnitude
            self.opacity = opacity
        }
    }

    public var minimumGradient: Float
    public var maximumGradient: Float
    public var points: [Point]
    public var resolution: Int

    public init(minimumGradient: Float = 0,
                maximumGradient: Float = 1000,
                points: [Point],
                resolution: Int = 256) {
        self.minimumGradient = minimumGradient
        self.maximumGradient = max(maximumGradient, minimumGradient)
        self.points = points
        self.resolution = max(2, resolution)
    }

    private enum CodingKeys: String, CodingKey {
        case minimumGradient = "minGradient"
        case maximumGradient = "maxGradient"
        case points
        case resolution
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minimum = try container.decodeIfPresent(Float.self, forKey: .minimumGradient) ?? 0
        let maximum = try container.decodeIfPresent(Float.self, forKey: .maximumGradient) ?? 1000
        minimumGradient = minimum
        maximumGradient = max(maximum, minimum)
        points = try container.decodeIfPresent([Point].self, forKey: .points) ?? []
        resolution = max(2, try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 256)
    }

    public func sanitizedPoints() -> [Point] {
        let clamped = points
            .filter { $0.gradientMagnitude.isFinite && $0.opacity.isFinite }
            .map { point in
                Point(
                    gradientMagnitude: VolumetricMath.clampFloat(point.gradientMagnitude,
                                                                  lower: minimumGradient,
                                                                  upper: maximumGradient),
                    opacity: VolumetricMath.clampFloat(point.opacity, lower: 0, upper: 1)
                )
            }
            .sorted { $0.gradientMagnitude < $1.gradientMagnitude }

        var deduplicated: [Point] = []
        for point in clamped {
            if let last = deduplicated.last,
               last.gradientMagnitude == point.gradientMagnitude {
                deduplicated[deduplicated.count - 1] = point
            } else {
                deduplicated.append(point)
            }
        }

        guard !deduplicated.isEmpty else {
            return [
                Point(gradientMagnitude: minimumGradient, opacity: 1),
                Point(gradientMagnitude: maximumGradient, opacity: 1)
            ]
        }

        if deduplicated[0].gradientMagnitude > minimumGradient {
            deduplicated.insert(Point(gradientMagnitude: minimumGradient,
                                      opacity: deduplicated[0].opacity), at: 0)
        } else {
            deduplicated[0].gradientMagnitude = minimumGradient
        }

        if deduplicated[deduplicated.count - 1].gradientMagnitude < maximumGradient {
            deduplicated.append(Point(gradientMagnitude: maximumGradient,
                                      opacity: deduplicated[deduplicated.count - 1].opacity))
        } else {
            deduplicated[deduplicated.count - 1].gradientMagnitude = maximumGradient
        }

        return deduplicated
    }

    public func opacity(at gradientMagnitude: Float) -> Float {
        let points = sanitizedPoints()
        guard let first = points.first else { return 1 }
        if gradientMagnitude <= first.gradientMagnitude {
            return first.opacity
        }

        for index in 1..<points.count {
            let right = points[index]
            let left = points[index - 1]
            if gradientMagnitude <= right.gradientMagnitude {
                let span = max(right.gradientMagnitude - left.gradientMagnitude, Float.leastNonzeroMagnitude)
                let t = (gradientMagnitude - left.gradientMagnitude) / span
                return right.opacity * t + left.opacity * (1 - t)
            }
        }

        return points.last?.opacity ?? first.opacity
    }
}

public enum ClinicalTransferFunctionPresetError: Error, Equatable, LocalizedError {
    case resourceUnavailable(ClinicalTransferFunctionPreset)

    public var errorDescription: String? {
        switch self {
        case .resourceUnavailable(let preset):
            return "Clinical transfer function preset '\(preset.displayName)' could not be loaded."
        }
    }
}

public enum ClinicalTransferFunctionPreset: String, CaseIterable, Identifiable, Sendable {
    case ctLung
    case ctBone
    case ctSoftTissue
    case ctBrain
    case ctAbdomen
    case ctVascular
    case ctPulmonaryArteries
    case ctAngioMIP
    case mrAngioMIP
    case ctMinIPLung
    case ctVRBone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ctLung:
            return "CT Lung"
        case .ctBone:
            return "CT Bone"
        case .ctSoftTissue:
            return "CT Soft Tissue"
        case .ctBrain:
            return "CT Brain"
        case .ctAbdomen:
            return "CT Abdomen"
        case .ctVascular:
            return "CT Vascular"
        case .ctPulmonaryArteries:
            return "CT Pulmonary Arteries"
        case .ctAngioMIP:
            return "CT Angio MIP"
        case .mrAngioMIP:
            return "MR Angio MIP"
        case .ctMinIPLung:
            return "CT MinIP Lung"
        case .ctVRBone:
            return "CT VR Bone"
        }
    }

    public var builtinPreset: VolumeRenderingBuiltinPreset {
        switch self {
        case .ctLung, .ctMinIPLung:
            return .ctLung
        case .ctBone, .ctVRBone:
            return .ctBone
        case .ctSoftTissue:
            return .ctSoftTissue
        case .ctBrain:
            return .ctBrain
        case .ctAbdomen:
            return .ctAbdomen
        case .ctVascular, .ctAngioMIP:
            return .ctArteries
        case .ctPulmonaryArteries:
            return .ctPulmonaryArteries
        case .mrAngioMIP:
            return .mrAngio
        }
    }

    public var metadata: TransferFunctionMetadata {
        TransferFunctionMetadata(
            identifier: "mtk.clinical.\(rawValue)",
            displayName: displayName,
            modality: modality,
            tissue: tissue,
            clinicalUse: clinicalUse,
            source: "MTK built-in transfer functions",
            tags: tags
        )
    }

    public var renderingIntent: TransferFunctionRenderingIntent {
        switch self {
        case .ctAngioMIP, .mrAngioMIP:
            return TransferFunctionRenderingIntent(mode: .mip,
                                                   lightingEnabled: false,
                                                   projectionsUseTransferFunction: false)
        case .ctMinIPLung:
            return TransferFunctionRenderingIntent(mode: .minip,
                                                   lightingEnabled: false,
                                                   projectionsUseTransferFunction: false)
        case .ctVRBone:
            return TransferFunctionRenderingIntent(mode: .dvr,
                                                   lightingEnabled: true,
                                                   projectionsUseTransferFunction: true)
        default:
            return TransferFunctionRenderingIntent(mode: .dvr,
                                                   lightingEnabled: true,
                                                   projectionsUseTransferFunction: true)
        }
    }

    public var gradientOpacity: GradientOpacityFunction? {
        switch self {
        case .ctBone, .ctSoftTissue, .ctBrain, .ctVRBone:
            return Self.ctSurfaceGradientOpacity
        default:
            return nil
        }
    }

    public func loadTransferFunction() throws -> TransferFunction {
        guard var transferFunction = VolumeTransferFunctionLibrary.transferFunction(for: builtinPreset) else {
            throw ClinicalTransferFunctionPresetError.resourceUnavailable(self)
        }
        transferFunction.version = TransferFunction.currentVersion
        transferFunction.metadata = metadata
        transferFunction.renderingIntent = renderingIntent
        transferFunction.gradientOpacity = gradientOpacity
        return transferFunction
    }

    private static var ctSurfaceGradientOpacity: GradientOpacityFunction {
        GradientOpacityFunction(
            minimumGradient: 0,
            maximumGradient: 100,
            points: [
                .init(gradientMagnitude: 0, opacity: 0.0),
                .init(gradientMagnitude: 20, opacity: 0.2),
                .init(gradientMagnitude: 100, opacity: 1.0)
            ],
            resolution: 256
        )
    }

    private var modality: ClinicalTransferFunctionModality {
        switch builtinPreset.modality {
        case .ct:
            return .ct
        case .mr:
            return .mr
        }
    }

    private var tissue: ClinicalTransferFunctionTissue {
        switch self {
        case .ctLung, .ctMinIPLung:
            return .lung
        case .ctBone, .ctVRBone:
            return .bone
        case .ctSoftTissue, .ctAbdomen:
            return .softTissue
        case .ctBrain:
            return .neurological
        case .ctVascular, .ctAngioMIP, .ctPulmonaryArteries, .mrAngioMIP:
            return .vascular
        }
    }

    private var clinicalUse: String {
        switch self {
        case .ctLung:
            return "Lung parenchyma and airway volume rendering."
        case .ctBone:
            return "Skeletal structure volume rendering."
        case .ctSoftTissue:
            return "General organ and soft-tissue volume rendering."
        case .ctBrain:
            return "Intracranial soft-tissue CT volume rendering."
        case .ctAbdomen:
            return "Abdominal organ and soft-tissue CT volume rendering."
        case .ctVascular:
            return "Contrast-enhanced CT vascular rendering."
        case .ctPulmonaryArteries:
            return "Pulmonary artery visualization."
        case .ctAngioMIP:
            return "CT angiography maximum-intensity projection."
        case .mrAngioMIP:
            return "MR angiography maximum-intensity projection."
        case .ctMinIPLung:
            return "Minimum-intensity lung projection."
        case .ctVRBone:
            return "Gradient-aware bone volume rendering."
        }
    }

    private var tags: [String] {
        var values = [modality.rawValue, tissue.rawValue, renderingIntent.mode.rawValue]
        if gradientOpacity != nil {
            values.append("gradientOpacity")
        }
        return values
    }
}

public extension VolumeTransferFunctionLibrary {
    static func transferFunction(for preset: ClinicalTransferFunctionPreset) throws -> TransferFunction {
        try preset.loadTransferFunction()
    }
}

public extension TransferFunction {
    func volumeTransferFunction() -> VolumeTransferFunction {
        let colourPoints = sanitizedColourPoints().map { point in
            VolumeTransferFunction.ColourControlPoint(
                intensity: point.dataValue + shift,
                colour: SIMD4<Float>(
                    point.colourValue.r,
                    point.colourValue.g,
                    point.colourValue.b,
                    point.colourValue.a
                )
            )
        }
        let opacityPoints = sanitizedAlphaPoints().map { point in
            VolumeTransferFunction.OpacityControlPoint(
                intensity: point.dataValue + shift,
                opacity: point.alphaValue
            )
        }
        return VolumeTransferFunction(opacityPoints: opacityPoints,
                                      colourPoints: colourPoints,
                                      gradientOpacity: gradientOpacity)
    }
}
