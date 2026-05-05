import Foundation
import CoreGraphics
import XCTest
import simd
@_spi(Testing) @testable import MTKCore

final class DICOMGeometryCorpusTests: XCTestCase {
    private let tolerance: Float = 1e-4

    func testManifestDocumentsFixtureStrategyAndRequiredClinicalRisks() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.version, 1)
        XCTAssertTrue(manifest.strategy.storagePolicy.contains("manifest-only"))
        XCTAssertTrue(manifest.strategy.storagePolicy.contains("skipped when unavailable"))
        XCTAssertEqual(manifest.strategy.coordinateSystem, "DICOM patient LPS millimeters")
        XCTAssertEqual(manifest.strategy.toleranceMillimeters, 0.0001, accuracy: 0.00001)
        XCTAssertGreaterThanOrEqual(manifest.fixtures.count, 3)

        let allTags = Set(manifest.fixtures.flatMap(\.tags))
        for requiredTag in [
            "ctAxial",
            "anisotropicSpacing",
            "invertedSliceOrder",
            "nonIdentityIOP",
            "obliqueVolume",
            "mrOrientation",
            "shiftedOrigin",
            "rescaleSlopeIntercept",
            "monochrome1"
        ] {
            XCTAssertTrue(allTags.contains(requiredTag), "Missing corpus tag \(requiredTag)")
        }

        for fixture in manifest.fixtures {
            XCTAssertFalse(fixture.description.isEmpty)
            XCTAssertTrue(fixture.geometrySignature.hasPrefix("sha256:"))
            XCTAssertEqual(fixture.geometrySignature.count, "sha256:".count + 64)
            XCTAssertFalse(fixture.expectedIndexWorldPairs.isEmpty)
            XCTAssertEqual(Set(fixture.expectedMPR.map(\.axis)), Set(["x", "y", "z"]))
        }
    }

    func testIndexToWorldAndWorldToIndexMatchManifestExpectations() throws {
        for fixture in try loadManifest().fixtures {
            let imageData = fixture.makeImageData()

            for pair in fixture.expectedIndexWorldPairs {
                let index = vector(pair.index)
                let expectedWorld = vector(pair.world)
                let actualWorld = imageData.indexToWorld.transformPoint(index)
                let roundTripIndex = imageData.worldToIndex.transformPoint(expectedWorld)

                assertVector(actualWorld, expectedWorld, accuracy: tolerance)
                assertVector(roundTripIndex, index, accuracy: tolerance)
            }
        }
    }

    func testMPRPlanesMatchPatientCoordinatesAcrossAxialCoronalAndSagittal() throws {
        var nonIdentityOrientationCases = 0

        for fixture in try loadManifest().fixtures {
            let dataset = fixture.makeDataset()
            if fixture.tags.contains("nonIdentityIOP") || fixture.tags.contains("obliqueVolume") {
                nonIdentityOrientationCases += 1
            }

            for expectation in fixture.expectedMPR {
                let plane = MPRPlaneGeometryFactory.makePlane(
                    for: dataset,
                    axis: expectation.mprAxis,
                    slicePosition: expectation.slicePosition
                )

                assertVector(plane.originWorld,
                             vector(expectation.originWorld),
                             accuracy: tolerance,
                             "originWorld mismatch for \(fixture.id) \(expectation.axis)")
                assertVector(plane.normalWorld,
                             simd_normalize(vector(expectation.normalWorld)),
                             accuracy: tolerance,
                             "normalWorld mismatch for \(fixture.id) \(expectation.axis)")
                XCTAssertEqual(simd_dot(plane.axisUWorld, plane.normalWorld),
                               0,
                               accuracy: tolerance,
                               "U axis must remain perpendicular for \(fixture.id) \(expectation.axis)")
                XCTAssertEqual(simd_dot(plane.axisVWorld, plane.normalWorld),
                               0,
                               accuracy: tolerance,
                               "V axis must remain perpendicular for \(fixture.id) \(expectation.axis)")
            }
        }

        XCTAssertGreaterThanOrEqual(nonIdentityOrientationCases, 3)
    }

    func testMPRCrosshairPatientPointRoundTripsThroughPicking() throws {
        let viewportSize = CGSize(width: 128, height: 96)

        for fixture in try loadManifest().fixtures {
            let dataset = fixture.makeDataset()

            for expectation in fixture.expectedMPR {
                let plane = MPRPlaneGeometryFactory.makePlane(
                    for: dataset,
                    axis: expectation.mprAxis,
                    slicePosition: expectation.slicePosition
                )
                let expectedWorld = vector(expectation.originWorld)
                let screen = try VolumePicking.screenPoint(forWorldPoint: expectedWorld,
                                                           dataset: dataset,
                                                           plane: plane,
                                                           displayTransform: .identity,
                                                           viewportSize: viewportSize)
                let pick = try VolumePicking.pickMPR(screenPoint: screen.screenPoint,
                                                     viewportSize: screen.viewportSize,
                                                     dataset: dataset,
                                                     plane: plane,
                                                     displayTransform: .identity,
                                                     axis: expectation.mprAxis)

                assertVector(pick.worldPoint,
                             expectedWorld,
                             accuracy: tolerance,
                             "crosshair world point mismatch for \(fixture.id) \(expectation.axis)")
            }
        }
    }

    func testInvertedSliceFixtureWouldFailIfSliceOrderFlipped() throws {
        let fixture = try XCTUnwrap(
            loadManifest().fixtures.first { $0.tags.contains("invertedSliceOrder") }
        )
        let imageData = fixture.makeImageData()
        let firstSliceWorld = imageData.indexToWorld.transformPoint(SIMD3<Float>(0, 0, 0))
        let lastSliceWorld = imageData.indexToWorld.transformPoint(
            SIMD3<Float>(0, 0, Float(fixture.dimensions.depth - 1))
        )

        assertVector(firstSliceWorld, vector(fixture.expectedIndexWorldPairs[0].world), accuracy: tolerance)
        assertVector(lastSliceWorld, vector(fixture.expectedIndexWorldPairs[1].world), accuracy: tolerance)
        XCTAssertLessThan(lastSliceWorld.z, firstSliceWorld.z)
    }
}

private struct DICOMGeometryManifest: Decodable {
    var version: Int
    var strategy: FixtureStrategy
    var fixtures: [DICOMGeometryFixture]
}

private struct FixtureStrategy: Decodable {
    var storagePolicy: String
    var coordinateSystem: String
    var toleranceMillimeters: Double
    var hashPolicy: String
}

private struct DICOMGeometryFixture: Decodable {
    var id: String
    var source: String
    var description: String
    var storage: String
    var modality: String
    var photometricInterpretation: String
    var pixelFormat: String
    var tags: [String]
    var rescaleSlope: Double
    var rescaleIntercept: Double
    var dimensions: FixtureDimensions
    var spacing: FixtureSpacing
    var origin: [Float]
    var row: [Float]
    var column: [Float]
    var geometrySignature: String
    var expectedIndexWorldPairs: [IndexWorldPair]
    var expectedMPR: [MPRExpectation]

    func makeDataset() -> VolumeDataset {
        VolumeDataset(data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
                      imageData: makeImageData())
    }

    func makeImageData() -> ImageData3D {
        let rowVector = vector(row)
        let columnVector = vector(column)
        let sliceVector = ImageData3D.normalizedCross(rowVector,
                                                     columnVector,
                                                     fallback: SIMD3<Float>(0, 0, 1))
        return ImageData3D(
            dimensions: VolumeDimensions(width: dimensions.width,
                                         height: dimensions.height,
                                         depth: dimensions.depth),
            spacing: VolumeSpacing(x: spacing.x, y: spacing.y, z: spacing.z),
            origin: vector(origin),
            direction: simd_float3x3(columns: (rowVector, columnVector, sliceVector)),
            pixelFormat: .int16Signed,
            clinicalMetadata: ClinicalImageMetadata(modality: modality,
                                                    seriesDescription: description,
                                                    rescaleSlope: rescaleSlope,
                                                    rescaleIntercept: rescaleIntercept,
                                                    sourcePixelFormat: .int16Signed)
        )
    }
}

private struct FixtureDimensions: Decodable {
    var width: Int
    var height: Int
    var depth: Int

    var voxelCount: Int { width * height * depth }
}

private struct FixtureSpacing: Decodable {
    var x: Double
    var y: Double
    var z: Double
}

private struct IndexWorldPair: Decodable {
    var index: [Float]
    var world: [Float]
}

private struct MPRExpectation: Decodable {
    var axis: String
    var slicePosition: Float
    var originWorld: [Float]
    var normalWorld: [Float]

    var mprAxis: MPRPlaneAxis {
        switch axis {
        case "x":
            return .x
        case "y":
            return .y
        case "z":
            return .z
        default:
            XCTFail("Unsupported manifest MPR axis \(axis)")
            return .z
        }
    }
}

private func loadManifest(file: StaticString = #filePath,
                          line: UInt = #line) throws -> DICOMGeometryManifest {
    let manifestURL = try XCTUnwrap(
        Bundle.module.url(forResource: "DICOMGeometryManifest", withExtension: "json"),
        file: file,
        line: line
    )
    let data = try Data(contentsOf: manifestURL)
    return try JSONDecoder().decode(DICOMGeometryManifest.self, from: data)
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
