import XCTest
import simd

@testable import MTKCore

final class RTStructureSurfaceMeshExtractorTests: XCTestCase {
    func testClosedPlanarContoursProduceWorldMillimeterSurfaceLayer() throws {
        let overlay = RTStructureContourOverlay(
            id: "rt",
            contours: [
                makeContour(id: "slice-1", z: 2),
                makeContour(id: "slice-2", z: 6)
            ]
        )

        let layers = RTStructureSurfaceMeshExtractor().extractSurfaceMeshLayers(
            from: overlay,
            options: RTStructureSurfaceMeshOptions(layerIDPrefix: "rt-surface-",
                                                   opacity: 0.45)
        )

        XCTAssertEqual(layers.count, 1)
        let layer = layers[0]
        XCTAssertEqual(layer.id, "rt-surface-roi-7")
        XCTAssertEqual(layer.opacity, 0.45)
        XCTAssertTrue(layer.isVisible)
        XCTAssertEqual(layer.material.color, SIMD4<Float>(0.2, 0.7, 0.1, 1))
        XCTAssertEqual(layer.mesh.coordinateSpace, .worldMillimeters)
        XCTAssertEqual(layer.mesh.metadata[SurfaceMeshMetadataKey.source], SurfaceMeshMetadataSource.rtStructure)
        XCTAssertEqual(layer.mesh.metadata[SurfaceMeshMetadataKey.roiNumber], "7")
        XCTAssertEqual(layer.mesh.segmentID, "rtstruct-roi-7")
        XCTAssertEqual(layer.mesh.segmentName, "Target")
        XCTAssertTrue(layer.mesh.isRenderable)
        XCTAssertEqual(layer.mesh.triangleCount, 12)

        let bounds = try XCTUnwrap(layer.mesh.bounds)
        XCTAssertEqual(bounds.min.x, 10, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.y, 20, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.z, 2, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.x, 30, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 40, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.z, 6, accuracy: 1e-5)
    }

    func testOpenContoursDoNotProduceSurfaceLayers() {
        let overlay = RTStructureContourOverlay(
            id: "rt-open",
            contours: [
                RTStructureContour(id: "open",
                                   roiNumber: 3,
                                   label: "Open",
                                   geometricType: "OPEN_PLANAR",
                                   patientPoints: [
                                       SIMD3<Double>(0, 0, 0),
                                       SIMD3<Double>(1, 0, 0),
                                       SIMD3<Double>(1, 1, 0)
                                   ])
            ]
        )

        let layers = RTStructureSurfaceMeshExtractor().extractSurfaceMeshLayers(from: overlay)

        XCTAssertTrue(layers.isEmpty)
    }

    private func makeContour(id: String, z: Double) -> RTStructureContour {
        RTStructureContour(
            id: id,
            roiNumber: 7,
            label: "Target",
            geometricType: "CLOSED_PLANAR",
            displayColor: SIMD4<Float>(0.2, 0.7, 0.1, 1),
            patientPoints: [
                SIMD3<Double>(10, 20, z),
                SIMD3<Double>(30, 20, z),
                SIMD3<Double>(30, 40, z),
                SIMD3<Double>(10, 40, z)
            ]
        )
    }
}
