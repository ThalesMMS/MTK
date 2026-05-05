//
//  SurfaceMesh.swift
//  MTKCore
//
//  Public minimal surface mesh contracts for segmentation surfaces.
//

import Foundation
import simd

public enum SurfaceMeshCoordinateSpace: String, Sendable, Equatable {
    case worldMillimeters
    case textureNormalized
}

public enum SurfaceMeshMetadataKey {
    public static let source = "source"
    public static let label = "label"
    public static let labelmapLabel = "labelmapLabel"
    public static let segmentID = "segmentID"
    public static let segmentName = "segmentName"
    public static let threshold = "threshold"
}

public enum SurfaceMeshMetadataSource {
    public static let labelmap = "labelmap"
    public static let scalarThreshold = "scalarThreshold"
}

public struct SurfaceMeshBounds: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public var center: SIMD3<Float> {
        (min + max) * 0.5
    }
}

public struct SurfaceMesh: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var vertices: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]
    public var coordinateSpace: SurfaceMeshCoordinateSpace
    public var metadata: [String: String]

    public init(id: String = UUID().uuidString,
                name: String? = nil,
                vertices: [SIMD3<Float>],
                normals: [SIMD3<Float>],
                indices: [UInt32],
                coordinateSpace: SurfaceMeshCoordinateSpace,
                metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.vertices = vertices
        self.normals = normals
        self.indices = indices
        self.coordinateSpace = coordinateSpace
        self.metadata = metadata
    }

    public var triangleCount: Int {
        indices.count / 3
    }

    public var isRenderable: Bool {
        guard !vertices.isEmpty,
              normals.count == vertices.count,
              indices.count.isMultiple(of: 3) else {
            return false
        }
        return indices.allSatisfy { Int($0) < vertices.count }
    }

    public var bounds: SurfaceMeshBounds? {
        guard var minPoint = vertices.first else { return nil }
        var maxPoint = minPoint
        for vertex in vertices.dropFirst() {
            minPoint = simd_min(minPoint, vertex)
            maxPoint = simd_max(maxPoint, vertex)
        }
        return SurfaceMeshBounds(min: minPoint, max: maxPoint)
    }

    public var labelmapLabel: UInt16? {
        metadata[SurfaceMeshMetadataKey.labelmapLabel].flatMap(UInt16.init) ??
            metadata[SurfaceMeshMetadataKey.label].flatMap(UInt16.init)
    }

    public var segmentID: String? {
        metadata[SurfaceMeshMetadataKey.segmentID]
    }

    public var segmentName: String? {
        metadata[SurfaceMeshMetadataKey.segmentName]
    }
}

public struct SurfaceMeshMaterial: Sendable, Equatable {
    public var color: SIMD4<Float>

    public init(color: SIMD4<Float>) {
        self.color = color
    }

    public static let segmentationRed = SurfaceMeshMaterial(color: SIMD4<Float>(1, 0.12, 0.05, 1))
    public static let segmentationBlue = SurfaceMeshMaterial(color: SIMD4<Float>(0.1, 0.45, 1, 1))
}

public struct SurfaceMeshLayer: Identifiable, Sendable, Equatable {
    public var id: String
    public var mesh: SurfaceMesh
    public var material: SurfaceMeshMaterial
    public var opacity: Float
    public var isVisible: Bool

    public init(id: String = UUID().uuidString,
                mesh: SurfaceMesh,
                material: SurfaceMeshMaterial,
                opacity: Float = 1,
                isVisible: Bool = true) {
        self.id = id
        self.mesh = mesh
        self.material = material
        self.opacity = opacity
        self.isVisible = isVisible
    }

    public var clampedOpacity: Float {
        guard opacity.isFinite else { return 0 }
        return min(max(opacity, 0), 1)
    }

    public var labelmapLabel: UInt16? {
        mesh.labelmapLabel
    }

    public var segmentID: String? {
        mesh.segmentID
    }

    public var segmentName: String? {
        mesh.segmentName
    }
}
