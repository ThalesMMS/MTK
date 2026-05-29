import Foundation
import XCTest
import simd

@testable import MTKCore

final class RTDoseVolumeOverlayTests: XCTestCase {
    func testDoseColorLookupTableBuildsStoredScalarTransferFunction() throws {
        let dataset = makeDoseDataset(values: [0, 100, 200, 300],
                                      dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
                                      intensityRange: 0...300)
        let table = RTDoseColorLookupTable(stops: [
            RTDoseColorStop(doseValue: 0, color: SIMD4<Float>(0, 0, 0, 0)),
            RTDoseColorStop(doseValue: 1, color: SIMD4<Float>(1, 0, 0, 0.5)),
            RTDoseColorStop(doseValue: 3, color: SIMD4<Float>(1, 1, 0, 1))
        ])

        let overlay = RTDoseVolumeOverlay(id: "dose",
                                          dataset: dataset,
                                          doseUnits: "GY",
                                          doseGridScaling: 0.01,
                                          colorLookupTable: table,
                                          opacity: 1.4)
        let scalar = try XCTUnwrap(overlay.volumeLayer.scalarVolume)

        XCTAssertEqual(overlay.volumeLayer.clampedOpacity, 1)
        XCTAssertEqual(overlay.doseUnits, "GY")
        XCTAssertEqual(scalar.transferFunction.opacityPoints.map(\.intensity), [0, 100, 300])
        XCTAssertEqual(scalar.transferFunction.opacityPoints.map(\.opacity), [0, 0.5, 1])
    }

    func testSamplesDoseAtBaseWorldPointThroughLayerTransform() throws {
        let dataset = makeDoseDataset(values: [10, 20],
                                      dimensions: VolumeDimensions(width: 2, height: 1, depth: 1),
                                      intensityRange: 10...20)
        var baseWorldToDoseWorld = matrix_identity_float4x4
        baseWorldToDoseWorld.columns.3.x = 1
        let overlay = RTDoseVolumeOverlay(id: "dose",
                                          dataset: dataset,
                                          doseUnits: "GY",
                                          doseGridScaling: 0.1,
                                          baseWorldToLayerWorld: baseWorldToDoseWorld)

        let sample = try overlay.sampleDose(atBaseWorldPoint: SIMD3<Float>(0, 0, 0))

        XCTAssertEqual(sample.layerID, "dose")
        XCTAssertEqual(sample.voxel.index, SIMD3<Int32>(1, 0, 0))
        XCTAssertEqual(sample.storedScalar, 20)
        XCTAssertEqual(sample.doseValue, 2.0, accuracy: 1e-6)
        XCTAssertEqual(sample.doseUnits, "GY")
    }

    func testDoseStatisticsSampleLabelmapROI() throws {
        let doseDataset = makeDoseDataset(values: [10, 20, 30, 40],
                                          dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
                                          intensityRange: 10...40)
        let overlay = RTDoseVolumeOverlay(id: "dose",
                                          dataset: doseDataset,
                                          doseUnits: "GY",
                                          doseGridScaling: 0.1)
        let labelmap = try LabelmapVolume(
            dataset: makeLabelmapDataset(values: [0, 7, 7, 0],
                                         dimensions: VolumeDimensions(width: 2, height: 2, depth: 1)),
            segments: [LabelmapSegment(label: 7,
                                       name: "Target",
                                       color: SIMD4<Float>(1, 0, 0, 1))]
        )
        let roiLayer = VolumeLayer(id: "roi", labelmap: labelmap)

        let stats = try overlay.doseStatistics(in: roiLayer, label: 7)

        XCTAssertEqual(stats.sampleCount, 2)
        XCTAssertEqual(stats.minimumDose, 2.0, accuracy: 1e-6)
        XCTAssertEqual(stats.maximumDose, 3.0, accuracy: 1e-6)
        XCTAssertEqual(stats.meanDose, 2.5, accuracy: 1e-6)
        XCTAssertEqual(stats.standardDeviation, 0.5, accuracy: 1e-6)
    }

    private func makeDoseDataset(values: [UInt16],
                                 dimensions: VolumeDimensions,
                                 intensityRange: ClosedRange<Int32>) -> VolumeDataset {
        VolumeDataset(data: littleEndianData(values),
                      dimensions: dimensions,
                      spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                      pixelFormat: .int16Unsigned,
                      intensityRange: intensityRange,
                      clinicalMetadata: ClinicalImageMetadata(modality: "RTDOSE"))
    }

    private func makeLabelmapDataset(values: [UInt16],
                                     dimensions: VolumeDimensions) -> VolumeDataset {
        VolumeDataset(data: littleEndianData(values),
                      dimensions: dimensions,
                      spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                      pixelFormat: .int16Unsigned,
                      intensityRange: 0...7)
    }

    private func littleEndianData(_ values: [UInt16]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<UInt16>.size)
        for value in values {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }
}
