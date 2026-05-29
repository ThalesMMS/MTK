//
//  RTStructureSurfaceMeshExtractor.swift
//  MTKCore
//
//  Surface mesh extraction for closed planar RT structure contours.
//

import Foundation
import simd

public struct RTStructureSurfaceMeshOptions: Equatable, Sendable {
    public var layerIDPrefix: String?
    public var opacity: Float
    public var isVisible: Bool

    public init(layerIDPrefix: String? = nil,
                opacity: Float = 1,
                isVisible: Bool = true) {
        self.layerIDPrefix = layerIDPrefix
        self.opacity = opacity
        self.isVisible = isVisible
    }
}

public struct RTStructureSurfaceMeshExtractor: Sendable {
    public init() {}

    public func extractSurfaceMeshLayers(
        from overlay: RTStructureContourOverlay,
        options: RTStructureSurfaceMeshOptions = RTStructureSurfaceMeshOptions()
    ) -> [SurfaceMeshLayer] {
        let rings = overlay.contours.compactMap(Self.makeRing(from:))
        let grouped = Dictionary(grouping: rings, by: \.roiNumber)
        let idPrefix = options.layerIDPrefix ?? "\(overlay.id)-surface-"

        return grouped.keys.sorted().compactMap { roiNumber in
            guard let roiRings = grouped[roiNumber],
                  let mesh = Self.makeMesh(from: roiRings,
                                           overlayID: overlay.id,
                                           roiNumber: roiNumber),
                  mesh.isRenderable else {
                return nil
            }
            let firstRing = roiRings[0]
            return SurfaceMeshLayer(id: "\(idPrefix)roi-\(roiNumber)",
                                    mesh: mesh,
                                    material: SurfaceMeshMaterial(color: firstRing.color),
                                    opacity: options.opacity,
                                    isVisible: overlay.isVisible && options.isVisible)
        }
    }
}

private extension RTStructureSurfaceMeshExtractor {
    struct Ring {
        var contourID: String
        var roiNumber: Int
        var label: String
        var color: SIMD4<Float>
        var points: [SIMD3<Float>]
        var normal: SIMD3<Float>
        var centroid: SIMD3<Float>
    }

    static func makeRing(from contour: RTStructureContour) -> Ring? {
        guard contour.isClosedPlanar else { return nil }
        var points = contour.patientPoints.compactMap(Self.finitePoint)
        if points.count >= 2,
           simd_distance(points[0], points[points.count - 1]) <= 0.0001 {
            points.removeLast()
        }
        guard points.count >= 3,
              let normal = polygonNormal(for: points) else {
            return nil
        }
        return Ring(contourID: contour.id,
                    roiNumber: contour.roiNumber,
                    label: contour.label,
                    color: contour.displayColor,
                    points: points,
                    normal: normal,
                    centroid: center(of: points))
    }

    static func makeMesh(from rings: [Ring],
                         overlayID: String,
                         roiNumber: Int) -> SurfaceMesh? {
        guard let firstRing = rings.first else { return nil }
        let sortedRings = sort(rings)
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        if sortedRings.count > 1,
           sortedRings.allSatisfy({ $0.points.count == firstRing.points.count }) {
            appendCap(sortedRings[0], reverseWinding: true,
                      vertices: &vertices, normals: &normals, indices: &indices)
            appendCap(sortedRings[sortedRings.count - 1], reverseWinding: false,
                      vertices: &vertices, normals: &normals, indices: &indices)
            appendSideWalls(sortedRings,
                            vertices: &vertices, normals: &normals, indices: &indices)
        } else {
            for ring in sortedRings {
                appendCap(ring, reverseWinding: false,
                          vertices: &vertices, normals: &normals, indices: &indices)
            }
        }

        let metadata = [
            SurfaceMeshMetadataKey.source: SurfaceMeshMetadataSource.rtStructure,
            SurfaceMeshMetadataKey.roiNumber: String(roiNumber),
            SurfaceMeshMetadataKey.segmentID: "rtstruct-roi-\(roiNumber)",
            SurfaceMeshMetadataKey.segmentName: firstRing.label
        ]
        return SurfaceMesh(id: "\(overlayID).roi-\(roiNumber)-surface",
                           name: firstRing.label,
                           vertices: vertices,
                           normals: normals,
                           indices: indices,
                           coordinateSpace: .worldMillimeters,
                           metadata: metadata)
    }

    static func sort(_ rings: [Ring]) -> [Ring] {
        guard let normal = rings.first?.normal else { return rings }
        return rings.sorted { lhs, rhs in
            let lhsPosition = simd_dot(lhs.centroid, normal)
            let rhsPosition = simd_dot(rhs.centroid, normal)
            if lhsPosition == rhsPosition {
                return lhs.contourID < rhs.contourID
            }
            return lhsPosition < rhsPosition
        }
    }

    static func appendCap(_ ring: Ring,
                          reverseWinding: Bool,
                          vertices: inout [SIMD3<Float>],
                          normals: inout [SIMD3<Float>],
                          indices: inout [UInt32]) {
        guard ring.points.count >= 3 else { return }
        for index in 1..<(ring.points.count - 1) {
            let triangle = reverseWinding
                ? [ring.points[0], ring.points[index + 1], ring.points[index]]
                : [ring.points[0], ring.points[index], ring.points[index + 1]]
            appendTriangle(triangle[0], triangle[1], triangle[2],
                           fallbackNormal: ring.normal,
                           vertices: &vertices,
                           normals: &normals,
                           indices: &indices)
        }
    }

    static func appendSideWalls(_ rings: [Ring],
                                vertices: inout [SIMD3<Float>],
                                normals: inout [SIMD3<Float>],
                                indices: inout [UInt32]) {
        guard rings.count >= 2 else { return }
        for ringIndex in 0..<(rings.count - 1) {
            let lower = rings[ringIndex].points
            let upper = rings[ringIndex + 1].points
            guard lower.count == upper.count else { continue }
            for pointIndex in lower.indices {
                let next = pointIndex == lower.count - 1 ? 0 : pointIndex + 1
                appendTriangle(lower[pointIndex], lower[next], upper[next],
                               fallbackNormal: rings[ringIndex].normal,
                               vertices: &vertices,
                               normals: &normals,
                               indices: &indices)
                appendTriangle(lower[pointIndex], upper[next], upper[pointIndex],
                               fallbackNormal: rings[ringIndex].normal,
                               vertices: &vertices,
                               normals: &normals,
                               indices: &indices)
            }
        }
    }

    static func appendTriangle(_ a: SIMD3<Float>,
                               _ b: SIMD3<Float>,
                               _ c: SIMD3<Float>,
                               fallbackNormal: SIMD3<Float>,
                               vertices: inout [SIMD3<Float>],
                               normals: inout [SIMD3<Float>],
                               indices: inout [UInt32]) {
        let cross = simd_cross(b - a, c - a)
        let crossLength = simd_length(cross)
        let normal = crossLength > Float.ulpOfOne ? cross / crossLength : fallbackNormal
        let start = UInt32(vertices.count)
        vertices.append(contentsOf: [a, b, c])
        normals.append(contentsOf: [normal, normal, normal])
        indices.append(contentsOf: [start, start + 1, start + 2])
    }

    static func polygonNormal(for points: [SIMD3<Float>]) -> SIMD3<Float>? {
        var normal = SIMD3<Float>.zero
        for index in points.indices {
            let current = points[index]
            let next = points[index == points.count - 1 ? 0 : index + 1]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        let length = simd_length(normal)
        guard length > Float.ulpOfOne else { return nil }
        return normal / length
    }

    static func center(of points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    }

    static func finitePoint(_ point: SIMD3<Double>) -> SIMD3<Float>? {
        guard point.x.isFinite,
              point.y.isFinite,
              point.z.isFinite else {
            return nil
        }
        return SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
    }
}
