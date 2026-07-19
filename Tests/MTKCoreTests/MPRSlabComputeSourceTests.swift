import XCTest

final class MPRSlabComputeSourceTests: XCTestCase {
    func test_shader_usesPrecomputedSlabInvariants() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Resources/MPR/mpr_slab_compute.metal"))

        XCTAssertTrue(source.contains("float3 planeNormal;"))
        XCTAssertTrue(source.contains("float slabSpan;"))
        XCTAssertTrue(source.contains("float invStepsMinusOne;"))
        XCTAssertFalse(source.contains("normalize(cross(uniforms.planeX, uniforms.planeY))"))
    }
}
