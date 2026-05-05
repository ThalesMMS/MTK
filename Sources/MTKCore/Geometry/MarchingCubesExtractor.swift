//
//  MarchingCubesExtractor.swift
//  MTKCore
//
//  Deterministic CPU surface extraction from structured volumes.
//

import Foundation
import simd

public enum MarchingCubesExtractorError: Error, Equatable, LocalizedError {
    case invalidDimensions(VolumeDimensions)
    case invalidDataSize(expected: Int, actual: Int)
    case unsupportedPixelFormat(VolumePixelFormat)

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let dimensions):
            return "Marching Cubes requires every dataset dimension to be at least 2 voxels; got \(dimensions)."
        case .invalidDataSize(let expected, let actual):
            return "Dataset voxel data size mismatch: expected \(expected) bytes, got \(actual)."
        case .unsupportedPixelFormat(let pixelFormat):
            return "Marching Cubes does not support \(pixelFormat.scalarTypeDescription) volumes."
        }
    }
}

public struct MarchingCubesExtractor: Sendable {
    public init() {}

    public func extractSurface(from labelmap: LabelmapVolume,
                               label: UInt16,
                               coordinateSpace: SurfaceMeshCoordinateSpace = .worldMillimeters) throws -> SurfaceMesh {
        let dataset = labelmap.dataset
        try validate(dataset)
        let reader = try ScalarReader(dataset: dataset)
        let segment = labelmap.segmentsByLabel[label]
        var metadata = [
            SurfaceMeshMetadataKey.source: SurfaceMeshMetadataSource.labelmap,
            SurfaceMeshMetadataKey.label: String(label),
            SurfaceMeshMetadataKey.labelmapLabel: String(label),
            SurfaceMeshMetadataKey.segmentID: "labelmap-\(label)"
        ]
        if let name = segment?.name, !name.isEmpty {
            metadata[SurfaceMeshMetadataKey.segmentName] = name
        }
        return try extractSurface(
            dataset: dataset,
            isoLevel: 0.5,
            coordinateSpace: coordinateSpace,
            id: "labelmap-\(label)",
            metadata: metadata,
            insideValue: { x, y, z in
                reader.unsignedValue(x: x, y: y, z: z) == label ? 1 : 0
            },
            name: segment?.name
        )
    }

    public func extractSurface(from dataset: VolumeDataset,
                               threshold: Int32,
                               coordinateSpace: SurfaceMeshCoordinateSpace = .worldMillimeters) throws -> SurfaceMesh {
        try validate(dataset)
        let reader = try ScalarReader(dataset: dataset)
        return try extractSurface(
            dataset: dataset,
            isoLevel: Float(threshold),
            coordinateSpace: coordinateSpace,
            id: "scalar-threshold-\(threshold)",
            metadata: [
                SurfaceMeshMetadataKey.source: SurfaceMeshMetadataSource.scalarThreshold,
                SurfaceMeshMetadataKey.threshold: String(threshold)
            ],
            insideValue: { x, y, z in
                reader.floatValue(x: x, y: y, z: z)
            },
            name: "Threshold \(threshold)"
        )
    }

    private func extractSurface(dataset: VolumeDataset,
                                isoLevel: Float,
                                coordinateSpace: SurfaceMeshCoordinateSpace,
                                id: String,
                                metadata: [String: String],
                                insideValue: (Int, Int, Int) -> Float,
                                name: String?) throws -> SurfaceMesh {
        let dimensions = dataset.dimensions
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for z in 0..<(dimensions.depth - 1) {
            for y in 0..<(dimensions.height - 1) {
                for x in 0..<(dimensions.width - 1) {
                    var values = [Float](repeating: 0, count: Self.cornerOffsets.count)
                    var positions = [SIMD3<Float>](repeating: .zero, count: Self.cornerOffsets.count)
                    var inside = [Bool](repeating: false, count: Self.cornerOffsets.count)

                    for corner in Self.cornerOffsets.indices {
                        let offset = Self.cornerOffsets[corner]
                        let vx = x + Int(offset.x)
                        let vy = y + Int(offset.y)
                        let vz = z + Int(offset.z)
                        let value = insideValue(vx, vy, vz)
                        values[corner] = value
                        inside[corner] = value >= isoLevel
                        positions[corner] = SIMD3<Float>(Float(vx), Float(vy), Float(vz))
                    }

                    let insideCount = inside.filter { $0 }.count
                    guard insideCount > 0, insideCount < Self.cornerOffsets.count else {
                        continue
                    }

                    var intersections: [Int: SIMD3<Float>] = [:]
                    for edge in Self.edges.indices {
                        let endpoints = Self.edges[edge]
                        let a = endpoints.0
                        let b = endpoints.1
                        guard inside[a] != inside[b] else { continue }
                        intersections[edge] = Self.interpolate(
                            from: positions[a],
                            valueA: values[a],
                            to: positions[b],
                            valueB: values[b],
                            isoLevel: isoLevel
                        )
                    }

                    let connections = Self.faceConnections(inside: inside,
                                                           intersections: intersections)
                    let polygons = Self.connectedPolygons(from: connections)
                    let insideCenter = Self.center(of: positions.enumerated().compactMap { index, position in
                        inside[index] ? position : nil
                    })

                    for polygon in polygons where polygon.count >= 3 {
                        let polygonPositions = polygon.compactMap { intersections[$0] }
                        guard polygonPositions.count == polygon.count else { continue }
                        appendTriangulatedPolygon(
                            polygonPositions,
                            insideCenter: insideCenter,
                            dataset: dataset,
                            coordinateSpace: coordinateSpace,
                            vertices: &vertices,
                            normals: &normals,
                            indices: &indices
                        )
                    }
                }
            }
        }

        return SurfaceMesh(id: id,
                           name: name,
                           vertices: vertices,
                           normals: normals,
                           indices: indices,
                           coordinateSpace: coordinateSpace,
                           metadata: metadata)
    }

    private func appendTriangulatedPolygon(_ polygon: [SIMD3<Float>],
                                           insideCenter: SIMD3<Float>,
                                           dataset: VolumeDataset,
                                           coordinateSpace: SurfaceMeshCoordinateSpace,
                                           vertices: inout [SIMD3<Float>],
                                           normals: inout [SIMD3<Float>],
                                           indices: inout [UInt32]) {
        let mappedPolygon = polygon.map { map($0, dataset: dataset, coordinateSpace: coordinateSpace) }
        let mappedInsideCenter = map(insideCenter, dataset: dataset, coordinateSpace: coordinateSpace)

        for index in 1..<(mappedPolygon.count - 1) {
            var triangle = [
                mappedPolygon[0],
                mappedPolygon[index],
                mappedPolygon[index + 1]
            ]
            var normal = Self.normal(for: triangle)
            let centroid = Self.center(of: triangle)
            if simd_dot(normal, mappedInsideCenter - centroid) > 0 {
                triangle.swapAt(1, 2)
                normal = -normal
            }
            let start = UInt32(vertices.count)
            vertices.append(contentsOf: triangle)
            normals.append(contentsOf: [normal, normal, normal])
            indices.append(contentsOf: [start, start + 1, start + 2])
        }
    }

    private func map(_ indexPoint: SIMD3<Float>,
                     dataset: VolumeDataset,
                     coordinateSpace: SurfaceMeshCoordinateSpace) -> SIMD3<Float> {
        switch coordinateSpace {
        case .worldMillimeters:
            return dataset.imageData.indexToWorld.transformPoint(indexPoint)
        case .textureNormalized:
            return dataset.imageData.voxelToTexture.transformPoint(indexPoint)
        }
    }

    private func validate(_ dataset: VolumeDataset) throws {
        let dimensions = dataset.dimensions
        guard dimensions.width >= 2,
              dimensions.height >= 2,
              dimensions.depth >= 2 else {
            throw MarchingCubesExtractorError.invalidDimensions(dimensions)
        }
        let expectedSize = dimensions.voxelCount * dataset.pixelFormat.bytesPerVoxel
        guard dataset.data.count == expectedSize else {
            throw MarchingCubesExtractorError.invalidDataSize(expected: expectedSize,
                                                              actual: dataset.data.count)
        }
    }
}

private extension MarchingCubesExtractor {
    static let cornerOffsets: [SIMD3<Int32>] = [
        SIMD3<Int32>(0, 0, 0),
        SIMD3<Int32>(1, 0, 0),
        SIMD3<Int32>(1, 1, 0),
        SIMD3<Int32>(0, 1, 0),
        SIMD3<Int32>(0, 0, 1),
        SIMD3<Int32>(1, 0, 1),
        SIMD3<Int32>(1, 1, 1),
        SIMD3<Int32>(0, 1, 1)
    ]

    static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]

    static let faceEdgeLoops: [[Int]] = [
        [0, 1, 2, 3],
        [4, 5, 6, 7],
        [0, 9, 4, 8],
        [2, 10, 6, 11],
        [3, 11, 7, 8],
        [1, 10, 5, 9]
    ]

    static func interpolate(from a: SIMD3<Float>,
                            valueA: Float,
                            to b: SIMD3<Float>,
                            valueB: Float,
                            isoLevel: Float) -> SIMD3<Float> {
        let denominator = valueB - valueA
        guard abs(denominator) > Float.ulpOfOne else {
            return (a + b) * 0.5
        }
        let t = min(max((isoLevel - valueA) / denominator, 0), 1)
        return a + (b - a) * t
    }

    static func faceConnections(inside: [Bool],
                                intersections: [Int: SIMD3<Float>]) -> [(Int, Int)] {
        var connections: [(Int, Int)] = []
        for face in faceEdgeLoops {
            let crossingEdges = face.filter { intersections[$0] != nil }
            switch crossingEdges.count {
            case 2:
                connections.append((crossingEdges[0], crossingEdges[1]))
            case 4:
                connections.append((crossingEdges[0], crossingEdges[1]))
                connections.append((crossingEdges[2], crossingEdges[3]))
            default:
                continue
            }
        }
        return connections
    }

    static func connectedPolygons(from connections: [(Int, Int)]) -> [[Int]] {
        var adjacency: [Int: [Int]] = [:]
        for connection in connections {
            adjacency[connection.0, default: []].append(connection.1)
            adjacency[connection.1, default: []].append(connection.0)
        }

        var visitedEdges = Set<EdgeKey>()
        var polygons: [[Int]] = []
        for start in adjacency.keys.sorted() {
            guard let firstNeighbor = adjacency[start]?.sorted().first else { continue }
            let firstEdge = EdgeKey(start, firstNeighbor)
            guard !visitedEdges.contains(firstEdge) else { continue }

            var polygon = [start]
            var previous = start
            var current = firstNeighbor
            visitedEdges.insert(firstEdge)

            while current != start {
                polygon.append(current)
                let neighbors = adjacency[current, default: []].sorted()
                guard let next = neighbors.first(where: { $0 != previous }) else {
                    break
                }
                let edge = EdgeKey(current, next)
                if visitedEdges.contains(edge), next != start {
                    break
                }
                visitedEdges.insert(edge)
                previous = current
                current = next
            }

            if polygon.count >= 3 {
                polygons.append(polygon)
            }
        }
        return polygons
    }

    static func center(of points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(SIMD3<Float>.zero, +)
        return sum / Float(points.count)
    }

    static func normal(for triangle: [SIMD3<Float>]) -> SIMD3<Float> {
        let raw = simd_cross(triangle[1] - triangle[0],
                             triangle[2] - triangle[0])
        let length = simd_length(raw)
        guard length > Float.ulpOfOne else {
            return SIMD3<Float>(0, 0, 1)
        }
        return raw / length
    }
}

private struct EdgeKey: Hashable {
    let a: Int
    let b: Int

    init(_ lhs: Int, _ rhs: Int) {
        a = min(lhs, rhs)
        b = max(lhs, rhs)
    }
}

private struct ScalarReader: Sendable {
    let dataset: VolumeDataset

    init(dataset: VolumeDataset) throws {
        switch dataset.pixelFormat {
        case .int16Signed, .int16Unsigned:
            self.dataset = dataset
        }
    }

    func floatValue(x: Int, y: Int, z: Int) -> Float {
        switch dataset.pixelFormat {
        case .int16Signed:
            return Float(signedValue(x: x, y: y, z: z))
        case .int16Unsigned:
            return Float(unsignedValue(x: x, y: y, z: z))
        }
    }

    func signedValue(x: Int, y: Int, z: Int) -> Int16 {
        let byteOffset = linearIndex(x: x, y: y, z: z) * MemoryLayout<Int16>.stride
        return dataset.data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
        }
    }

    func unsignedValue(x: Int, y: Int, z: Int) -> UInt16 {
        let byteOffset = linearIndex(x: x, y: y, z: z) * MemoryLayout<UInt16>.stride
        return dataset.data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self)
        }
    }

    private func linearIndex(x: Int, y: Int, z: Int) -> Int {
        x + y * dataset.dimensions.width + z * dataset.dimensions.width * dataset.dimensions.height
    }
}
