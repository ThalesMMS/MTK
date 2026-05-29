//
//  RTDoseVolumeOverlay.swift
//  MTKCore
//
//  Dose-volume overlay, colorwash, and picking contracts.
//

import Foundation
import simd

public struct RTDoseColorStop: Sendable, Equatable {
    public var doseValue: Double
    public var color: SIMD4<Float>

    public init(doseValue: Double, color: SIMD4<Float>) {
        self.doseValue = doseValue.isFinite ? max(doseValue, 0) : 0
        self.color = SIMD4<Float>(
            Self.clamp01(color.x),
            Self.clamp01(color.y),
            Self.clamp01(color.z),
            Self.clamp01(color.w)
        )
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct RTDoseColorLookupTable: Sendable, Equatable {
    public var stops: [RTDoseColorStop]

    public init(stops: [RTDoseColorStop]) {
        self.stops = stops
            .filter { $0.doseValue.isFinite }
            .sorted { lhs, rhs in lhs.doseValue < rhs.doseValue }
    }

    public static func defaultColorwash(maxDose: Double) -> RTDoseColorLookupTable {
        let upper = max(maxDose.isFinite ? maxDose : 0, 1)
        return RTDoseColorLookupTable(stops: [
            RTDoseColorStop(doseValue: 0, color: SIMD4<Float>(0, 0, 0, 0)),
            RTDoseColorStop(doseValue: upper * 0.25, color: SIMD4<Float>(0, 0.7, 1, 0.35)),
            RTDoseColorStop(doseValue: upper * 0.50, color: SIMD4<Float>(0.1, 1, 0.25, 0.55)),
            RTDoseColorStop(doseValue: upper * 0.75, color: SIMD4<Float>(1, 0.85, 0, 0.75)),
            RTDoseColorStop(doseValue: upper, color: SIMD4<Float>(1, 0.1, 0, 0.95))
        ])
    }

    public func transferFunction(doseGridScaling: Double,
                                 fallbackStoredRange: ClosedRange<Int32>) -> VolumeTransferFunction {
        let scaling = doseGridScaling.isFinite && doseGridScaling > 0 ? doseGridScaling : 1
        let lower = Float(fallbackStoredRange.lowerBound)
        let upper = Float(fallbackStoredRange.upperBound)
        guard stops.isEmpty == false else {
            return VolumeTransferFunction(
                opacityPoints: [
                    VolumeTransferFunction.OpacityControlPoint(intensity: lower, opacity: 0),
                    VolumeTransferFunction.OpacityControlPoint(intensity: upper, opacity: 1)
                ],
                colourPoints: [
                    VolumeTransferFunction.ColourControlPoint(intensity: lower,
                                                              colour: SIMD4<Float>(0, 0, 0, 0)),
                    VolumeTransferFunction.ColourControlPoint(intensity: upper,
                                                              colour: SIMD4<Float>(1, 0, 0, 1))
                ]
            )
        }

        return VolumeTransferFunction(
            opacityPoints: stops.map { stop in
                VolumeTransferFunction.OpacityControlPoint(
                    intensity: Float(stop.doseValue / scaling),
                    opacity: stop.color.w
                )
            },
            colourPoints: stops.map { stop in
                VolumeTransferFunction.ColourControlPoint(
                    intensity: Float(stop.doseValue / scaling),
                    colour: stop.color
                )
            }
        )
    }
}

public struct RTDoseVolumeOverlay: Identifiable, Sendable, Equatable {
    public var id: String
    public var volumeLayer: VolumeLayer
    public var doseUnits: String?
    public var doseType: String?
    public var doseSummationType: String?
    public var doseGridScaling: Double
    public var frameOfReferenceUID: String?
    public var colorLookupTable: RTDoseColorLookupTable

    public init(id: String = UUID().uuidString,
                dataset: VolumeDataset,
                doseUnits: String? = nil,
                doseType: String? = nil,
                doseSummationType: String? = nil,
                doseGridScaling: Double,
                frameOfReferenceUID: String? = nil,
                colorLookupTable: RTDoseColorLookupTable? = nil,
                opacity: Float = 0.45,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4,
                isVisible: Bool = true) {
        let resolvedID = Self.normalized(id) ?? UUID().uuidString
        let scaling = doseGridScaling.isFinite && doseGridScaling > 0 ? doseGridScaling : 1
        let maxDose = Double(dataset.intensityRange.upperBound) * scaling
        let resolvedLUT = colorLookupTable ?? .defaultColorwash(maxDose: maxDose)
        let transfer = resolvedLUT.transferFunction(doseGridScaling: scaling,
                                                    fallbackStoredRange: dataset.intensityRange)
        self.id = resolvedID
        self.volumeLayer = VolumeLayer(id: resolvedID,
                                       dataset: dataset,
                                       transferFunction: transfer,
                                       opacity: opacity,
                                       blendMode: blendMode,
                                       baseWorldToLayerWorld: baseWorldToLayerWorld,
                                       isVisible: isVisible)
        self.doseUnits = Self.normalized(doseUnits)
        self.doseType = Self.normalized(doseType)
        self.doseSummationType = Self.normalized(doseSummationType)
        self.doseGridScaling = scaling
        self.frameOfReferenceUID = Self.normalized(frameOfReferenceUID)
        self.colorLookupTable = resolvedLUT
    }

    public var doseDataset: VolumeDataset? {
        volumeLayer.scalarVolume?.dataset
    }

    public func settingOpacity(_ opacity: Float) -> RTDoseVolumeOverlay {
        var overlay = self
        overlay.volumeLayer.opacity = Self.clamp01(opacity)
        return overlay
    }

    public func settingVisibility(_ isVisible: Bool) -> RTDoseVolumeOverlay {
        var overlay = self
        overlay.volumeLayer.isVisible = isVisible
        return overlay
    }

    public func settingColorLookupTable(_ colorLookupTable: RTDoseColorLookupTable) -> RTDoseVolumeOverlay {
        var overlay = self
        overlay.colorLookupTable = colorLookupTable
        guard let scalarVolume = volumeLayer.scalarVolume else {
            return overlay
        }
        let transfer = colorLookupTable.transferFunction(
            doseGridScaling: doseGridScaling,
            fallbackStoredRange: scalarVolume.dataset.intensityRange
        )
        overlay.volumeLayer.content = .scalarVolume(
            ScalarVolumeLayer(dataset: scalarVolume.dataset,
                              transferFunction: transfer)
        )
        return overlay
    }

    public func sampleDose(atBaseWorldPoint worldPoint: SIMD3<Float>) throws -> RTDoseSample {
        try RTDoseVolumePicking.sampleDose(in: self,
                                           atBaseWorldPoint: worldPoint)
    }

    public func doseStatistics(in roiLayer: VolumeLayer,
                               label: UInt16? = nil) throws -> RTDoseStatistics {
        try RTDoseVolumePicking.doseStatistics(in: self,
                                               roiLayer: roiLayer,
                                               label: label)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct RTDoseSample: Sendable, Equatable {
    public var layerID: String
    public var doseValue: Double
    public var doseUnits: String?
    public var storedScalar: Int32
    public var voxel: VoxelIndex
    public var baseWorldPoint: SIMD3<Float>
    public var doseWorldPoint: SIMD3<Float>

    public init(layerID: String,
                doseValue: Double,
                doseUnits: String?,
                storedScalar: Int32,
                voxel: VoxelIndex,
                baseWorldPoint: SIMD3<Float>,
                doseWorldPoint: SIMD3<Float>) {
        self.layerID = layerID
        self.doseValue = doseValue
        self.doseUnits = doseUnits
        self.storedScalar = storedScalar
        self.voxel = voxel
        self.baseWorldPoint = baseWorldPoint
        self.doseWorldPoint = doseWorldPoint
    }
}

public struct RTDoseStatistics: Sendable, Equatable {
    public var layerID: String
    public var doseUnits: String?
    public var sampleCount: Int
    public var minimumDose: Double
    public var maximumDose: Double
    public var meanDose: Double
    public var standardDeviation: Double

    public init(layerID: String,
                doseUnits: String?,
                sampleCount: Int,
                minimumDose: Double,
                maximumDose: Double,
                meanDose: Double,
                standardDeviation: Double = 0) {
        self.layerID = layerID
        self.doseUnits = doseUnits
        self.sampleCount = sampleCount
        self.minimumDose = minimumDose
        self.maximumDose = maximumDose
        self.meanDose = meanDose
        self.standardDeviation = standardDeviation.isFinite ? standardDeviation : 0
    }
}

public enum RTDoseVolumePickingError: Error, Equatable, LocalizedError {
    case missingDoseDataset(String)
    case missingLabelmap(String)
    case malformedLabelmap(String)
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .missingDoseDataset(let id):
            return "RT dose overlay \(id) does not contain a scalar dose dataset."
        case .missingLabelmap(let id):
            return "ROI layer \(id) does not contain a labelmap volume."
        case .malformedLabelmap(let id):
            return "ROI layer \(id) has malformed labelmap data."
        case .emptySelection:
            return "No dose samples were found in the selected ROI."
        }
    }
}

public enum RTDoseVolumePicking {
    public static func sampleDose(in overlay: RTDoseVolumeOverlay,
                                  atBaseWorldPoint baseWorldPoint: SIMD3<Float>) throws -> RTDoseSample {
        guard let dataset = overlay.doseDataset else {
            throw RTDoseVolumePickingError.missingDoseDataset(overlay.id)
        }
        let doseWorldPoint = overlay.volumeLayer.baseWorldToLayerWorld.transformPoint(baseWorldPoint)
        let voxel = try VolumePicking.voxelIndex(forWorldPoint: doseWorldPoint,
                                                 in: dataset)
        let intensity = try VolumePicking.sampleIntensity(in: dataset,
                                                          atVoxelIndex: voxel.index)
        return RTDoseSample(layerID: overlay.volumeLayer.id,
                            doseValue: Double(intensity.storedScalar) * overlay.doseGridScaling,
                            doseUnits: overlay.doseUnits,
                            storedScalar: intensity.storedScalar,
                            voxel: voxel,
                            baseWorldPoint: baseWorldPoint,
                            doseWorldPoint: doseWorldPoint)
    }

    public static func doseStatistics(in overlay: RTDoseVolumeOverlay,
                                      roiLayer: VolumeLayer,
                                      label: UInt16? = nil) throws -> RTDoseStatistics {
        guard let labelmap = roiLayer.labelmap else {
            throw RTDoseVolumePickingError.missingLabelmap(roiLayer.id)
        }
        guard labelmap.dataset.pixelFormat == .int16Unsigned,
              labelmap.dataset.data.count >= labelmap.dataset.dimensions.voxelCount * MemoryLayout<UInt16>.size else {
            throw RTDoseVolumePickingError.malformedLabelmap(roiLayer.id)
        }

        let labelWorldToBaseWorld = simd_inverse(roiLayer.baseWorldToLayerWorld)
        var count = 0
        var total = 0.0
        var totalSquares = 0.0
        var minDose = Double.greatestFiniteMagnitude
        var maxDose = -Double.greatestFiniteMagnitude
        let dimensions = labelmap.dataset.dimensions
        let labelData = labelmap.dataset.data
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let linear = z * dimensions.width * dimensions.height + y * dimensions.width + x
                    let storedLabel = readUInt16LittleEndian(labelData, atLinearIndex: linear)
                    guard storedLabel > 0,
                          label == nil || storedLabel == label else {
                        continue
                    }
                    let labelIndex = SIMD3<Float>(Float(x), Float(y), Float(z))
                    let labelWorld = labelmap.dataset.imageData.indexToWorld.transformPoint(labelIndex)
                    let baseWorld = labelWorldToBaseWorld.transformPoint(labelWorld)
                    guard let sample = try? sampleDose(in: overlay, atBaseWorldPoint: baseWorld) else {
                        continue
                    }
                    count += 1
                    total += sample.doseValue
                    totalSquares += sample.doseValue * sample.doseValue
                    minDose = min(minDose, sample.doseValue)
                    maxDose = max(maxDose, sample.doseValue)
                }
            }
        }

        guard count > 0 else {
            throw RTDoseVolumePickingError.emptySelection
        }
        let mean = total / Double(count)
        let variance = max(0, totalSquares / Double(count) - mean * mean)
        return RTDoseStatistics(layerID: overlay.volumeLayer.id,
                                doseUnits: overlay.doseUnits,
                                sampleCount: count,
                                minimumDose: minDose,
                                maximumDose: maxDose,
                                meanDose: mean,
                                standardDeviation: variance.squareRoot())
    }

    private static func readUInt16LittleEndian(_ data: Data, atLinearIndex linearIndex: Int) -> UInt16 {
        let byteOffset = linearIndex * MemoryLayout<UInt16>.size
        let low = UInt16(data[byteOffset])
        let high = UInt16(data[byteOffset + 1]) << 8
        return low | high
    }
}
