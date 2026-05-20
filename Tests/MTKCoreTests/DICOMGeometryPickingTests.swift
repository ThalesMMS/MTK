import CoreGraphics
import Foundation
import XCTest
import simd

@testable import MTKCore

final class DICOMGeometryPickingTests: XCTestCase {
    private let tolerance: Float = 1e-4

    func testManifestMPRPickingReturnsVoxelPatientCoordinateHUAndLabelAcrossOrientations() throws {
        let viewportSizes = [
            CGSize(width: 96, height: 64),
            CGSize(width: 240, height: 180)
        ]

        for fixture in try loadDICOMGeometryManifest().fixtures where fixture.hasNonIdentityOrientation {
            let dataset = fixture.makeDataset()
            let target = fixture.targetIndex
            let labelLayer = try makeLabelLayer(label: 17,
                                                target: target,
                                                baseDataset: dataset)

            for axis in [MPRPlaneAxis.x, .y, .z] {
                let expectedWorld = dataset.worldPoint(for: target)
                let expectedHU = dataset.storedValue(at: target)
                let plane = MPRPlaneGeometryFactory.makePlane(
                    for: dataset,
                    axis: axis,
                    slicePosition: normalizedSlicePosition(for: axis,
                                                           target: target,
                                                           dimensions: dataset.dimensions)
                )

                for viewportSize in viewportSizes {
                    let screen = try VolumePicking.screenPoint(forWorldPoint: expectedWorld,
                                                               dataset: dataset,
                                                               plane: plane,
                                                               displayTransform: .identity,
                                                               outputAspect: .fill,
                                                               viewportSize: viewportSize)
                    let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                                         viewportSize: viewportSize,
                                                         dataset: dataset,
                                                         plane: plane,
                                                         displayTransform: .identity,
                                                         outputAspect: .fill,
                                                         axis: axis,
                                                         layers: [labelLayer])

                    XCTAssertEqual(pick.hitKind, .mprPlane(axis), fixture.id)
                    XCTAssertEqual(pick.voxel.index, target, fixture.id)
                    XCTAssertEqual(pick.intensity.storedScalar, expectedHU, fixture.id)
                    XCTAssertEqual(pick.intensity.hounsfieldUnits, Float(expectedHU), accuracy: tolerance, fixture.id)
                    XCTAssertEqual(pick.label?.label, 17, fixture.id)
                    assertVector(pick.worldPoint,
                                 expectedWorld,
                                 accuracy: tolerance,
                                 "patient coordinate mismatch for \(fixture.id) \(axis)")
                }
            }
        }
    }

    func testManifestPickingReportsPredictableErrorsOutsideViewportAndVolume() throws {
        let fixture = try XCTUnwrap(loadDICOMGeometryManifest().fixtures.first)
        let dataset = fixture.makeDataset()
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0.5)

        XCTAssertThrowsError(
            try VolumePicking.pickMPR(screenPoint: CGPoint(x: 101, y: 50),
                                      viewportSize: CGSize(width: 100, height: 100),
                                      dataset: dataset,
                                      plane: plane,
                                      displayTransform: .identity,
                                      outputAspect: .fill,
                                      axis: .z)
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .screenPointOutsideViewport)
        }

        XCTAssertThrowsError(
            try VolumePicking.sampleIntensity(in: dataset,
                                              atWorldPoint: dataset.imageData.origin + SIMD3<Float>(1_000, 1_000, 1_000))
        ) { error in
            XCTAssertEqual(error as? VolumePickError, .outsideVolume)
        }
    }

    func testVolume3DPickingReturnsVoxelAndPatientCoordinateForObliqueDataset() throws {
        let fixture = try XCTUnwrap(
            loadDICOMGeometryManifest().fixtures.first { $0.tags.contains("obliqueVolume") }
        )
        let target = SIMD3<Int32>(2, 2, 3)
        let dataset = fixture.makeDataset { index in
            index == target ? 1000 : -1000
        }
        let configuration = Volume3DPickConfiguration(
            camera: VolumeRenderRequest.Camera(position: SIMD3<Float>(0.5, 0.5, 2),
                                               target: SIMD3<Float>(0.5, 0.5, 0.5),
                                               up: SIMD3<Float>(0, 1, 0),
                                               fieldOfView: 45),
            viewportSize: CGSize(width: 100, height: 100),
            transferFunction: visibleTargetTransferFunction(),
            window: -1000...1000,
            samplingDistance: 1.0 / 512.0
        )

        let pick = try VolumePicking.pickVolume3D(screenPoint: CGPoint(x: 50, y: 50),
                                                  dataset: dataset,
                                                  configuration: configuration)

        XCTAssertEqual(pick.hitKind, .volumeVisibleSample)
        XCTAssertEqual(pick.voxel.index, target)
        XCTAssertEqual(pick.intensity.storedScalar, 1000)
        assertVector(dataset.imageData.worldToIndex.transformPoint(pick.worldPoint),
                     pick.voxel.continuousIndex,
                     accuracy: tolerance)
    }
}

private struct DICOMPickingManifest: Decodable {
    var fixtures: [DICOMPickingFixture]
}

private struct DICOMPickingFixture: Decodable {
    var id: String
    var modality: String
    var description: String
    var tags: [String]
    var rescaleSlope: Double
    var rescaleIntercept: Double
    var dimensions: DICOMPickingDimensions
    var spacing: DICOMPickingSpacing
    var origin: [Float]
    var row: [Float]
    var column: [Float]

    var hasNonIdentityOrientation: Bool {
        tags.contains("nonIdentityIOP") || tags.contains("obliqueVolume") || tags.contains("mrOrientation")
    }

    var targetIndex: SIMD3<Int32> {
        SIMD3<Int32>(
            Int32(max(min(dimensions.width - 2, 2), 1)),
            Int32(max(min(dimensions.height - 2, 2), 1)),
            Int32(max(min(dimensions.depth - 1, 3), 1))
        )
    }

    func makeDataset(values: ((SIMD3<Int32>) -> Int16)? = nil) -> VolumeDataset {
        var samples: [Int16] = []
        samples.reserveCapacity(dimensions.voxelCount)
        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let index = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    samples.append(values?(index) ?? Int16(x + y * 10 + z * 100))
                }
            }
        }

        let rowVector = vector(row)
        let columnVector = vector(column)
        let sliceVector = ImageData3D.normalizedCross(rowVector,
                                                     columnVector,
                                                     fallback: SIMD3<Float>(0, 0, 1))
        let imageData = ImageData3D(
            dimensions: VolumeDimensions(width: dimensions.width,
                                         height: dimensions.height,
                                         depth: dimensions.depth),
            spacing: VolumeSpacing(x: spacing.x, y: spacing.y, z: spacing.z),
            origin: vector(origin),
            direction: simd_float3x3(columns: (rowVector, columnVector, sliceVector)),
            pixelFormat: .int16Signed,
            intensityRange: -1000...1000,
            recommendedWindow: -200...300,
            clinicalMetadata: ClinicalImageMetadata(modality: modality,
                                                    seriesDescription: description,
                                                    rescaleSlope: rescaleSlope,
                                                    rescaleIntercept: rescaleIntercept,
                                                    sourcePixelFormat: .int16Signed)
        )
        return VolumeDataset(data: samples.withUnsafeBytes { Data($0) },
                             imageData: imageData)
    }
}

private struct DICOMPickingDimensions: Decodable {
    var width: Int
    var height: Int
    var depth: Int

    var voxelCount: Int { width * height * depth }
}

private struct DICOMPickingSpacing: Decodable {
    var x: Double
    var y: Double
    var z: Double
}

private func loadDICOMGeometryManifest(file: StaticString = #filePath,
                                       line: UInt = #line) throws -> DICOMPickingManifest {
    let manifestURL = try XCTUnwrap(
        Bundle.module.url(forResource: "DICOMGeometryManifest", withExtension: "json"),
        file: file,
        line: line
    )
    let data = try Data(contentsOf: manifestURL)
    return try JSONDecoder().decode(DICOMPickingManifest.self, from: data)
}

private func makeLabelLayer(label: UInt16,
                            target: SIMD3<Int32>,
                            baseDataset: VolumeDataset) throws -> VolumeLayer {
    let dimensions = baseDataset.dimensions
    var values = [UInt16](repeating: 0, count: dimensions.voxelCount)
    let linear = Int(target.z) * dimensions.width * dimensions.height
        + Int(target.y) * dimensions.width
        + Int(target.x)
    values[linear] = label

    var imageData = baseDataset.imageData
    imageData.pixelFormat = .int16Unsigned
    imageData.intensityRange = 0...Int32(label)
    imageData.clinicalMetadata = ClinicalImageMetadata(modality: "SEG",
                                                       seriesDescription: "Picking labelmap",
                                                       sourcePixelFormat: .int16Unsigned)
    let labelDataset = VolumeDataset(data: values.withUnsafeBytes { Data($0) },
                                     imageData: imageData)
    let labelmap = try LabelmapVolume(
        dataset: labelDataset,
        segments: [LabelmapSegment(label: label,
                                   name: "Target",
                                   color: SIMD4<Float>(1, 0, 0, 1))]
    )
    return VolumeLayer(id: "dicom-picking-label",
                       labelmap: labelmap,
                       opacity: 1)
}

private func normalizedSlicePosition(for axis: MPRPlaneAxis,
                                     target: SIMD3<Int32>,
                                     dimensions: VolumeDimensions) -> Float {
    switch axis {
    case .x:
        return normalizedPosition(component: target.x, count: dimensions.width)
    case .y:
        return normalizedPosition(component: target.y, count: dimensions.height)
    case .z:
        return normalizedPosition(component: target.z, count: dimensions.depth)
    }
}

private func normalizedPosition(component: Int32, count: Int) -> Float {
    guard count > 1 else { return 0 }
    return Float(component) / Float(count - 1)
}

private func visibleTargetTransferFunction() -> VolumeTransferFunction {
    VolumeTransferFunction(
        opacityPoints: [
            VolumeTransferFunction.OpacityControlPoint(intensity: -1000, opacity: 0),
            VolumeTransferFunction.OpacityControlPoint(intensity: 999, opacity: 0),
            VolumeTransferFunction.OpacityControlPoint(intensity: 1000, opacity: 1)
        ],
        colourPoints: [
            VolumeTransferFunction.ColourControlPoint(intensity: -1000,
                                                      colour: SIMD4<Float>(0, 0, 0, 1)),
            VolumeTransferFunction.ColourControlPoint(intensity: 1000,
                                                      colour: SIMD4<Float>(1, 1, 1, 1))
        ]
    )
}

private extension VolumeDataset {
    func worldPoint(for index: SIMD3<Int32>) -> SIMD3<Float> {
        imageData.indexToWorld.transformPoint(SIMD3<Float>(Float(index.x),
                                                           Float(index.y),
                                                           Float(index.z)))
    }

    func storedValue(at index: SIMD3<Int32>) -> Int32 {
        let linear = Int(index.z) * dimensions.width * dimensions.height
            + Int(index.y) * dimensions.width
            + Int(index.x)
        return data.withUnsafeBytes { rawBuffer in
            Int32(rawBuffer.bindMemory(to: Int16.self)[linear])
        }
    }
}

private func vector(_ values: [Float]) -> SIMD3<Float> {
    precondition(values.count == 3, "Expected a 3-component vector")
    return SIMD3<Float>(values[0], values[1], values[2])
}

private func assertVector(_ actual: SIMD3<Float>,
                          _ expected: SIMD3<Float>,
                          accuracy: Float,
                          _ message: String = "",
                          file: StaticString = #filePath,
                          line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, message, file: file, line: line)
}
