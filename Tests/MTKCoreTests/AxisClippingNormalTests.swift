import MTKCore
import XCTest

final class AxisClippingNormalTests: XCTestCase {
    func testAxisTextureCenteredClipNormalsMatchVolumeTextureAxes() {
        XCTAssertEqual(Axis.axial.textureCenteredClipNormal, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(Axis.sagittal.textureCenteredClipNormal, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(Axis.coronal.textureCenteredClipNormal, SIMD3<Float>(0, 1, 0))
    }
}
