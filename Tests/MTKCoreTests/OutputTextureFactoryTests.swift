import Metal
import XCTest

@testable import MTKCore

final class OutputTextureFactoryTests: XCTestCase {
    func testRenderTargetDescriptorUsesPrivateBGRAOutputContract() {
        let descriptor = OutputTextureFactory.descriptor(width: 320, height: 240)

        XCTAssertEqual(descriptor.textureType, .type2D)
        XCTAssertEqual(descriptor.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(descriptor.width, 320)
        XCTAssertEqual(descriptor.height, 240)
        XCTAssertFalse(descriptor.mipmapLevelCount > 1)
        XCTAssertEqual(descriptor.storageMode, .private)
        XCTAssertTrue(descriptor.usage.contains(.shaderRead))
        XCTAssertTrue(descriptor.usage.contains(.shaderWrite))
        XCTAssertTrue(descriptor.usage.contains(.renderTarget))
        XCTAssertTrue(descriptor.usage.contains(.pixelFormatView))
    }

    func testShaderOnlyDescriptorOmitsRenderTargetUsage() {
        let descriptor = OutputTextureFactory.descriptor(width: 128,
                                                         height: 64,
                                                         usage: OutputTextureFactory.shaderUsage)

        XCTAssertTrue(descriptor.usage.contains(.shaderRead))
        XCTAssertTrue(descriptor.usage.contains(.shaderWrite))
        XCTAssertFalse(descriptor.usage.contains(.renderTarget))
    }
}
