//
//  QuantitativeScalarVolumePicking.swift
//  MTKCore
//
//  Picking and ROI statistics for quantitative scalar layers.
//

import Foundation
import simd

public struct QuantitativeScalarStatistics: Sendable, Equatable {
    public var layerID: String
    public var units: QuantitativeCodedConcept?
    public var quantityDefinitions: [QuantitativeQuantityDefinition]
    public var sampleCount: Int
    public var minimumValue: Double
    public var maximumValue: Double
    public var meanValue: Double
    public var standardDeviation: Double
    public var physicalRange: ClosedRange<Double>
    public var legendTitle: String?

    public init(layerID: String,
                units: QuantitativeCodedConcept?,
                quantityDefinitions: [QuantitativeQuantityDefinition],
                sampleCount: Int,
                minimumValue: Double,
                maximumValue: Double,
                meanValue: Double,
                standardDeviation: Double = 0,
                physicalRange: ClosedRange<Double>,
                legendTitle: String?) {
        self.layerID = layerID
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.sampleCount = sampleCount
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.meanValue = meanValue
        self.standardDeviation = standardDeviation.isFinite ? standardDeviation : 0
        self.physicalRange = physicalRange
        self.legendTitle = legendTitle
    }

    public var unitsLabel: String? {
        units?.displayText
    }
}

public enum QuantitativeScalarVolumePickingError: Error, Equatable, LocalizedError {
    case missingScalarDataset(String)
    case missingQuantitativeMapping(String)
    case missingLabelmap(String)
    case malformedLabelmap(String)
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .missingScalarDataset(let id):
            return "Scalar layer \(id) does not contain a scalar volume."
        case .missingQuantitativeMapping(let id):
            return "Scalar layer \(id) does not contain quantitative mapping metadata."
        case .missingLabelmap(let id):
            return "ROI layer \(id) does not contain a labelmap volume."
        case .malformedLabelmap(let id):
            return "ROI layer \(id) has malformed labelmap data."
        case .emptySelection:
            return "No quantitative samples were found in the selected ROI."
        }
    }
}

public enum QuantitativeScalarVolumePicking {
    public static func statistics(in layer: VolumeLayer,
                                  roiLayer: VolumeLayer,
                                  label: UInt16? = nil) throws -> QuantitativeScalarStatistics {
        guard let scalarVolume = layer.scalarVolume else {
            throw QuantitativeScalarVolumePickingError.missingScalarDataset(layer.id)
        }
        guard let mapping = scalarVolume.quantitativeMapping else {
            throw QuantitativeScalarVolumePickingError.missingQuantitativeMapping(layer.id)
        }
        guard let labelmap = roiLayer.labelmap else {
            throw QuantitativeScalarVolumePickingError.missingLabelmap(roiLayer.id)
        }
        guard labelmap.dataset.pixelFormat == .int16Unsigned,
              labelmap.dataset.data.count >= labelmap.dataset.dimensions.voxelCount * MemoryLayout<UInt16>.size else {
            throw QuantitativeScalarVolumePickingError.malformedLabelmap(roiLayer.id)
        }

        let labelWorldToBaseWorld = simd_inverse(roiLayer.baseWorldToLayerWorld)
        var count = 0
        var total = 0.0
        var totalSquares = 0.0
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
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
                    let scalarWorld = layer.baseWorldToLayerWorld.transformPoint(baseWorld)
                    guard let value = try? quantitativeValue(in: scalarVolume,
                                                             mapping: mapping,
                                                             atWorldPoint: scalarWorld) else {
                        continue
                    }
                    count += 1
                    total += value.value
                    totalSquares += value.value * value.value
                    minimum = min(minimum, value.value)
                    maximum = max(maximum, value.value)
                }
            }
        }

        guard count > 0 else {
            throw QuantitativeScalarVolumePickingError.emptySelection
        }
        let mean = total / Double(count)
        let variance = max(0, totalSquares / Double(count) - mean * mean)
        return QuantitativeScalarStatistics(layerID: layer.id,
                                            units: mapping.units,
                                            quantityDefinitions: mapping.quantityDefinitions,
                                            sampleCount: count,
                                            minimumValue: minimum,
                                            maximumValue: maximum,
                                            meanValue: mean,
                                            standardDeviation: variance.squareRoot(),
                                            physicalRange: mapping.physicalRange,
                                            legendTitle: mapping.legendTitle)
    }

    private static func quantitativeValue(in scalarVolume: ScalarVolumeLayer,
                                          mapping: QuantitativeScalarMapping,
                                          atWorldPoint worldPoint: SIMD3<Float>) throws -> QuantitativeScalarValue? {
        let voxel = try VolumePicking.voxelIndex(forWorldPoint: worldPoint,
                                                 in: scalarVolume.dataset)
        let intensity = try VolumePicking.sampleIntensity(in: scalarVolume.dataset,
                                                          atVoxelIndex: voxel.index)
        let linear = linearIndex(voxel.index,
                                 dimensions: scalarVolume.dataset.dimensions)
        return mapping.sample(storedScalar: intensity.storedScalar,
                              linearIndex: linear)
    }

    private static func linearIndex(_ index: SIMD3<Int32>,
                                    dimensions: VolumeDimensions) -> Int {
        Int(index.z) * dimensions.width * dimensions.height
            + Int(index.y) * dimensions.width
            + Int(index.x)
    }

    private static func readUInt16LittleEndian(_ data: Data, atLinearIndex linearIndex: Int) -> UInt16 {
        let byteOffset = linearIndex * MemoryLayout<UInt16>.size
        let low = UInt16(data[byteOffset])
        let high = UInt16(data[byteOffset + 1]) << 8
        return low | high
    }
}
