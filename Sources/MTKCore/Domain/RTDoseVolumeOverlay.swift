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
        guard let doseDataset = overlay.doseDataset else {
            throw RTDoseVolumePickingError.missingDoseDataset(overlay.id)
        }
        guard doseDataset.data.count >= doseDataset.dimensions.voxelCount * doseDataset.pixelFormat.bytesPerVoxel else {
            throw VolumePickError.malformedData
        }

        let labelWorldToBaseWorld = simd_inverse(roiLayer.baseWorldToLayerWorld)
        let labelIndexToDoseIndex = doseDataset.imageData.worldToIndex
            * overlay.volumeLayer.baseWorldToLayerWorld
            * labelWorldToBaseWorld
            * labelmap.dataset.imageData.indexToWorld
        let labelDimensions = labelmap.dataset.dimensions
        let labelData = labelmap.dataset.data
        let doseData = doseDataset.data
        let totals = labelData.withUnsafeBytes { labelRawBuffer in
            let labels = labelRawBuffer.bindMemory(to: UInt16.self)
            return doseData.withUnsafeBytes { doseRawBuffer in
                switch doseDataset.pixelFormat {
                case .int16Signed:
                    return accumulateDoseStatistics(
                        labels: labels,
                        doseValues: doseRawBuffer.bindMemory(to: Int16.self),
                        labelDimensions: labelDimensions,
                        doseDimensions: doseDataset.dimensions,
                        labelIndexToDoseIndex: labelIndexToDoseIndex,
                        selectedLabel: label,
                        doseGridScaling: overlay.doseGridScaling
                    )
                case .int16Unsigned:
                    return accumulateDoseStatistics(
                        labels: labels,
                        doseValues: doseRawBuffer.bindMemory(to: UInt16.self),
                        labelDimensions: labelDimensions,
                        doseDimensions: doseDataset.dimensions,
                        labelIndexToDoseIndex: labelIndexToDoseIndex,
                        selectedLabel: label,
                        doseGridScaling: overlay.doseGridScaling
                    )
                }
            }
        }

        guard totals.count > 0 else {
            throw RTDoseVolumePickingError.emptySelection
        }
        let mean = totals.total / Double(totals.count)
        let variance = max(0, totals.totalSquares / Double(totals.count) - mean * mean)
        return RTDoseStatistics(layerID: overlay.volumeLayer.id,
                                doseUnits: overlay.doseUnits,
                                sampleCount: totals.count,
                                minimumDose: totals.minimum,
                                maximumDose: totals.maximum,
                                meanDose: mean,
                                standardDeviation: variance.squareRoot())
    }

    private static func accumulateDoseStatistics<StoredScalar: BinaryInteger>(
        labels: UnsafeBufferPointer<UInt16>,
        doseValues: UnsafeBufferPointer<StoredScalar>,
        labelDimensions: VolumeDimensions,
        doseDimensions: VolumeDimensions,
        labelIndexToDoseIndex: simd_float4x4,
        selectedLabel: UInt16?,
        doseGridScaling: Double
    ) -> DoseStatisticsAccumulator {
        var totals = DoseStatisticsAccumulator()
        let labelSliceStride = labelDimensions.width * labelDimensions.height

        for z in 0..<labelDimensions.depth {
            for y in 0..<labelDimensions.height {
                for x in 0..<labelDimensions.width {
                    let labelLinear = z * labelSliceStride + y * labelDimensions.width + x
                    let storedLabel = UInt16(littleEndian: labels[labelLinear])
                    guard storedLabel > 0,
                          selectedLabel == nil || storedLabel == selectedLabel else {
                        continue
                    }

                    let doseIndex = labelIndexToDoseIndex.transformPoint(
                        SIMD3<Float>(Float(x), Float(y), Float(z))
                    )
                    guard doseIndex.x.isFinite, doseIndex.y.isFinite, doseIndex.z.isFinite else {
                        continue
                    }
                    let nearest = SIMD3<Int32>(
                        Int32(floor(doseIndex.x + 0.5)),
                        Int32(floor(doseIndex.y + 0.5)),
                        Int32(floor(doseIndex.z + 0.5))
                    )
                    guard nearest.x >= 0, nearest.x < Int32(doseDimensions.width),
                          nearest.y >= 0, nearest.y < Int32(doseDimensions.height),
                          nearest.z >= 0, nearest.z < Int32(doseDimensions.depth) else {
                        continue
                    }

                    let doseLinear = Int(nearest.z) * doseDimensions.width * doseDimensions.height
                        + Int(nearest.y) * doseDimensions.width
                        + Int(nearest.x)
                    let dose = Double(Int32(doseValues[doseLinear])) * doseGridScaling
                    totals.append(dose)
                }
            }
        }
        return totals
    }

    private struct DoseStatisticsAccumulator {
        var count = 0
        var total = 0.0
        var totalSquares = 0.0
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude

        mutating func append(_ dose: Double) {
            count += 1
            total += dose
            totalSquares += dose * dose
            minimum = min(minimum, dose)
            maximum = max(maximum, dose)
        }
    }
}
