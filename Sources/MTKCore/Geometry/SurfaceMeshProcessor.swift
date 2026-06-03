//
//  SurfaceMeshProcessor.swift
//  MTKCore
//

import Foundation
import simd

public enum SurfaceMeshProcessor {
    public static func process(_ mesh: SurfaceMesh,
                               options: SurfaceMeshProcessingOptions = .clinicalDefault) -> SurfaceMesh {
        var processed = options.repairsTopology ? repaired(mesh) : mesh
        let iterations = options.clampedSmoothingIterations
        if iterations > 0 {
            processed = smoothed(processed,
                                 iterations: iterations,
                                 relaxation: options.clampedSmoothingRelaxation)
        }
        let decimationRatio = options.clampedDecimationRatio
        if decimationRatio < 0.999 {
            processed = decimated(processed, targetTriangleRatio: decimationRatio)
        }
        return processed
    }

    public static func repaired(_ mesh: SurfaceMesh) -> SurfaceMesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var remappedIndices: [UInt32: UInt32] = [:]

        func appendVertex(_ oldIndex: UInt32) -> UInt32? {
            if let existing = remappedIndices[oldIndex] {
                return existing
            }
            guard let sourceIndex = Int(exactly: oldIndex),
                  mesh.vertices.indices.contains(sourceIndex),
                  mesh.vertices[sourceIndex].surfaceMeshProcessingAllFinite else {
                return nil
            }
            let newIndex = UInt32(vertices.count)
            vertices.append(mesh.vertices[sourceIndex])
            remappedIndices[oldIndex] = newIndex
            return newIndex
        }

        for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard triangleStart + 2 < mesh.indices.count else { continue }
            let original = [
                mesh.indices[triangleStart],
                mesh.indices[triangleStart + 1],
                mesh.indices[triangleStart + 2]
            ]
            guard Set(original).count == 3,
                  let a = appendVertex(original[0]),
                  let b = appendVertex(original[1]),
                  let c = appendVertex(original[2]),
                  !isDegenerateTriangle(vertices[Int(a)], vertices[Int(b)], vertices[Int(c)]) else {
                continue
            }
            indices.append(contentsOf: [a, b, c])
        }

        return makeMeshLike(mesh,
                            vertices: vertices,
                            normals: recomputeNormals(vertices: vertices, indices: indices),
                            indices: indices)
    }

    public static func smoothed(_ mesh: SurfaceMesh,
                                iterations: Int,
                                relaxation: Float = 0.35) -> SurfaceMesh {
        let repairedMesh = repaired(mesh)
        guard repairedMesh.isRenderable else { return repairedMesh }
        let iterations = min(max(iterations, 0), 12)
        guard iterations > 0 else { return repairedMesh }

        let relaxation = min(max(relaxation.isFinite ? relaxation : 0.35, 0), 1)
        let adjacency = adjacencyList(vertices: repairedMesh.vertices, indices: repairedMesh.indices)
        var vertices = repairedMesh.vertices

        for _ in 0..<iterations {
            var next = vertices
            for index in vertices.indices {
                let neighbors = adjacency[index]
                guard !neighbors.isEmpty else { continue }
                let average = neighbors.reduce(SIMD3<Float>.zero) { partial, neighbor in
                    partial + vertices[neighbor]
                } / Float(neighbors.count)
                next[index] = vertices[index] + (average - vertices[index]) * relaxation
            }
            vertices = next
        }

        return makeMeshLike(repairedMesh,
                            vertices: vertices,
                            normals: recomputeNormals(vertices: vertices, indices: repairedMesh.indices),
                            indices: repairedMesh.indices)
    }

    public static func decimated(_ mesh: SurfaceMesh,
                                 targetTriangleRatio: Float) -> SurfaceMesh {
        let repairedMesh = repaired(mesh)
        guard repairedMesh.isRenderable else { return repairedMesh }
        let triangleCount = repairedMesh.triangleCount
        guard triangleCount > 1 else { return repairedMesh }
        let ratio = min(max(targetTriangleRatio.isFinite ? targetTriangleRatio : 1, 0.05), 1)
        let targetCount = max(1, Int((Float(triangleCount) * ratio).rounded()))
        guard targetCount < triangleCount else { return repairedMesh }

        var selected: [UInt32] = []
        selected.reserveCapacity(targetCount * 3)
        for targetIndex in 0..<targetCount {
            let sourceTriangle = min(Int((Float(targetIndex) * Float(triangleCount) / Float(targetCount)).rounded(.down)),
                                     triangleCount - 1)
            let sourceStart = sourceTriangle * 3
            selected.append(repairedMesh.indices[sourceStart])
            selected.append(repairedMesh.indices[sourceStart + 1])
            selected.append(repairedMesh.indices[sourceStart + 2])
        }

        return repaired(makeMeshLike(repairedMesh,
                                     vertices: repairedMesh.vertices,
                                     normals: repairedMesh.normals,
                                     indices: selected))
    }

    private static func makeMeshLike(_ mesh: SurfaceMesh,
                                     vertices: [SIMD3<Float>],
                                     normals: [SIMD3<Float>],
                                     indices: [UInt32]) -> SurfaceMesh {
        SurfaceMesh(id: mesh.id,
                    name: mesh.name,
                    vertices: vertices,
                    normals: normals,
                    indices: indices,
                    coordinateSpace: mesh.coordinateSpace,
                    metadata: mesh.metadata)
    }

    private static func adjacencyList(vertices: [SIMD3<Float>],
                                      indices: [UInt32]) -> [[Int]] {
        var adjacency = Array(repeating: Set<Int>(), count: vertices.count)
        for triangleStart in stride(from: 0, to: indices.count, by: 3) {
            guard triangleStart + 2 < indices.count else { continue }
            let triangle = [
                Int(indices[triangleStart]),
                Int(indices[triangleStart + 1]),
                Int(indices[triangleStart + 2])
            ]
            guard triangle.allSatisfy({ vertices.indices.contains($0) }) else { continue }
            adjacency[triangle[0]].insert(triangle[1])
            adjacency[triangle[0]].insert(triangle[2])
            adjacency[triangle[1]].insert(triangle[0])
            adjacency[triangle[1]].insert(triangle[2])
            adjacency[triangle[2]].insert(triangle[0])
            adjacency[triangle[2]].insert(triangle[1])
        }
        return adjacency.map(Array.init)
    }

    private static func recomputeNormals(vertices: [SIMD3<Float>],
                                         indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
        for triangleStart in stride(from: 0, to: indices.count, by: 3) {
            guard triangleStart + 2 < indices.count else { continue }
            let ia = Int(indices[triangleStart])
            let ib = Int(indices[triangleStart + 1])
            let ic = Int(indices[triangleStart + 2])
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else {
                continue
            }
            let cross = simd_cross(vertices[ib] - vertices[ia], vertices[ic] - vertices[ia])
            let length = simd_length(cross)
            guard length > 1e-7 else { continue }
            let normal = cross / length
            normals[ia] += normal
            normals[ib] += normal
            normals[ic] += normal
        }
        return normals.map { normal in
            let length = simd_length(normal)
            return length > Float.ulpOfOne ? normal / length : SIMD3<Float>(0, 0, 1)
        }
    }

    private static func isDegenerateTriangle(_ a: SIMD3<Float>,
                                             _ b: SIMD3<Float>,
                                             _ c: SIMD3<Float>) -> Bool {
        simd_length(simd_cross(b - a, c - a)) <= 1e-7
    }
}

private extension SIMD3 where Scalar == Float {
    var surfaceMeshProcessingAllFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
