import XCTest
import simd

@testable import MTKCore

final class QuantitativeScalarLayerTests: XCTestCase {
    func testScalarLayerPickingReturnsPhysicalQuantitativeValue() throws {
        let dataset = makeDataset(values: [0, 32768, 65535, 1024])
        let mapping = QuantitativeScalarMapping(
            units: QuantitativeCodedConcept(codeValue: "ml/min/100g",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "mL/min/100 g"),
            quantityDefinitions: [
                QuantitativeQuantityDefinition(
                    conceptCode: QuantitativeCodedConcept(codeValue: "113054",
                                                          codingSchemeDesignator: "DCM",
                                                          codeMeaning: "Perfusion")
                )
            ],
            physicalRange: 10...40,
            storedValueRange: 0...65535,
            physicalValues: [10, 20, 40, 12],
            legendTitle: "Perfusion"
        )
        let scalarVolume = ScalarVolumeLayer(
            dataset: dataset,
            transferFunction: .defaultGrayscale(for: dataset),
            quantitativeMapping: mapping
        )
        let layer = VolumeLayer(id: "perfusion", scalarVolume: scalarVolume)
        let worldPoint = VolumePicking.worldPoint(forVoxelIndex: SIMD3<Float>(1, 0, 0),
                                                  in: dataset)

        let samples = try VolumePicking.sampleScalarVolumes(in: [layer],
                                                            atBaseWorldPoint: worldPoint)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].intensity.storedScalar, 32768)
        let quantitativeValue = try XCTUnwrap(samples[0].quantitativeValue)
        XCTAssertEqual(quantitativeValue.value, 20, accuracy: 1e-6)
        XCTAssertEqual(quantitativeValue.unitsLabel, "mL/min/100 g")
        let legend = try XCTUnwrap(layer.quantitativeLegend)
        XCTAssertEqual(legend.title, "Perfusion")
        XCTAssertEqual(legend.unitsLabel, "mL/min/100 g")
        XCTAssertEqual(legend.physicalRange.lowerBound, 10)
        XCTAssertEqual(legend.physicalRange.upperBound, 40)
    }

    func testQuantitativeMappingFallsBackToStoredRangeInterpolation() throws {
        let mapping = QuantitativeScalarMapping(
            physicalRange: -1...1,
            storedValueRange: 0...100
        )

        XCTAssertEqual(try XCTUnwrap(mapping.physicalValue(storedScalar: 25, linearIndex: nil)), -0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(mapping.physicalValue(storedScalar: 100, linearIndex: nil)), 1, accuracy: 1e-6)
    }

    func testQuantitativeStatisticsMeasureLabelmapROIValues() throws {
        let dataset = makeDataset(values: [10, 20, 30, 40])
        let mapping = QuantitativeScalarMapping(
            units: QuantitativeCodedConcept(codeValue: "g/ml{SUVbw}",
                                            codingSchemeDesignator: "UCUM",
                                            codeMeaning: "SUV body weight"),
            physicalRange: 1...4,
            storedValueRange: 10...40,
            physicalValues: [1, 2, 3, 4],
            legendTitle: "SUV"
        )
        let scalarVolume = ScalarVolumeLayer(
            dataset: dataset,
            transferFunction: .defaultGrayscale(for: dataset),
            quantitativeMapping: mapping
        )
        let scalarLayer = VolumeLayer(id: "pet-suv", scalarVolume: scalarVolume)
        let roiLayer = try makeLabelmapLayer(labels: [7, 0, 7, 0],
                                             dimensions: dataset.dimensions)

        let statistics = try QuantitativeScalarVolumePicking.statistics(in: scalarLayer,
                                                                        roiLayer: roiLayer,
                                                                        label: 7)

        XCTAssertEqual(statistics.layerID, "pet-suv")
        XCTAssertEqual(statistics.sampleCount, 2)
        XCTAssertEqual(statistics.minimumValue, 1, accuracy: 1e-6)
        XCTAssertEqual(statistics.maximumValue, 3, accuracy: 1e-6)
        XCTAssertEqual(statistics.meanValue, 2, accuracy: 1e-6)
        XCTAssertEqual(statistics.standardDeviation, 1, accuracy: 1e-6)
        XCTAssertEqual(statistics.unitsLabel, "SUV body weight")
        XCTAssertEqual(statistics.legendTitle, "SUV")
    }

    private func makeDataset(values: [UInt16]) -> VolumeDataset {
        VolumeDataset(
            data: littleEndianData(from: values),
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...65535
        )
    }

    private func makeLabelmapLayer(labels: [UInt16],
                                   dimensions: VolumeDimensions) throws -> VolumeLayer {
        let dataset = VolumeDataset(
            data: littleEndianData(from: labels),
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...Int32(labels.max() ?? 0)
        )
        let labelmap = try LabelmapVolume(
            dataset: dataset,
            segments: [
                LabelmapSegment(label: 7,
                                color: SIMD4<Float>(1, 0.2, 0.1, 1))
            ]
        )
        return VolumeLayer(id: "roi",
                           labelmap: labelmap)
    }

    private func littleEndianData(from values: [UInt16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }
}
