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
        try extractLabelSurfaces(from: labelmap,
                                 labels: [label],
                                 coordinateSpace: coordinateSpace)[0]
    }

    public func extractSurfaces(
        from labelmap: LabelmapVolume,
        coordinateSpace: SurfaceMeshCoordinateSpace = .worldMillimeters
    ) throws -> [SurfaceMesh] {
        try extractLabelSurfaces(from: labelmap,
                                 labels: labelmap.segments.map(\.label),
                                 coordinateSpace: coordinateSpace)
    }

    public func extractSurface(from dataset: VolumeDataset,
                               threshold: Int32,
                               coordinateSpace: SurfaceMeshCoordinateSpace = .worldMillimeters) throws -> SurfaceMesh {
        try validate(dataset)
        return dataset.data.withUnsafeBytes { rawBuffer in
            switch dataset.pixelFormat {
            case .int16Signed:
                return extractScalarSurface(dataset: dataset,
                                            values: rawBuffer.bindMemory(to: Int16.self),
                                            threshold: threshold,
                                            coordinateSpace: coordinateSpace)
            case .int16Unsigned:
                return extractScalarSurface(dataset: dataset,
                                            values: rawBuffer.bindMemory(to: UInt16.self),
                                            threshold: threshold,
                                            coordinateSpace: coordinateSpace)
            }
        }
    }

    private func extractLabelSurfaces(from labelmap: LabelmapVolume,
                                      labels: [UInt16],
                                      coordinateSpace: SurfaceMeshCoordinateSpace) throws -> [SurfaceMesh] {
        guard !labels.isEmpty else { return [] }
        let dataset = labelmap.dataset
        try validate(dataset)
        guard dataset.pixelFormat == .int16Unsigned else {
            throw MarchingCubesExtractorError.unsupportedPixelFormat(dataset.pixelFormat)
        }

        var accumulators = labels.map {
            labelAccumulator(label: $0,
                             labelmap: labelmap,
                             coordinateSpace: coordinateSpace)
        }
        var accumulatorIndexByLabel: [UInt16: Int] = [:]
        accumulatorIndexByLabel.reserveCapacity(labels.count)
        for (index, label) in labels.enumerated() where accumulatorIndexByLabel[label] == nil {
            accumulatorIndexByLabel[label] = index
        }

        dataset.data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: UInt16.self)
            let dimensions = dataset.dimensions
            var scratch = CubeScratch()
            var cornerLabels = SIMD8<UInt16>(repeating: 0)
            var candidateAccumulatorIndices = SIMD8<Int32>(repeating: -1)

            for z in 0..<(dimensions.depth - 1) {
                for y in 0..<(dimensions.height - 1) {
                    for x in 0..<(dimensions.width - 1) {
                        var candidateCount = 0
                        for corner in Self.cornerOffsets.indices {
                            let offset = Self.cornerOffsets[corner]
                            let index = Self.linearIndex(x: x + Int(offset.x),
                                                         y: y + Int(offset.y),
                                                         z: z + Int(offset.z),
                                                         dimensions: dimensions)
                            let label = values[index]
                            cornerLabels[corner] = label
                            guard let accumulatorIndex = accumulatorIndexByLabel[label] else { continue }
                            var isDuplicate = false
                            for candidate in 0..<candidateCount where
                                candidateAccumulatorIndices[candidate] == Int32(accumulatorIndex) {
                                isDuplicate = true
                            }
                            if !isDuplicate {
                                candidateAccumulatorIndices[candidateCount] = Int32(accumulatorIndex)
                                candidateCount += 1
                            }
                        }

                        for candidate in 0..<candidateCount {
                            let accumulatorIndex = Int(candidateAccumulatorIndices[candidate])
                            let label = labels[accumulatorIndex]
                            for corner in Self.cornerOffsets.indices {
                                scratch.values[corner] = cornerLabels[corner] == label ? 1 : 0
                            }
                            appendCubeSurface(x: x,
                                              y: y,
                                              z: z,
                                              isoLevel: 0.5,
                                              dataset: dataset,
                                              coordinateSpace: coordinateSpace,
                                              accumulator: &accumulators[accumulatorIndex],
                                              scratch: &scratch)
                        }
                    }
                }
            }
        }

        return accumulators.map(\.mesh)
    }

    private func extractScalarSurface<Scalar: BinaryInteger>(
        dataset: VolumeDataset,
        values: UnsafeBufferPointer<Scalar>,
        threshold: Int32,
        coordinateSpace: SurfaceMeshCoordinateSpace
    ) -> SurfaceMesh {
        let dimensions = dataset.dimensions
        var accumulator = MeshAccumulator(
            id: "scalar-threshold-\(threshold)",
            name: "Threshold \(threshold)",
            metadata: [
                SurfaceMeshMetadataKey.source: SurfaceMeshMetadataSource.scalarThreshold,
                SurfaceMeshMetadataKey.threshold: String(threshold)
            ],
            coordinateSpace: coordinateSpace
        )
        var scratch = CubeScratch()

        for z in 0..<(dimensions.depth - 1) {
            for y in 0..<(dimensions.height - 1) {
                for x in 0..<(dimensions.width - 1) {
                    for corner in Self.cornerOffsets.indices {
                        let offset = Self.cornerOffsets[corner]
                        let index = Self.linearIndex(x: x + Int(offset.x),
                                                     y: y + Int(offset.y),
                                                     z: z + Int(offset.z),
                                                     dimensions: dimensions)
                        scratch.values[corner] = Float(values[index])
                    }
                    appendCubeSurface(x: x,
                                      y: y,
                                      z: z,
                                      isoLevel: Float(threshold),
                                      dataset: dataset,
                                      coordinateSpace: coordinateSpace,
                                      accumulator: &accumulator,
                                      scratch: &scratch)
                }
            }
        }

        return accumulator.mesh
    }

    private func appendCubeSurface(x: Int,
                                   y: Int,
                                   z: Int,
                                   isoLevel: Float,
                                   dataset: VolumeDataset,
                                   coordinateSpace: SurfaceMeshCoordinateSpace,
                                   accumulator: inout MeshAccumulator,
                                   scratch: inout CubeScratch) {
        var insideMask: UInt8 = 0
        var insidePositionSum = SIMD3<Float>.zero
        var insideCount = 0
        for corner in Self.cornerOffsets.indices where scratch.values[corner] >= isoLevel {
            insideMask |= UInt8(1 << corner)
            insidePositionSum += Self.cornerPosition(x: x, y: y, z: z, corner: corner)
            insideCount += 1
        }
        guard insideMask != 0, insideMask != UInt8.max else { return }

        scratch.resetGraph()
        for edge in Self.edges.indices {
            let endpoints = Self.edges[edge]
            let a = endpoints.0
            let b = endpoints.1
            let aIsInside = insideMask & UInt8(1 << a) != 0
            let bIsInside = insideMask & UInt8(1 << b) != 0
            guard aIsInside != bIsInside else { continue }
            scratch.intersections[edge] = Self.interpolate(
                from: Self.cornerPosition(x: x, y: y, z: z, corner: a),
                valueA: scratch.values[a],
                to: Self.cornerPosition(x: x, y: y, z: z, corner: b),
                valueB: scratch.values[b],
                isoLevel: isoLevel
            )
            scratch.intersectionMask |= UInt16(1 << edge)
        }

        for face in Self.faceEdgeLoops {
            var crossingEdges = SIMD4<Int32>(repeating: -1)
            var crossingCount = 0
            for edge in face where scratch.intersectionMask & UInt16(1 << edge) != 0 {
                crossingEdges[crossingCount] = Int32(edge)
                crossingCount += 1
            }
            if crossingCount == 2 {
                scratch.addConnection(Int(crossingEdges[0]), Int(crossingEdges[1]))
            } else if crossingCount == 4 {
                let firstEdge = Int(crossingEdges[0])
                let secondEdge = Int(crossingEdges[1])
                let thirdEdge = Int(crossingEdges[2])
                let fourthEdge = Int(crossingEdges[3])
                let sharedCorner = Self.sharedCorner(between: firstEdge, and: secondEdge)
                let sharedCornerIsInside = insideMask & UInt8(1 << sharedCorner) != 0
                if sharedCornerIsInside {
                    scratch.addConnection(firstEdge, secondEdge)
                    scratch.addConnection(thirdEdge, fourthEdge)
                } else {
                    scratch.addConnection(firstEdge, fourthEdge)
                    scratch.addConnection(secondEdge, thirdEdge)
                }
            }
        }

        let insideCenter = insidePositionSum / Float(insideCount)
        for start in Self.edges.indices {
            guard let first = scratch.firstNeighbor(of: start),
                  !scratch.isConnectionVisited(first.connection) else {
                continue
            }

            var polygonCount = 1
            scratch.polygon[0] = Int32(start)
            var previous = start
            var current = first.neighbor
            scratch.markConnectionVisited(first.connection)

            while current != start, polygonCount < Self.edges.count {
                scratch.polygon[polygonCount] = Int32(current)
                polygonCount += 1
                guard let next = scratch.nextNeighbor(of: current, excluding: previous) else {
                    break
                }
                if scratch.isConnectionVisited(next.connection), next.neighbor != start {
                    break
                }
                scratch.markConnectionVisited(next.connection)
                previous = current
                current = next.neighbor
            }

            if polygonCount >= 3 {
                appendTriangulatedPolygon(scratch.polygon,
                                          count: polygonCount,
                                          intersections: scratch.intersections,
                                          insideCenter: insideCenter,
                                          dataset: dataset,
                                          coordinateSpace: coordinateSpace,
                                          accumulator: &accumulator)
            }
        }
    }

    private func appendTriangulatedPolygon(_ polygon: SIMD16<Int32>,
                                           count: Int,
                                           intersections: [SIMD3<Float>],
                                           insideCenter: SIMD3<Float>,
                                           dataset: VolumeDataset,
                                           coordinateSpace: SurfaceMeshCoordinateSpace,
                                           accumulator: inout MeshAccumulator) {
        let first = map(intersections[Int(polygon[0])],
                        dataset: dataset,
                        coordinateSpace: coordinateSpace)
        let mappedInsideCenter = map(insideCenter, dataset: dataset, coordinateSpace: coordinateSpace)

        for index in 1..<(count - 1) {
            var second = map(intersections[Int(polygon[index])],
                             dataset: dataset,
                             coordinateSpace: coordinateSpace)
            var third = map(intersections[Int(polygon[index + 1])],
                            dataset: dataset,
                            coordinateSpace: coordinateSpace)
            var normal = Self.normal(first, second, third)
            let centroid = (first + second + third) / 3
            if simd_dot(normal, mappedInsideCenter - centroid) > 0 {
                swap(&second, &third)
                normal = -normal
            }
            let start = UInt32(accumulator.vertices.count)
            accumulator.vertices.append(first)
            accumulator.vertices.append(second)
            accumulator.vertices.append(third)
            accumulator.normals.append(normal)
            accumulator.normals.append(normal)
            accumulator.normals.append(normal)
            accumulator.indices.append(start)
            accumulator.indices.append(start + 1)
            accumulator.indices.append(start + 2)
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

    private func labelAccumulator(label: UInt16,
                                  labelmap: LabelmapVolume,
                                  coordinateSpace: SurfaceMeshCoordinateSpace) -> MeshAccumulator {
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
        return MeshAccumulator(id: "labelmap-\(label)",
                               name: segment?.name,
                               metadata: metadata,
                               coordinateSpace: coordinateSpace)
    }
}

private struct MeshAccumulator {
    let id: String
    let name: String?
    let metadata: [String: String]
    let coordinateSpace: SurfaceMeshCoordinateSpace
    var vertices: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var mesh: SurfaceMesh {
        SurfaceMesh(id: id,
                    name: name,
                    vertices: vertices,
                    normals: normals,
                    indices: indices,
                    coordinateSpace: coordinateSpace,
                    metadata: metadata)
    }
}

private struct CubeScratch {
    var values = SIMD8<Float>(repeating: 0)
    var intersections = [SIMD3<Float>](repeating: .zero, count: 12)
    var intersectionMask: UInt16 = 0
    var firstNeighbors = SIMD16<Int32>(repeating: -1)
    var secondNeighbors = SIMD16<Int32>(repeating: -1)
    var firstConnectionIndices = SIMD16<Int32>(repeating: -1)
    var secondConnectionIndices = SIMD16<Int32>(repeating: -1)
    var polygon = SIMD16<Int32>(repeating: -1)
    var connectionCount = 0
    var visitedConnections: UInt16 = 0

    mutating func resetGraph() {
        intersectionMask = 0
        firstNeighbors = SIMD16<Int32>(repeating: -1)
        secondNeighbors = SIMD16<Int32>(repeating: -1)
        firstConnectionIndices = SIMD16<Int32>(repeating: -1)
        secondConnectionIndices = SIMD16<Int32>(repeating: -1)
        connectionCount = 0
        visitedConnections = 0
    }

    mutating func addConnection(_ first: Int, _ second: Int) {
        let connection = connectionCount
        connectionCount += 1
        addNeighbor(second, connection: connection, to: first)
        addNeighbor(first, connection: connection, to: second)
    }

    func firstNeighbor(of node: Int) -> (neighbor: Int, connection: Int)? {
        let first = Int(firstNeighbors[node])
        guard first >= 0 else { return nil }
        let second = Int(secondNeighbors[node])
        if second >= 0, second < first {
            return (second, Int(secondConnectionIndices[node]))
        }
        return (first, Int(firstConnectionIndices[node]))
    }

    func nextNeighbor(of node: Int, excluding previous: Int) -> (neighbor: Int, connection: Int)? {
        let first = Int(firstNeighbors[node])
        let second = Int(secondNeighbors[node])
        let firstIsCandidate = first >= 0 && first != previous
        let secondIsCandidate = second >= 0 && second != previous
        if firstIsCandidate, secondIsCandidate {
            if first <= second {
                return (first, Int(firstConnectionIndices[node]))
            }
            return (second, Int(secondConnectionIndices[node]))
        }
        if firstIsCandidate {
            return (first, Int(firstConnectionIndices[node]))
        }
        if secondIsCandidate {
            return (second, Int(secondConnectionIndices[node]))
        }
        return nil
    }

    func isConnectionVisited(_ connection: Int) -> Bool {
        visitedConnections & UInt16(1 << connection) != 0
    }

    mutating func markConnectionVisited(_ connection: Int) {
        visitedConnections |= UInt16(1 << connection)
    }

    private mutating func addNeighbor(_ neighbor: Int, connection: Int, to node: Int) {
        if firstNeighbors[node] < 0 {
            firstNeighbors[node] = Int32(neighbor)
            firstConnectionIndices[node] = Int32(connection)
        } else {
            secondNeighbors[node] = Int32(neighbor)
            secondConnectionIndices[node] = Int32(connection)
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

    static func linearIndex(x: Int,
                            y: Int,
                            z: Int,
                            dimensions: VolumeDimensions) -> Int {
        x + y * dimensions.width + z * dimensions.width * dimensions.height
    }

    static func sharedCorner(between firstEdge: Int, and secondEdge: Int) -> Int {
        let first = edges[firstEdge]
        let second = edges[secondEdge]
        return first.0 == second.0 || first.0 == second.1 ? first.0 : first.1
    }

    static func cornerPosition(x: Int, y: Int, z: Int, corner: Int) -> SIMD3<Float> {
        let offset = cornerOffsets[corner]
        return SIMD3<Float>(Float(x + Int(offset.x)),
                            Float(y + Int(offset.y)),
                            Float(z + Int(offset.z)))
    }

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

    static func normal(_ first: SIMD3<Float>,
                       _ second: SIMD3<Float>,
                       _ third: SIMD3<Float>) -> SIMD3<Float> {
        let raw = simd_cross(second - first, third - first)
        let length = simd_length(raw)
        guard length > Float.ulpOfOne else {
            return SIMD3<Float>(0, 0, 1)
        }
        return raw / length
    }
}
