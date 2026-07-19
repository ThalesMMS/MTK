import Foundation
import XCTest

final class EmptySpaceSkippingSourceTests: XCTestCase {
    func test_perStepVisibilityCheckUsesOnePrecomputedPyramidRead() throws {
        let source = try String(contentsOfFile: sourceFilePath(
            "Sources/MTKCore/Resources/Shaders/empty_space_acceleration.metal"
        ))
        let start = try XCTUnwrap(source.range(of: "static inline bool sampleAccelerationStructureAtLevel"))
        let end = try XCTUnwrap(source.range(of: "\n}\n\n} // namespace ESS",
                                             range: start.upperBound..<source.endIndex))
        let functionSource = source[start.lowerBound..<end.upperBound]

        XCTAssertEqual(functionSource.components(separatedBy: "accelerationTexture.read(").count - 1, 1)
        XCTAssertFalse(functionSource.contains("isTransparentInRange"))
        XCTAssertFalse(functionSource.contains("transferTexture"))
    }

    func test_accelerationMetadataIsHoistedOutsideRaymarchLoop() throws {
        let source = try String(contentsOfFile: sourceFilePath(
            "Sources/MTKCore/Resources/Shaders/volume_compute.metal"
        ))
        let loopStart = try XCTUnwrap(source.range(of: "while (distanceTravelled < totalDistance"))
        let beforeLoop = source[..<loopStart.lowerBound]
        let loop = source[loopStart.lowerBound...]

        XCTAssertTrue(beforeLoop.contains("const bool accelerationEnabled"))
        XCTAssertTrue(beforeLoop.contains("get_num_mip_levels()"))
        XCTAssertFalse(loop.contains("get_num_mip_levels()"))
        XCTAssertFalse(loop.contains("const bool accelerationEnabled"))
        XCTAssertEqual(loop.components(separatedBy: "sampleAccelerationStructureAtLevel(").count - 1, 1)
    }
}
