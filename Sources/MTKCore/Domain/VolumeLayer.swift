//
//  VolumeLayer.swift
//  MTKCore
//
//  Public volume layer and labelmap overlay contracts.
//

import Foundation
@preconcurrency import Metal
import simd

public enum VolumeLayerBlendMode: Sendable, Equatable {
    case sourceOver
    case additive
}

public struct ScalarVolumeLayer: Sendable, Equatable {
    public var dataset: VolumeDataset
    public var transferFunction: VolumeTransferFunction

    public init(dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction) {
        self.dataset = dataset
        self.transferFunction = transferFunction
    }
}

public struct LabelmapSegment: Sendable, Equatable {
    public var label: UInt16
    public var name: String?
    public var color: SIMD4<Float>
    public var isVisible: Bool

    public init(label: UInt16,
                name: String? = nil,
                color: SIMD4<Float>,
                isVisible: Bool = true) {
        self.label = label
        self.name = name
        self.color = color
        self.isVisible = isVisible
    }
}

public enum LabelmapVolumeError: Error, Equatable, LocalizedError {
    case unsupportedPixelFormat(VolumePixelFormat)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let pixelFormat):
            return "Labelmap volumes require UInt16 scalar labels; got \(pixelFormat.scalarTypeDescription)."
        }
    }
}

public struct LabelmapVolume: Sendable, Equatable {
    public var dataset: VolumeDataset
    public var segments: [LabelmapSegment]

    public init(dataset: VolumeDataset,
                segments: [LabelmapSegment]) throws {
        guard dataset.pixelFormat == .int16Unsigned else {
            throw LabelmapVolumeError.unsupportedPixelFormat(dataset.pixelFormat)
        }
        self.dataset = dataset
        self.segments = segments
    }

    public var segmentsByLabel: [UInt16: LabelmapSegment] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.label, $0) })
    }
}

public struct VolumeLayer: Identifiable, Sendable {
    public enum Content: Sendable, Equatable {
        case scalarVolume(ScalarVolumeLayer)
        case labelmap(LabelmapVolume)
    }

    public var id: String
    public var content: Content
    public var opacity: Float
    public var blendMode: VolumeLayerBlendMode
    public var baseWorldToLayerWorld: simd_float4x4
    public var isVisible: Bool

    public init(id: String = UUID().uuidString,
                labelmap: LabelmapVolume,
                opacity: Float = 1,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4,
                isVisible: Bool = true) {
        self.id = id
        self.content = .labelmap(labelmap)
        self.opacity = opacity
        self.blendMode = blendMode
        self.baseWorldToLayerWorld = baseWorldToLayerWorld
        self.isVisible = isVisible
    }

    public init(id: String = UUID().uuidString,
                scalarVolume: ScalarVolumeLayer,
                opacity: Float = 1,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4,
                isVisible: Bool = true) {
        self.id = id
        self.content = .scalarVolume(scalarVolume)
        self.opacity = opacity
        self.blendMode = blendMode
        self.baseWorldToLayerWorld = baseWorldToLayerWorld
        self.isVisible = isVisible
    }

    public init(id: String = UUID().uuidString,
                dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction,
                opacity: Float = 1,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4,
                isVisible: Bool = true) {
        self.init(id: id,
                  scalarVolume: ScalarVolumeLayer(dataset: dataset,
                                                  transferFunction: transferFunction),
                  opacity: opacity,
                  blendMode: blendMode,
                  baseWorldToLayerWorld: baseWorldToLayerWorld,
                  isVisible: isVisible)
    }

    public var scalarVolume: ScalarVolumeLayer? {
        guard case .scalarVolume(let scalarVolume) = content else { return nil }
        return scalarVolume
    }

    public var labelmap: LabelmapVolume? {
        guard case .labelmap(let labelmap) = content else { return nil }
        return labelmap
    }

    public var clampedOpacity: Float {
        Self.clamp01(opacity)
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

extension VolumeLayer: Equatable {
    public static func == (lhs: VolumeLayer, rhs: VolumeLayer) -> Bool {
        lhs.id == rhs.id &&
            lhs.content == rhs.content &&
            lhs.opacity == rhs.opacity &&
            lhs.blendMode == rhs.blendMode &&
            lhs.baseWorldToLayerWorld.columns.0 == rhs.baseWorldToLayerWorld.columns.0 &&
            lhs.baseWorldToLayerWorld.columns.1 == rhs.baseWorldToLayerWorld.columns.1 &&
            lhs.baseWorldToLayerWorld.columns.2 == rhs.baseWorldToLayerWorld.columns.2 &&
            lhs.baseWorldToLayerWorld.columns.3 == rhs.baseWorldToLayerWorld.columns.3 &&
            lhs.isVisible == rhs.isVisible
    }
}

public enum LabelmapColorLUTError: Error, Equatable, LocalizedError {
    case textureCreationFailed(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case let .textureCreationFailed(width, height):
            return "Failed to create labelmap color lookup texture with size \(width)x\(height)."
        }
    }
}

public enum LabelmapColorLUTBuilder {
    public static let textureWidth = 256
    public static let textureHeight = 256

    public static func colors(for labelmap: LabelmapVolume) -> [SIMD4<Float>] {
        let maxLabel = labelmap.segments
            .map(\.label)
            .filter { $0 > 0 }
            .max() ?? 0
        var colors = Array(repeating: SIMD4<Float>(0, 0, 0, 0),
                           count: max(1, Int(maxLabel) + 1))

        for segment in labelmap.segments.sorted(by: LabelmapSegment.deterministicLUTOrder) {
            guard segment.label > 0,
                  Int(segment.label) < colors.count,
                  segment.isVisible else {
                continue
            }
            colors[Int(segment.label)] = SIMD4<Float>(
                clamp01(segment.color.x),
                clamp01(segment.color.y),
                clamp01(segment.color.z),
                clamp01(segment.color.w)
            )
        }
        return colors
    }

    public static func texture(for labelmap: LabelmapVolume,
                               device: any MTLDevice) throws -> any MTLTexture {
        let colors = fullUInt16ColorTable(for: labelmap)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: textureWidth,
                                                                  height: textureHeight,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LabelmapColorLUTError.textureCreationFailed(width: textureWidth,
                                                              height: textureHeight)
        }
        texture.label = "Labelmap.colorLUT"
        colors.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, textureWidth, textureHeight),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: textureWidth * MemoryLayout<SIMD4<Float>>.stride)
        }
        return texture
    }

    private static func fullUInt16ColorTable(for labelmap: LabelmapVolume) -> [SIMD4<Float>] {
        var colors = Array(repeating: SIMD4<Float>(0, 0, 0, 0),
                           count: textureWidth * textureHeight)
        for segment in labelmap.segments.sorted(by: LabelmapSegment.deterministicLUTOrder) {
            guard segment.label > 0,
                  segment.isVisible else {
                continue
            }
            colors[Int(segment.label)] = SIMD4<Float>(
                clamp01(segment.color.x),
                clamp01(segment.color.y),
                clamp01(segment.color.z),
                clamp01(segment.color.w)
            )
        }
        return colors
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct MPRLabelmapOverlay {
    public var labelmapTexture: any MTLTexture
    public var colorLUTTexture: any MTLTexture
    public var opacity: Float
    public var originTexture: SIMD3<Float>
    public var axisUTexture: SIMD3<Float>
    public var axisVTexture: SIMD3<Float>

    public init(labelmapTexture: any MTLTexture,
                colorLUTTexture: any MTLTexture,
                opacity: Float,
                originTexture: SIMD3<Float>,
                axisUTexture: SIMD3<Float>,
                axisVTexture: SIMD3<Float>) {
        self.labelmapTexture = labelmapTexture
        self.colorLUTTexture = colorLUTTexture
        self.opacity = opacity
        self.originTexture = originTexture
        self.axisUTexture = axisUTexture
        self.axisVTexture = axisVTexture
    }
}

extension MPRLabelmapOverlay: @unchecked Sendable {}

public enum VolumeLayerMPRMapper {
    public static func textureBasis(for labelmap: LabelmapVolume,
                                    baseWorldToLayerWorld: simd_float4x4,
                                    plane: MPRPlaneGeometry) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        let geometry = DICOMGeometry(imageData: labelmap.dataset.imageData)
        let layerOriginWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld)
        let layerUWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld + plane.axisUWorld) - layerOriginWorld
        let layerVWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld + plane.axisVWorld) - layerOriginWorld
        let textureBasis = geometry.planeWorldToTex(originW: layerOriginWorld,
                                                    axisUW: layerUWorld,
                                                    axisVW: layerVWorld)
        return (textureBasis.originT, textureBasis.axisUT, textureBasis.axisVT)
    }

    public static func makeLabelmapOverlay(for layer: VolumeLayer,
                                           baseFrame: MPRTextureFrame,
                                           labelmapTexture: any MTLTexture,
                                           colorLUTTexture: any MTLTexture) -> MPRLabelmapOverlay? {
        guard layer.isVisible,
              layer.blendMode == .sourceOver,
              layer.clampedOpacity > 0,
              let labelmap = layer.labelmap else {
            return nil
        }
        let basis = textureBasis(for: labelmap,
                                 baseWorldToLayerWorld: layer.baseWorldToLayerWorld,
                                 plane: baseFrame.planeGeometry)
        return MPRLabelmapOverlay(labelmapTexture: labelmapTexture,
                                  colorLUTTexture: colorLUTTexture,
                                  opacity: layer.clampedOpacity,
                                  originTexture: basis.origin,
                                  axisUTexture: basis.axisU,
                                  axisVTexture: basis.axisV)
    }
}

public final class VolumeLayerResourceCache {
    private struct DatasetTextureKey: Hashable {
        let count: Int
        let dimensions: VolumeDimensions
        let pixelFormatKey: Int
        let contentFingerprint: UInt64

        init(dataset: VolumeDataset) {
            self.count = dataset.data.count
            self.dimensions = dataset.dimensions
            self.pixelFormatKey = dataset.pixelFormat.hashKey
            self.contentFingerprint = DatasetContentFingerprint.make(for: dataset.data)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(count)
            hasher.combine(dimensions.width)
            hasher.combine(dimensions.height)
            hasher.combine(dimensions.depth)
            hasher.combine(pixelFormatKey)
            hasher.combine(contentFingerprint)
        }
    }

    private struct LUTKey: Hashable {
        struct Entry: Hashable {
            let label: UInt16
            let r: UInt32
            let g: UInt32
            let b: UInt32
            let a: UInt32
            let isVisible: Bool

            init(segment: LabelmapSegment) {
                self.label = segment.label
                self.r = segment.color.x.bitPattern
                self.g = segment.color.y.bitPattern
                self.b = segment.color.z.bitPattern
                self.a = segment.color.w.bitPattern
                self.isVisible = segment.isVisible
            }
        }

        let entries: [Entry]

        init(labelmap: LabelmapVolume) {
            self.entries = labelmap.segments
                .sorted(by: LabelmapSegment.deterministicLUTOrder)
                .map(Entry.init(segment:))
        }
    }

    private let lock = NSLock()
    private var cacheGeneration: UInt64 = 0
    private var labelmapTextures: [DatasetTextureKey: any MTLTexture] = [:]
    private var colorLUTTextures: [LUTKey: any MTLTexture] = [:]

    public init() {}

    public func makeMPRLabelmapOverlays(for layers: [VolumeLayer],
                                        baseFrame: MPRTextureFrame,
                                        device: any MTLDevice,
                                        commandQueue: any MTLCommandQueue) async throws -> [MPRLabelmapOverlay] {
        var overlays: [MPRLabelmapOverlay] = []
        for layer in layers {
            guard layer.isVisible,
                  let labelmap = layer.labelmap else {
                continue
            }
            let labelmapTexture = try await texture(for: labelmap,
                                                    device: device,
                                                    commandQueue: commandQueue)
            let lutTexture = try colorLUTTexture(for: labelmap,
                                                 device: device)
            if let overlay = VolumeLayerMPRMapper.makeLabelmapOverlay(for: layer,
                                                                      baseFrame: baseFrame,
                                                                      labelmapTexture: labelmapTexture,
                                                                      colorLUTTexture: lutTexture) {
                overlays.append(overlay)
            }
        }
        return overlays
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cacheGeneration &+= 1
        labelmapTextures.removeAll()
        colorLUTTextures.removeAll()
    }

    private func texture(for labelmap: LabelmapVolume,
                         device: any MTLDevice,
                         commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        let key = DatasetTextureKey(dataset: labelmap.dataset)
        let cacheState = cachedLabelmapTexture(for: key, device: device)
        if let texture = cacheState.texture {
            return texture
        }

        let texture = try await VolumeTextureFactory(dataset: labelmap.dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        texture.label = "Labelmap.volumeTexture"
        storeLabelmapTexture(texture, for: key, generation: cacheState.generation)
        return texture
    }

    private func colorLUTTexture(for labelmap: LabelmapVolume,
                                 device: any MTLDevice) throws -> any MTLTexture {
        let key = LUTKey(labelmap: labelmap)
        let cacheState = cachedColorLUTTexture(for: key, device: device)
        if let texture = cacheState.texture {
            return texture
        }

        let texture = try LabelmapColorLUTBuilder.texture(for: labelmap,
                                                          device: device)
        storeColorLUTTexture(texture, for: key, generation: cacheState.generation)
        return texture
    }

    private func cachedLabelmapTexture(for key: DatasetTextureKey,
                                       device: any MTLDevice) -> (texture: (any MTLTexture)?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let texture = labelmapTextures[key],
           texture.device === device {
            return (texture, cacheGeneration)
        }
        return (nil, cacheGeneration)
    }

    private func storeLabelmapTexture(_ texture: any MTLTexture,
                                      for key: DatasetTextureKey,
                                      generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == cacheGeneration else {
            return
        }
        labelmapTextures[key] = texture
    }

    private func cachedColorLUTTexture(for key: LUTKey,
                                       device: any MTLDevice) -> (texture: (any MTLTexture)?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let texture = colorLUTTextures[key],
           texture.device === device {
            return (texture, cacheGeneration)
        }
        return (nil, cacheGeneration)
    }

    private func storeColorLUTTexture(_ texture: any MTLTexture,
                                      for key: LUTKey,
                                      generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == cacheGeneration else {
            return
        }
        colorLUTTextures[key] = texture
    }
}

extension VolumeLayerResourceCache: @unchecked Sendable {}

private extension VolumePixelFormat {
    var hashKey: Int {
        switch self {
        case .int16Signed:
            return 0
        case .int16Unsigned:
            return 1
        }
    }
}

private extension LabelmapSegment {
    static func deterministicLUTOrder(lhs: LabelmapSegment, rhs: LabelmapSegment) -> Bool {
        if lhs.label != rhs.label {
            return lhs.label < rhs.label
        }
        let lhsName = lhs.name ?? ""
        let rhsName = rhs.name ?? ""
        if lhsName != rhsName {
            return lhsName < rhsName
        }
        if lhs.color.x.bitPattern != rhs.color.x.bitPattern {
            return lhs.color.x.bitPattern < rhs.color.x.bitPattern
        }
        if lhs.color.y.bitPattern != rhs.color.y.bitPattern {
            return lhs.color.y.bitPattern < rhs.color.y.bitPattern
        }
        if lhs.color.z.bitPattern != rhs.color.z.bitPattern {
            return lhs.color.z.bitPattern < rhs.color.z.bitPattern
        }
        if lhs.color.w.bitPattern != rhs.color.w.bitPattern {
            return lhs.color.w.bitPattern < rhs.color.w.bitPattern
        }
        if lhs.isVisible != rhs.isVisible {
            return lhs.isVisible == false
        }
        return false
    }
}
