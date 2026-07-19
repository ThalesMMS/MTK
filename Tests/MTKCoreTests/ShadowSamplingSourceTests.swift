import Foundation
import XCTest

final class ShadowSamplingSourceTests: XCTestCase {
    func test_shadowSampleAlphaUsesTrilinearDensity() throws {
        let source = try String(contentsOfFile: sourceFilePath(
            "Sources/MTKCore/Resources/Shaders/volume_rendering_helpers.metal"
        ))
        let start = try XCTUnwrap(source.range(of: "static inline float shadowSampleAlpha"))
        let end = try XCTUnwrap(source.range(of: "static inline float accumulateShadowOpacity",
                                             range: start.upperBound..<source.endIndex))
        let functionSource = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(functionSource.contains("VR::getDensityTrilinear("))
        XCTAssertTrue(functionSource.contains("const float huValue = VR::getDensityTrilinear("))
        XCTAssertTrue(functionSource.contains("short(round(huValue))"))
        XCTAssertFalse(functionSource.contains("VR::getDensity(args.volumeTexture"))
    }
}
