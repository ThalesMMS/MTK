import XCTest
@testable import MTKCore
import simd

final class CPRPathTests: XCTestCase {
    func test_sampleStraightCenterline_preservesEndpointsAndPhysicalLength() throws {
        let path = try CPRPathSampler.sample(
            controlPointsWorld: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(0, 0, 100)
            ],
            spacingMillimeters: 2
        )

        assertVectorEqual(try XCTUnwrap(path.samples.first).positionWorld, SIMD3<Float>(0, 0, 0))
        assertVectorEqual(try XCTUnwrap(path.samples.last).positionWorld, SIMD3<Float>(0, 0, 100))
        XCTAssertEqual(path.lengthMillimeters, 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(path.samples.last).distanceMillimeters, 100, accuracy: 0.001)
        assertVectorEqual(path.samples[path.samples.count / 2].tangentWorld,
                          SIMD3<Float>(0, 0, 1))
    }

    func test_sampleCurvedCenterline_usesSmoothedArcLengthInsteadOfChord() throws {
        let path = try CPRPathSampler.sample(
            controlPointsWorld: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(25, 25, 0),
                SIMD3<Float>(50, 0, 0)
            ],
            spacingMillimeters: 1
        )

        XCTAssertGreaterThan(path.lengthMillimeters, 50)
        assertVectorEqual(try XCTUnwrap(path.samples.first).positionWorld, SIMD3<Float>(0, 0, 0))
        assertVectorEqual(try XCTUnwrap(path.samples.last).positionWorld, SIMD3<Float>(50, 0, 0))
        XCTAssertTrue(path.samples.allSatisfy { $0.tangentWorld.isFiniteUnitVector })
    }

    func test_perpendicularPlane_isCenteredOnScrubberAndNormalToPath() throws {
        let dataset = makeDataset()
        let path = try CPRPathSampler.sample(
            controlPointsWorld: [
                SIMD3<Float>(0, 16, 16),
                SIMD3<Float>(31, 16, 16)
            ],
            spacingMillimeters: 1
        )

        let plane = CPRPlaneFactory.makePerpendicularPlane(
            path: path,
            progress: 0.5,
            dataset: dataset,
            outputSize: 64
        )
        let center = plane.originWorld + plane.axisUWorld * 0.5 + plane.axisVWorld * 0.5

        assertVectorEqual(center, SIMD3<Float>(15.5, 16, 16))
        XCTAssertEqual(abs(simd_dot(simd_normalize(plane.normalWorld), SIMD3<Float>(1, 0, 0))),
                       1,
                       accuracy: 0.001)
        XCTAssertEqual(simd_dot(plane.axisUWorld, plane.normalWorld), 0, accuracy: 0.001)
        XCTAssertEqual(simd_dot(plane.axisVWorld, plane.normalWorld), 0, accuracy: 0.001)
    }

    func test_invalidCenterline_rejectsFewerThanTwoDistinctPoints() {
        XCTAssertThrowsError(
            try CPRPathSampler.sample(
                controlPointsWorld: [SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1)],
                spacingMillimeters: 1
            )
        ) { error in
            XCTAssertEqual(error as? CPRPathError, .insufficientDistinctControlPoints)
        }
    }

    private func makeDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 32, height: 32, depth: 32)
        return VolumeDataset(
            data: Data(count: dimensions.voxelCount * MemoryLayout<Int16>.size),
            imageData: ImageData3D(
                dimensions: dimensions,
                spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                origin: .zero,
                direction: matrix_identity_float3x3,
                pixelFormat: .int16Signed
            )
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var isFiniteUnitVector: Bool {
        x.isFinite && y.isFinite && z.isFinite && abs(simd_length(self) - 1) < 0.001
    }
}

private extension XCTestCase {
    func assertVectorEqual(_ lhs: SIMD3<Float>,
                           _ rhs: SIMD3<Float>,
                           accuracy: Float = 0.001,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        XCTAssertLessThanOrEqual(simd_distance(lhs, rhs), accuracy, file: file, line: line)
    }
}
