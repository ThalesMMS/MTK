import XCTest
import simd

@testable import MTKCore

final class SurfaceMeshProcessorTests: XCTestCase {
    func testRepairRemovesInvalidDegenerateTrianglesAndCompactsVertices() {
        let mesh = SurfaceMesh(
            id: "repair",
            name: "Repair",
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(2, 2, 2),
                SIMD3<Float>(.nan, 0, 0)
            ],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 5),
            indices: [
                0, 1, 2,
                0, 0, 1,
                1, 4, 2,
                9, 1, 2
            ],
            coordinateSpace: .textureNormalized,
            metadata: [SurfaceMeshMetadataKey.segmentID: "segment-a"]
        )

        let repaired = SurfaceMeshProcessor.repaired(mesh)

        XCTAssertTrue(repaired.isRenderable)
        XCTAssertEqual(repaired.triangleCount, 1)
        XCTAssertEqual(repaired.vertices.count, 3)
        XCTAssertEqual(repaired.indices, [0, 1, 2])
        XCTAssertEqual(repaired.metadata[SurfaceMeshMetadataKey.segmentID], "segment-a")
        XCTAssertTrue(repaired.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
    }

    func testSmoothingMovesInteriorVertexAndKeepsMeshRenderable() {
        let mesh = makePyramidMesh()

        let smoothed = SurfaceMeshProcessor.smoothed(mesh,
                                                     iterations: 1,
                                                     relaxation: 0.5)

        XCTAssertTrue(smoothed.isRenderable)
        XCTAssertEqual(smoothed.triangleCount, mesh.triangleCount)
        XCTAssertNotEqual(smoothed.vertices[4], mesh.vertices[4])
        XCTAssertTrue(smoothed.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
    }

    func testDecimationReducesTrianglesAndPreservesValidTopology() {
        let mesh = makePyramidMesh()

        let decimated = SurfaceMeshProcessor.decimated(mesh, targetTriangleRatio: 0.5)

        XCTAssertTrue(decimated.isRenderable)
        XCTAssertLessThan(decimated.triangleCount, mesh.triangleCount)
        XCTAssertEqual(decimated.triangleCount, 3)
        XCTAssertTrue(decimated.indices.allSatisfy { Int($0) < decimated.vertices.count })
    }

    func testProcessingOptionsComposeRepairSmoothingAndDecimation() {
        let mesh = makePyramidMesh()
        let options = SurfaceMeshProcessingOptions(repairsTopology: true,
                                                   smoothingIterations: 1,
                                                   smoothingRelaxation: 0.25,
                                                   decimationRatio: 0.5)

        let processed = SurfaceMeshProcessor.process(mesh, options: options)

        XCTAssertTrue(processed.isRenderable)
        XCTAssertEqual(processed.triangleCount, 3)
        XCTAssertEqual(processed.id, mesh.id)
        XCTAssertEqual(processed.name, mesh.name)
    }

    func testMaterialShadingDefaultsClampForRendererInput() {
        let shading = SurfaceMeshShading(lightingEnabled: true,
                                         ambientIntensity: -1,
                                         diffuseIntensity: 3,
                                         specularIntensity: 2,
                                         shininess: 500)

        XCTAssertEqual(shading.clampedAmbientIntensity, 0)
        XCTAssertEqual(shading.clampedDiffuseIntensity, 2)
        XCTAssertEqual(shading.clampedSpecularIntensity, 1)
        XCTAssertEqual(shading.clampedShininess, 128)
    }

    private func makePyramidMesh() -> SurfaceMesh {
        SurfaceMesh(
            id: "pyramid",
            name: "Pyramid",
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0.5, 0.5, 1)
            ],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 5),
            indices: [
                0, 1, 4,
                1, 2, 4,
                2, 3, 4,
                3, 0, 4,
                0, 2, 1,
                0, 3, 2
            ],
            coordinateSpace: .textureNormalized,
            metadata: [:]
        )
    }
}
