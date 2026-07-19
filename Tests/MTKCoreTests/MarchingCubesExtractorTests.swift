import XCTest
import simd

@testable import MTKCore

final class MarchingCubesExtractorTests: XCTestCase {
    func testScalarThresholdRampProducesFlatTwoTriangleSurface() throws {
        let dataset = makeTwoByTwoDataset(bottom: 0, top: 10)

        let mesh = try MarchingCubesExtractor()
            .extractSurface(from: dataset, threshold: 5)

        XCTAssertEqual(mesh.coordinateSpace, .worldMillimeters)
        XCTAssertEqual(mesh.triangleCount, 2)
        XCTAssertEqual(mesh.vertices.count, 6)
        XCTAssertEqual(mesh.normals.count, mesh.vertices.count)
        XCTAssertEqual(mesh.indices, [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(mesh.isRenderable)
        XCTAssertTrue(mesh.vertices.allSatisfy { abs($0.z - 0.5) < 1e-5 })
        XCTAssertTrue(mesh.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })
    }

    func testLabelmapExtractionIsDeterministicForSyntheticCube() throws {
        let labelmap = try makePaddedCubeLabelmap()
        let extractor = MarchingCubesExtractor()

        let first = try extractor.extractSurface(from: labelmap, label: 1)
        let second = try extractor.extractSurface(from: labelmap, label: 1)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.isRenderable)
        XCTAssertGreaterThan(first.triangleCount, 0)
        XCTAssertTrue(first.indices.allSatisfy { Int($0) < first.vertices.count })
        XCTAssertTrue(first.normals.allSatisfy { normal in
            normal.x.isFinite &&
                normal.y.isFinite &&
                normal.z.isFinite &&
                abs(simd_length(normal) - 1) < 1e-5
        })
    }

    func testLabelmapExtractionCarriesSegmentMetadataAndWorldBounds() throws {
        let labelmap = try makePaddedCubeLabelmap()

        let mesh = try MarchingCubesExtractor()
            .extractSurface(from: labelmap, label: 1)
        let surfaceLayer = SurfaceMeshLayer(id: "surface-cube",
                                            mesh: mesh,
                                            material: .segmentationRed,
                                            opacity: 0.6)
        let mprLayer = VolumeLayer(id: "mpr-cube",
                                   labelmap: labelmap,
                                   opacity: 0.6)

        XCTAssertEqual(mesh.metadata[SurfaceMeshMetadataKey.source], SurfaceMeshMetadataSource.labelmap)
        XCTAssertEqual(mesh.labelmapLabel, 1)
        XCTAssertEqual(mesh.segmentID, "labelmap-1")
        XCTAssertEqual(mesh.segmentName, "Cube")
        XCTAssertEqual(surfaceLayer.labelmapLabel, mprLayer.labelmap?.segments.first?.label)
        XCTAssertEqual(surfaceLayer.segmentID, "labelmap-1")
        XCTAssertEqual(surfaceLayer.clampedOpacity, 0.6, accuracy: 1e-6)

        let bounds = try XCTUnwrap(mesh.bounds)
        XCTAssertEqual(bounds.min.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.x, 2.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 2.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.z, 2.5, accuracy: 1e-5)

        let center = bounds.center
        for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = Int(mesh.indices[triangleStart])
            let i1 = Int(mesh.indices[triangleStart + 1])
            let i2 = Int(mesh.indices[triangleStart + 2])
            let centroid = (mesh.vertices[i0] + mesh.vertices[i1] + mesh.vertices[i2]) / 3
            let normal = mesh.normals[i0]
            XCTAssertGreaterThan(simd_dot(normal, centroid - center), -1e-5)
        }
    }

    func testMissingLabelProducesEmptyMesh() throws {
        let labelmap = try makePaddedCubeLabelmap()

        let mesh = try MarchingCubesExtractor()
            .extractSurface(from: labelmap, label: 7)

        XCTAssertTrue(mesh.vertices.isEmpty)
        XCTAssertTrue(mesh.normals.isEmpty)
        XCTAssertTrue(mesh.indices.isEmpty)
        XCTAssertEqual(mesh.triangleCount, 0)
        XCTAssertFalse(mesh.isRenderable)
    }

    func test_multiLabelExtraction_matchesIndependentMeshes() throws {
        let labelmap = try makeMultiSegmentLabelmap()
        let extractor = MarchingCubesExtractor()

        let combined = try extractor.extractSurfaces(from: labelmap)
        let independent = try labelmap.segments.map { segment in
            try extractor.extractSurface(from: labelmap, label: segment.label)
        }

        XCTAssertEqual(combined, independent)
        XCTAssertEqual(combined.count, labelmap.segments.count)
        XCTAssertTrue(combined.allSatisfy { !$0.vertices.isEmpty && $0.triangleCount > 0 })
        XCTAssertTrue(combined.allSatisfy(\.isRenderable))
    }

    func test_checkerboardFaces_invertedInsideCorners_preserveTwoSurfaceComponents() throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 2)
        let firstValues: [Int16] = [10, 0, 0, 10, 10, 0, 0, 10]
        let secondValues: [Int16] = firstValues.map { 10 - $0 }
        var triangleSignatures: [Set<Set<SIMD3<Float>>>] = []

        for values in [firstValues, secondValues] {
            let dataset = VolumeDataset(
                data: values.withUnsafeBytes { Data($0) },
                dimensions: dimensions,
                spacing: VolumeSpacing(x: 1, y: 1, z: 1),
                pixelFormat: .int16Signed,
                intensityRange: 0...10
            )

            let mesh = try MarchingCubesExtractor().extractSurface(from: dataset, threshold: 5)

            XCTAssertTrue(mesh.isRenderable)
            XCTAssertEqual(connectedComponentCount(in: mesh), 2)
            triangleSignatures.append(triangleSignature(of: mesh))
        }
        XCTAssertNotEqual(triangleSignatures[0], triangleSignatures[1])
    }

    private func triangleSignature(of mesh: SurfaceMesh) -> Set<Set<SIMD3<Float>>> {
        Set(stride(from: 0, to: mesh.indices.count, by: 3).map { triangleStart in
            Set(mesh.indices[triangleStart..<(triangleStart + 3)].map { mesh.vertices[Int($0)] })
        })
    }

    private func connectedComponentCount(in mesh: SurfaceMesh) -> Int {
        var canonicalIDs: [SIMD3<Float>: Int] = [:]
        var adjacency: [Int: Set<Int>] = [:]
        for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
            let triangle = mesh.indices[triangleStart..<(triangleStart + 3)].map { index in
                let position = mesh.vertices[Int(index)]
                if let existing = canonicalIDs[position] {
                    return existing
                }
                let id = canonicalIDs.count
                canonicalIDs[position] = id
                return id
            }
            for vertex in triangle {
                adjacency[vertex, default: []].formUnion(triangle.filter { $0 != vertex })
            }
        }

        var remaining = Set(adjacency.keys)
        var count = 0
        while let seed = remaining.first {
            count += 1
            var stack = [seed]
            remaining.remove(seed)
            while let vertex = stack.popLast() {
                for neighbor in adjacency[vertex, default: []] where remaining.remove(neighbor) != nil {
                    stack.append(neighbor)
                }
            }
        }
        return count
    }

    func testWorldCoordinatesPreserveImageDataAffine() throws {
        let dataset = makeTwoByTwoDataset(
            bottom: 0,
            top: 10,
            spacing: VolumeSpacing(x: 2, y: 3, z: 4),
            orientation: VolumeOrientation(row: SIMD3<Float>(0, 1, 0),
                                           column: SIMD3<Float>(-1, 0, 0),
                                           origin: SIMD3<Float>(10, 20, 30))
        )

        let mesh = try MarchingCubesExtractor()
            .extractSurface(from: dataset, threshold: 5)

        XCTAssertTrue(mesh.vertices.allSatisfy { abs($0.z - 32) < 1e-5 })
        XCTAssertTrue(mesh.vertices.contains { simd_distance($0, SIMD3<Float>(10, 20, 32)) < 1e-5 })
        XCTAssertTrue(mesh.vertices.contains { simd_distance($0, SIMD3<Float>(10, 22, 32)) < 1e-5 })
        XCTAssertTrue(mesh.vertices.contains { simd_distance($0, SIMD3<Float>(7, 20, 32)) < 1e-5 })
    }

    private func makeTwoByTwoDataset(bottom: Int16,
                                     top: Int16,
                                     spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                                     orientation: VolumeOrientation = .canonical) -> VolumeDataset {
        let values: [Int16] = [
            bottom, bottom,
            bottom, bottom,
            top, top,
            top, top
        ]
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: Int32(bottom)...Int32(top),
            orientation: orientation
        )
    }

    private func makePaddedCubeLabelmap() throws -> LabelmapVolume {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        var labels = [UInt16](repeating: 0, count: dimensions.voxelCount)
        for z in 1...2 {
            for y in 1...2 {
                for x in 1...2 {
                    labels[x + y * dimensions.width + z * dimensions.width * dimensions.height] = 1
                }
            }
        }
        let dataset = VolumeDataset(
            data: labels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...1
        )
        return try LabelmapVolume(
            dataset: dataset,
            segments: [LabelmapSegment(label: 1, name: "Cube", color: SIMD4<Float>(1, 0, 0, 1))]
        )
    }

    private func makeMultiSegmentLabelmap() throws -> LabelmapVolume {
        let dimensions = VolumeDimensions(width: 5, height: 4, depth: 4)
        var labels = [UInt16](repeating: 0, count: dimensions.voxelCount)
        labels[1 + dimensions.width + dimensions.width * dimensions.height] = 1
        labels[3 + 2 * dimensions.width + 2 * dimensions.width * dimensions.height] = 2
        let dataset = VolumeDataset(
            data: labels.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...2
        )
        return try LabelmapVolume(
            dataset: dataset,
            segments: [
                LabelmapSegment(label: 1, name: "First", color: SIMD4<Float>(1, 0, 0, 1)),
                LabelmapSegment(label: 2, name: "Second", color: SIMD4<Float>(0, 1, 0, 1))
            ]
        )
    }

}
