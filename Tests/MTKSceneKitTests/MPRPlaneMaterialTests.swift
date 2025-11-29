//
//  MPRPlaneMaterialTests.swift
//  MTKTests
//
//  Validates Phase 4 MPR slab uniforms wiring (spacing / thickness / flags)
//  without altering legacy defaults.
//

import XCTest
@testable import MTKSceneKit
import MTKCore
import Metal

final class MPRPlaneMaterialTests: XCTestCase {
    func testSlabUniformsPopulateSpacingAndThickness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on test host")
        }

        let dims = VolumeDimensions(width: 4, height: 3, depth: 2)
        let spacing = VolumeSpacing(x: 0.0005, y: 0.001, z: 0.002) // meters
        let data = Data(count: dims.voxelCount * MemoryLayout<Int16>.stride)
        let dataset = VolumeDataset(
            data: data,
            dimensions: dims,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )

        let material = MPRPlaneMaterial(device: device)
        material.setDataset(device: device, dataset: dataset)
        material.setSlab(thicknessInVoxels: 4, axis: 2, steps: 5)

        var uniforms = material.snapshotUniforms()

        XCTAssertEqual(uniforms.spacingMM.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(uniforms.spacingMM.y, 1.0, accuracy: 1e-5)
        XCTAssertEqual(uniforms.spacingMM.z, 2.0, accuracy: 1e-5)

        XCTAssertEqual(uniforms.volumeSizeMM.x, 2.0, accuracy: 1e-4)
        XCTAssertEqual(uniforms.volumeSizeMM.y, 3.0, accuracy: 1e-4)
        XCTAssertEqual(uniforms.volumeSizeMM.z, 4.0, accuracy: 1e-4)
        XCTAssertEqual(uniforms.slabThicknessMM, 8.0, accuracy: 1e-4) // 4 voxels * 2 mm
        XCTAssertEqual(uniforms.usePhysicalWeighting, 0)
        XCTAssertEqual(uniforms.useBoundsEpsilon, 0)

        material.setPhysicalWeighting(true)
        material.setBoundsEpsilon(enabled: true, epsilon: 5.0e-4)
        uniforms = material.snapshotUniforms()
        XCTAssertEqual(uniforms.usePhysicalWeighting, 1)
        XCTAssertEqual(uniforms.useBoundsEpsilon, 1)
        XCTAssertEqual(uniforms.boundsEpsilon, 5.0e-4, accuracy: 1e-7)
    }
}
