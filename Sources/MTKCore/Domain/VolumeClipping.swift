//
//  VolumeClipping.swift
//  MTK
//
//  Public crop and clip contract for Metal-native volume rendering.
//

import Foundation
import simd

public enum VolumeClippingError: Error, Equatable, LocalizedError {
    case nonFiniteCropBounds
    case cropBoundsOutOfRange
    case invertedCropBounds(axis: String)
    case invalidVoxelIndexBounds
    case nonFiniteClipPlane
    case degenerateClipPlaneNormal
    case invalidClipPlanePreset(Int)
    case tooManyClipPlanes(maximum: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .nonFiniteCropBounds:
            return "Crop bounds must be finite."
        case .cropBoundsOutOfRange:
            return "Crop bounds must be normalized texture values in [0, 1]."
        case .invertedCropBounds(let axis):
            return "Crop lower bound must be less than or equal to the upper bound for axis \(axis)."
        case .invalidVoxelIndexBounds:
            return "Voxel crop bounds must be inside the dataset dimensions."
        case .nonFiniteClipPlane:
            return "Clip plane normal and distance must be finite."
        case .degenerateClipPlaneNormal:
            return "Clip plane normal must have non-zero length."
        case .invalidClipPlanePreset(let preset):
            return "Clip plane preset must be 0 (off), 1 (axial), 2 (sagittal), or 3 (coronal); got \(preset)."
        case .tooManyClipPlanes(let maximum, let actual):
            return "Volume clipping supports at most \(maximum) clip planes; got \(actual)."
        }
    }
}

/// Axis-aligned crop box in normalized dataset texture coordinates.
///
/// The crop box is aligned to dataset IJK axes. Bounds are normalized texture
/// coordinates in `[0, 1]`, where `(0, 0, 0)` and `(1, 1, 1)` are the full
/// texture extent. Crop affects 3D volume/projection rendering and visible-only
/// 3D picking; it does not clip MPR reslices or crosshair state.
public struct VolumeCropBox: Sendable, Equatable, Codable {
    public var textureMin: SIMD3<Float>
    public var textureMax: SIMD3<Float>

    public init(textureMin: SIMD3<Float>, textureMax: SIMD3<Float>) throws {
        try Self.validate(textureMin: textureMin, textureMax: textureMax)
        self.textureMin = textureMin
        self.textureMax = textureMax
    }

    /// Creates a crop box from inclusive voxel-index bounds.
    ///
    /// For example, in a 10-voxel-wide volume, `inclusiveVoxelMin.x == 0` and
    /// `inclusiveVoxelMax.x == 9` maps to the full texture range `0...1`.
    public init(inclusiveVoxelMin: SIMD3<Int32>,
                inclusiveVoxelMax: SIMD3<Int32>,
                dimensions: VolumeDimensions) throws {
        guard let width = Int32(exactly: dimensions.width),
              let height = Int32(exactly: dimensions.height),
              let depth = Int32(exactly: dimensions.depth),
              width > 0, height > 0, depth > 0,
              inclusiveVoxelMin.x >= 0,
              inclusiveVoxelMin.y >= 0,
              inclusiveVoxelMin.z >= 0,
              inclusiveVoxelMax.x < width,
              inclusiveVoxelMax.y < height,
              inclusiveVoxelMax.z < depth,
              inclusiveVoxelMin.x <= inclusiveVoxelMax.x,
              inclusiveVoxelMin.y <= inclusiveVoxelMax.y,
              inclusiveVoxelMin.z <= inclusiveVoxelMax.z else {
            throw VolumeClippingError.invalidVoxelIndexBounds
        }

        let dims = SIMD3<Float>(Float(dimensions.width),
                                Float(dimensions.height),
                                Float(dimensions.depth))
        let textureMin = SIMD3<Float>(Float(inclusiveVoxelMin.x),
                                      Float(inclusiveVoxelMin.y),
                                      Float(inclusiveVoxelMin.z)) / dims
        let textureMax = SIMD3<Float>(Float(inclusiveVoxelMax.x + 1),
                                      Float(inclusiveVoxelMax.y + 1),
                                      Float(inclusiveVoxelMax.z + 1)) / dims
        try self.init(textureMin: textureMin, textureMax: textureMax)
    }

    public static let full = VolumeCropBox(uncheckedTextureMin: .zero,
                                           textureMax: SIMD3<Float>(repeating: 1))

    public var isFullExtent: Bool {
        textureMin == .zero && textureMax == SIMD3<Float>(repeating: 1)
    }

    public func contains(textureCoordinate: SIMD3<Float>) -> Bool {
        textureCoordinate.x >= textureMin.x && textureCoordinate.x <= textureMax.x &&
            textureCoordinate.y >= textureMin.y && textureCoordinate.y <= textureMax.y &&
            textureCoordinate.z >= textureMin.z && textureCoordinate.z <= textureMax.z
    }

    var clipBoundsSnapshot: ClipBoundsSnapshot {
        ClipBoundsSnapshot(xMin: textureMin.x,
                           xMax: textureMax.x,
                           yMin: textureMin.y,
                           yMax: textureMax.y,
                           zMin: textureMin.z,
                           zMax: textureMax.z)
    }

    private init(uncheckedTextureMin textureMin: SIMD3<Float>, textureMax: SIMD3<Float>) {
        self.textureMin = textureMin
        self.textureMax = textureMax
    }

    private static func validate(textureMin: SIMD3<Float>, textureMax: SIMD3<Float>) throws {
        guard textureMin.allFinite, textureMax.allFinite else {
            throw VolumeClippingError.nonFiniteCropBounds
        }
        guard textureMin.allInUnitRange, textureMax.allInUnitRange else {
            throw VolumeClippingError.cropBoundsOutOfRange
        }
        guard textureMin.x <= textureMax.x else {
            throw VolumeClippingError.invertedCropBounds(axis: "x")
        }
        guard textureMin.y <= textureMax.y else {
            throw VolumeClippingError.invertedCropBounds(axis: "y")
        }
        guard textureMin.z <= textureMax.z else {
            throw VolumeClippingError.invertedCropBounds(axis: "z")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case xMin, xMax, yMin, yMax, zMin, zMax
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            textureMin: SIMD3<Float>(
                try container.decode(Float.self, forKey: .xMin),
                try container.decode(Float.self, forKey: .yMin),
                try container.decode(Float.self, forKey: .zMin)
            ),
            textureMax: SIMD3<Float>(
                try container.decode(Float.self, forKey: .xMax),
                try container.decode(Float.self, forKey: .yMax),
                try container.decode(Float.self, forKey: .zMax)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(textureMin.x, forKey: .xMin)
        try container.encode(textureMax.x, forKey: .xMax)
        try container.encode(textureMin.y, forKey: .yMin)
        try container.encode(textureMax.y, forKey: .yMax)
        try container.encode(textureMin.z, forKey: .zMin)
        try container.encode(textureMax.z, forKey: .zMax)
    }
}

/// World-space clipping plane for 3D volume/projection rendering.
///
/// The equation is `dot(normalWorld, worldPoint) + distanceWorld == 0`, in
/// patient/world millimeters. The positive side of the plane is clipped. The
/// normal is normalized at construction time.
public struct VolumeClipPlane: Sendable, Equatable, Codable {
    public var normalWorld: SIMD3<Float>
    public var distanceWorld: Float

    public init(worldNormal: SIMD3<Float>, distance: Float) throws {
        guard worldNormal.allFinite, distance.isFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }
        let length = simd_length(worldNormal)
        guard length > Float.ulpOfOne else {
            throw VolumeClippingError.degenerateClipPlaneNormal
        }
        self.normalWorld = worldNormal / length
        self.distanceWorld = distance / length
    }

    public init(worldNormal: SIMD3<Float>, pointOnPlane: SIMD3<Float>) throws {
        guard pointOnPlane.allFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }
        try self.init(worldNormal: worldNormal,
                      distance: -simd_dot(worldNormal, pointOnPlane))
    }

    /// Creates a world-space plane from a normalized texture-centered plane.
    ///
    /// The input equation is `dot(normal, textureCoordinate - 0.5) - offset == 0`.
    public init(textureCenteredNormal: SIMD3<Float>,
                offset: Float,
                dataset: VolumeDataset) throws {
        guard textureCenteredNormal.allFinite, offset.isFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }
        let centeredPlane = SIMD4<Float>(textureCenteredNormal.x,
                                         textureCenteredNormal.y,
                                         textureCenteredNormal.z,
                                         -offset)
        let worldToCenteredTexture = Self.centeringMatrix(offset: -0.5) * dataset.imageData.worldToTexture
        let worldPlane = simd_transpose(worldToCenteredTexture) * centeredPlane
        try self.init(worldNormal: SIMD3<Float>(worldPlane.x, worldPlane.y, worldPlane.z),
                      distance: worldPlane.w)
    }

    func textureCenteredPlane(for dataset: VolumeDataset) throws -> SIMD4<Float> {
        let textureToWorld = simd_inverse(dataset.imageData.worldToTexture)
        let centeredTextureToWorld = textureToWorld * Self.centeringMatrix(offset: 0.5)
        let worldPlane = SIMD4<Float>(normalWorld.x,
                                      normalWorld.y,
                                      normalWorld.z,
                                      distanceWorld)
        let centeredPlane = simd_transpose(centeredTextureToWorld) * worldPlane
        let normal = SIMD3<Float>(centeredPlane.x, centeredPlane.y, centeredPlane.z)
        let length = simd_length(normal)
        guard length > Float.ulpOfOne else {
            throw VolumeClippingError.degenerateClipPlaneNormal
        }
        return SIMD4<Float>(normal / length, centeredPlane.w / length)
    }

    private static func centeringMatrix(offset: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(offset, offset, offset, 1)
        ))
    }

    private enum CodingKeys: String, CodingKey {
        case normalX, normalY, normalZ, distance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let normal = SIMD3<Float>(
            try container.decode(Float.self, forKey: .normalX),
            try container.decode(Float.self, forKey: .normalY),
            try container.decode(Float.self, forKey: .normalZ)
        )
        let distance = try container.decode(Float.self, forKey: .distance)
        guard normal.allFinite, distance.isFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }
        let length = simd_length(normal)
        guard length > Float.ulpOfOne else {
            throw VolumeClippingError.degenerateClipPlaneNormal
        }
        if abs(length - 1) <= 1e-5 {
            self.normalWorld = normal
            self.distanceWorld = distance
        } else {
            self.normalWorld = normal / length
            self.distanceWorld = distance / length
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalWorld.x, forKey: .normalX)
        try container.encode(normalWorld.y, forKey: .normalY)
        try container.encode(normalWorld.z, forKey: .normalZ)
        try container.encode(distanceWorld, forKey: .distance)
    }
}

/// Public clipping state for volume rendering requests and viewports.
public struct VolumeClippingState: Sendable, Equatable, Codable {
    public static let maxClipPlanes = 3
    public static let disabled = VolumeClippingState(uncheckedCropBox: nil, clipPlanes: [])

    public var cropBox: VolumeCropBox?
    public var clipPlanes: [VolumeClipPlane]

    public init(cropBox: VolumeCropBox? = nil,
                clipPlanes: [VolumeClipPlane] = []) throws {
        guard clipPlanes.count <= Self.maxClipPlanes else {
            throw VolumeClippingError.tooManyClipPlanes(maximum: Self.maxClipPlanes,
                                                        actual: clipPlanes.count)
        }
        self.cropBox = cropBox
        self.clipPlanes = clipPlanes
    }

    public var isDisabled: Bool {
        cropBox == nil && clipPlanes.isEmpty
    }

    public func contains(textureCoordinate: SIMD3<Float>) -> Bool {
        guard let cropBox else { return true }
        return cropBox.contains(textureCoordinate: textureCoordinate)
    }

    func shaderCropBounds() -> ClipBoundsSnapshot {
        (cropBox ?? .full).clipBoundsSnapshot
    }

    func shaderClipPlanes(for dataset: VolumeDataset) throws -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let planes = try clipPlanes.map { try $0.textureCenteredPlane(for: dataset) }
        return (
            planes.indices.contains(0) ? planes[0] : .zero,
            planes.indices.contains(1) ? planes[1] : .zero,
            planes.indices.contains(2) ? planes[2] : .zero
        )
    }

    private init(uncheckedCropBox cropBox: VolumeCropBox?,
                 clipPlanes: [VolumeClipPlane]) {
        self.cropBox = cropBox
        self.clipPlanes = clipPlanes
    }
}

public extension ClipBoundsSnapshot {
    init(cropBox: VolumeCropBox) {
        self = cropBox.clipBoundsSnapshot
    }

    func volumeCropBox() throws -> VolumeCropBox {
        try VolumeCropBox(textureMin: SIMD3<Float>(xMin, yMin, zMin),
                          textureMax: SIMD3<Float>(xMax, yMax, zMax))
    }
}

public extension ClipPlaneSnapshot {
    func volumeClipPlane(for dataset: VolumeDataset) throws -> VolumeClipPlane? {
        guard preset != 0 else { return nil }
        let normal: SIMD3<Float>
        switch preset {
        case 1:
            normal = SIMD3<Float>(0, 0, 1)
        case 2:
            normal = SIMD3<Float>(1, 0, 0)
        case 3:
            normal = SIMD3<Float>(0, 1, 0)
        default:
            return nil
        }
        return try VolumeClipPlane(textureCenteredNormal: normal,
                                   offset: offset,
                                   dataset: dataset)
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    var allInUnitRange: Bool {
        x >= 0 && x <= 1 &&
            y >= 0 && y <= 1 &&
            z >= 0 && z <= 1
    }
}
