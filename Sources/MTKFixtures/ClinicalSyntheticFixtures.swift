import Foundation
import MTKCore
import simd

public struct SyntheticLabelmapFixture: Sendable, Equatable {
    public var baseDataset: VolumeDataset
    public var labelmapLayer: VolumeLayer
    public var surfaceMeshLayers: [SurfaceMeshLayer]

    public init(baseDataset: VolumeDataset,
                labelmapLayer: VolumeLayer,
                surfaceMeshLayers: [SurfaceMeshLayer]) {
        self.baseDataset = baseDataset
        self.labelmapLayer = labelmapLayer
        self.surfaceMeshLayers = surfaceMeshLayers
    }
}

public struct SyntheticFusionFixture: Sendable, Equatable {
    public var baseDataset: VolumeDataset
    public var petLayer: VolumeLayer

    public init(baseDataset: VolumeDataset,
                petLayer: VolumeLayer) {
        self.baseDataset = baseDataset
        self.petLayer = petLayer
    }
}

public enum ClinicalSyntheticFixtureIDs {
    public static let labelmapLayer = "mtk.fixtures.synthetic.labelmap"
    public static let petLayer = "mtk.fixtures.synthetic.pet"
    public static let surfaceLayerPrefix = "mtk.fixtures.synthetic.surface."
}

public enum ClinicalSyntheticFixtures {
    public static func makeLabelmapOverlay(
        labelmapLayerID: String = ClinicalSyntheticFixtureIDs.labelmapLayer,
        surfaceLayerIDPrefix: String = ClinicalSyntheticFixtureIDs.surfaceLayerPrefix,
        labelmapOpacity: Float = 0.65,
        labelmapVisible: Bool = true,
        surfaceOpacity: Float = 0.45,
        surfaceVisible: Bool = true
    ) throws -> SyntheticLabelmapFixture {
        let dimensions = standardDimensions
        let spacing = standardSpacing
        let orientation = standardOrientation
        let center = standardCenter(dimensions: dimensions)

        var intensities = Array(repeating: Int16(-900), count: dimensions.voxelCount)
        var labels = Array(repeating: UInt16(0), count: dimensions.voxelCount)

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = x + y * dimensions.width + z * dimensions.width * dimensions.height
                    let voxel = SIMD3<Float>(Float(x), Float(y), Float(z))
                    let normalized = (voxel - center) / SIMD3<Float>(42, 42, 28)
                    let shell = max(0, 1 - simd_length(normalized))
                    intensities[index] = Int16(-850 + shell * 1_700)

                    let lesionA = simd_length((voxel - (center + SIMD3<Float>(-13, 8, 1))) / SIMD3<Float>(12, 16, 10))
                    let lesionB = simd_length((voxel - (center + SIMD3<Float>(15, -10, -4))) / SIMD3<Float>(14, 10, 12))
                    if lesionA <= 1 {
                        labels[index] = 1
                    } else if lesionB <= 1 {
                        labels[index] = 2
                    }
                }
            }
        }

        let baseDataset = VolumeDataset(
            data: intensities.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: (-900)...850,
            orientation: orientation,
            recommendedWindow: (-500)...650,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "SYN",
                seriesDescription: "Synthetic labelmap overlay"
            )
        )
        let labelmapDataset = VolumeDataset(
            data: labels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: 0...2,
            orientation: orientation,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "SEG",
                seriesDescription: "Synthetic labelmap"
            )
        )
        let labelmap = try LabelmapVolume(
            dataset: labelmapDataset,
            segments: [
                LabelmapSegment(label: 1,
                                name: "Region A",
                                color: SIMD4<Float>(1.0, 0.12, 0.05, 1.0)),
                LabelmapSegment(label: 2,
                                name: "Region B",
                                color: SIMD4<Float>(0.1, 0.45, 1.0, 1.0))
            ]
        )
        let labelmapLayer = VolumeLayer(id: labelmapLayerID,
                                        labelmap: labelmap,
                                        opacity: labelmapOpacity,
                                        isVisible: labelmapVisible)
        let surfaceMeshLayers = try makeSurfaceMeshLayers(from: labelmap,
                                                          layerIDPrefix: surfaceLayerIDPrefix,
                                                          opacity: surfaceOpacity,
                                                          isVisible: surfaceVisible)
        return SyntheticLabelmapFixture(baseDataset: baseDataset,
                                        labelmapLayer: labelmapLayer,
                                        surfaceMeshLayers: surfaceMeshLayers)
    }

    public static func makeFusion(
        petLayerID: String = ClinicalSyntheticFixtureIDs.petLayer,
        petOpacity: Float = 0.5,
        petBlendMode: VolumeLayerBlendMode = .additive,
        petVisible: Bool = true
    ) -> SyntheticFusionFixture {
        let dimensions = standardDimensions
        let spacing = standardSpacing
        let orientation = standardOrientation
        let center = standardCenter(dimensions: dimensions)

        var ctValues = Array(repeating: Int16(-950), count: dimensions.voxelCount)
        var petValues = Array(repeating: Int16(0), count: dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = x + y * dimensions.width + z * dimensions.width * dimensions.height
                    let voxel = SIMD3<Float>(Float(x), Float(y), Float(z))
                    let body = simd_length((voxel - center) / SIMD3<Float>(42, 42, 28))
                    let bodySignal = max(0, 1 - body)
                    ctValues[index] = Int16(-900 + bodySignal * 1_450)

                    let focusA = simd_length((voxel - (center + SIMD3<Float>(-12, 8, 2))) / SIMD3<Float>(10, 13, 8))
                    let focusB = simd_length((voxel - (center + SIMD3<Float>(16, -9, -5))) / SIMD3<Float>(13, 9, 10))
                    let uptake = max(exp(-focusA * focusA * 2.0), exp(-focusB * focusB * 2.4))
                    petValues[index] = Int16(max(0, min(1000, uptake * 1000)))
                }
            }
        }

        let baseDataset = VolumeDataset(
            data: ctValues.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: (-950)...550,
            orientation: orientation,
            recommendedWindow: (-500)...550,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "CT",
                seriesDescription: "Synthetic CT base"
            )
        )
        let petDataset = VolumeDataset(
            data: petValues.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: 0...1000,
            orientation: orientation,
            recommendedWindow: 0...1000,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "PT",
                seriesDescription: "Synthetic PET-like heat volume"
            )
        )
        let petTransfer = VolumeTransferFunction(
            opacityPoints: [
                .init(intensity: 0, opacity: 0),
                .init(intensity: 250, opacity: 0.08),
                .init(intensity: 650, opacity: 0.45),
                .init(intensity: 1000, opacity: 0.85)
            ],
            colourPoints: [
                .init(intensity: 0, colour: SIMD4<Float>(0, 0, 0, 0)),
                .init(intensity: 250, colour: SIMD4<Float>(0.05, 0.1, 1.0, 1)),
                .init(intensity: 650, colour: SIMD4<Float>(1.0, 0.45, 0.0, 1)),
                .init(intensity: 1000, colour: SIMD4<Float>(1.0, 1.0, 0.15, 1))
            ]
        )
        let petLayer = VolumeLayer(id: petLayerID,
                                   dataset: petDataset,
                                   transferFunction: petTransfer,
                                   opacity: petOpacity,
                                   blendMode: petBlendMode,
                                   isVisible: petVisible)
        return SyntheticFusionFixture(baseDataset: baseDataset,
                                      petLayer: petLayer)
    }

    public static func makeCropClipVolume() throws -> VolumeDataset {
        try makeLabelmapOverlay().baseDataset
    }
}

private extension ClinicalSyntheticFixtures {
    static let standardDimensions = VolumeDimensions(width: 96, height: 96, depth: 64)
    static let standardSpacing = VolumeSpacing(x: 1.0, y: 1.0, z: 1.5)
    static let standardOrientation = VolumeOrientation(
        row: SIMD3<Float>(1, 0, 0),
        column: SIMD3<Float>(0, 1, 0),
        origin: SIMD3<Float>(-48, -48, -48)
    )

    static func standardCenter(dimensions: VolumeDimensions) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(dimensions.width - 1) / 2,
            Float(dimensions.height - 1) / 2,
            Float(dimensions.depth - 1) / 2
        )
    }

    static func makeSurfaceMeshLayers(from labelmap: LabelmapVolume,
                                      layerIDPrefix: String,
                                      opacity: Float,
                                      isVisible: Bool) throws -> [SurfaceMeshLayer] {
        let extractor = MarchingCubesExtractor()
        return try labelmap.segments.compactMap { segment in
            let mesh = try extractor.extractSurface(from: labelmap, label: segment.label)
            guard mesh.isRenderable else { return nil }
            return SurfaceMeshLayer(id: "\(layerIDPrefix)\(segment.label)",
                                    mesh: mesh,
                                    material: SurfaceMeshMaterial(color: segment.color),
                                    opacity: opacity,
                                    isVisible: isVisible && segment.isVisible)
        }
    }
}
