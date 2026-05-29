import DicomCore
import Foundation
import MTKCore
import simd

public enum DicomRTDoseVolumeOverlayBridgeError: Error, Equatable, LocalizedError {
    case emptyDoseVolume
    case invalidPixelCount(expected: Int, actual: Int)
    case unsupportedStoredValue(UInt32)
    case frameOfReferenceMismatch(base: String, dose: String)

    public var errorDescription: String? {
        switch self {
        case .emptyDoseVolume:
            return "RTDOSE contains no dose pixels."
        case let .invalidPixelCount(expected, actual):
            return "RTDOSE contains \(actual) pixels; expected \(expected)."
        case let .unsupportedStoredValue(value):
            return "RTDOSE stored value \(value) exceeds MTK's UInt16 scalar layer range."
        case let .frameOfReferenceMismatch(base, dose):
            return "RTDOSE FrameOfReferenceUID \(dose) does not match base volume \(base)."
        }
    }
}

public struct DicomRTDoseVolumeOverlayOptions: Equatable, Sendable {
    public var layerID: String?
    public var opacity: Float
    public var isVisible: Bool
    public var colorLookupTable: RTDoseColorLookupTable?
    public var blendMode: VolumeLayerBlendMode
    public var seriesDescription: String?

    public init(layerID: String? = nil,
                opacity: Float = 0.45,
                isVisible: Bool = true,
                colorLookupTable: RTDoseColorLookupTable? = nil,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                seriesDescription: String? = "RT dose") {
        self.layerID = layerID
        self.opacity = opacity
        self.isVisible = isVisible
        self.colorLookupTable = colorLookupTable
        self.blendMode = blendMode
        self.seriesDescription = seriesDescription
    }
}

public enum DicomRTDoseVolumeOverlayBuilder {
    public static func makeOverlay(
        from dose: DicomRTDoseVolume,
        alignedTo baseDataset: VolumeDataset,
        options: DicomRTDoseVolumeOverlayOptions = DicomRTDoseVolumeOverlayOptions()
    ) throws -> RTDoseVolumeOverlay {
        try validateFrameOfReference(dose.frameOfReferenceUID,
                                     baseFrameOfReferenceUID: baseDataset.imageData.clinicalMetadata?.frameOfReferenceUID)
        let dataset = try makeDataset(from: dose,
                                      alignedTo: baseDataset,
                                      seriesDescription: options.seriesDescription)
        return RTDoseVolumeOverlay(
            id: options.layerID ?? dose.sopInstanceUID ?? "dicom-rtdose",
            dataset: dataset,
            doseUnits: dose.doseUnits,
            doseType: dose.doseType,
            doseSummationType: dose.doseSummationType,
            doseGridScaling: dose.doseGridScaling,
            frameOfReferenceUID: dose.frameOfReferenceUID,
            colorLookupTable: options.colorLookupTable,
            opacity: options.opacity,
            blendMode: options.blendMode,
            isVisible: options.isVisible
        )
    }

    public static func makeDataset(
        from dose: DicomRTDoseVolume,
        alignedTo baseDataset: VolumeDataset,
        seriesDescription: String? = "RT dose"
    ) throws -> VolumeDataset {
        let expectedCount = dose.rows * dose.columns * dose.frames
        guard expectedCount > 0 else {
            throw DicomRTDoseVolumeOverlayBridgeError.emptyDoseVolume
        }
        guard dose.storedValues.count == expectedCount else {
            throw DicomRTDoseVolumeOverlayBridgeError.invalidPixelCount(expected: expectedCount,
                                                                       actual: dose.storedValues.count)
        }
        guard let maxStored = dose.storedValues.max(),
              maxStored <= UInt32(UInt16.max) else {
            throw DicomRTDoseVolumeOverlayBridgeError.unsupportedStoredValue(dose.storedValues.max() ?? 0)
        }

        let voxels = dose.storedValues.map(UInt16.init)
        let range = storedRange(for: voxels)
        let orientation = orientation(from: dose, fallback: baseDataset.imageData)
        let imageData = ImageData3D(
            dimensions: VolumeDimensions(width: dose.columns,
                                         height: dose.rows,
                                         depth: dose.frames),
            spacing: spacing(from: dose, fallback: baseDataset.spacing),
            origin: origin(from: dose, fallback: baseDataset.imageData.origin),
            direction: orientation,
            pixelFormat: .int16Unsigned,
            intensityRange: range,
            recommendedWindow: range,
            clinicalMetadata: ClinicalImageMetadata(
                modality: "RTDOSE",
                seriesDescription: seriesDescription,
                frameOfReferenceUID: dose.frameOfReferenceUID,
                rescaleSlope: dose.doseGridScaling,
                rescaleIntercept: 0,
                sourcePixelFormat: .int16Unsigned
            )
        )
        return VolumeDataset(data: littleEndianData(from: voxels),
                             imageData: imageData)
    }

    private static func validateFrameOfReference(_ doseFrameOfReferenceUID: String?,
                                                 baseFrameOfReferenceUID: String?) throws {
        guard let dose = nonEmpty(doseFrameOfReferenceUID),
              let base = nonEmpty(baseFrameOfReferenceUID),
              dose != base else {
            return
        }
        throw DicomRTDoseVolumeOverlayBridgeError.frameOfReferenceMismatch(base: base, dose: dose)
    }

    private static func spacing(from dose: DicomRTDoseVolume,
                                fallback: VolumeSpacing) -> VolumeSpacing {
        let x = dose.pixelSpacing?.y ?? fallback.x
        let y = dose.pixelSpacing?.x ?? fallback.y
        let z: Double
        if dose.gridFrameOffsetVector.count >= 2 {
            z = max(abs(dose.gridFrameOffsetVector[1] - dose.gridFrameOffsetVector[0]), Double.ulpOfOne)
        } else {
            z = fallback.z
        }
        return VolumeSpacing(x: x, y: y, z: z)
    }

    private static func origin(from dose: DicomRTDoseVolume,
                               fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let imagePositionPatient = dose.imagePositionPatient else {
            return fallback
        }
        return SIMD3<Float>(Float(imagePositionPatient.x),
                            Float(imagePositionPatient.y),
                            Float(imagePositionPatient.z))
    }

    private static func orientation(from dose: DicomRTDoseVolume,
                                    fallback: ImageData3D) -> simd_float3x3 {
        guard let imageOrientationPatient = dose.imageOrientationPatient else {
            return fallback.direction
        }
        let row = SIMD3<Float>(
            Float(imageOrientationPatient.row.x),
            Float(imageOrientationPatient.row.y),
            Float(imageOrientationPatient.row.z)
        )
        let column = SIMD3<Float>(
            Float(imageOrientationPatient.column.x),
            Float(imageOrientationPatient.column.y),
            Float(imageOrientationPatient.column.z)
        )
        let slice = normalizedCross(row,
                                    column,
                                    fallback: fallback.sliceDirection)
        return simd_float3x3(columns: (row, column, slice))
    }

    private static func storedRange(for voxels: [UInt16]) -> ClosedRange<Int32> {
        let minValue = Int32(voxels.min() ?? 0)
        let maxValue = Int32(voxels.max() ?? 0)
        return minValue...max(maxValue, minValue)
    }

    private static func littleEndianData(from voxels: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(voxels.count * MemoryLayout<UInt16>.size)
        for value in voxels {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedCross(_ lhs: SIMD3<Float>,
                                        _ rhs: SIMD3<Float>,
                                        fallback: SIMD3<Float>) -> SIMD3<Float> {
        let cross = simd_cross(lhs, rhs)
        let length = simd_length(cross)
        if length > Float.ulpOfOne {
            return cross / length
        }
        let fallbackLength = simd_length(fallback)
        if fallbackLength > Float.ulpOfOne {
            return fallback / fallbackLength
        }
        return SIMD3<Float>(0, 0, 1)
    }
}
