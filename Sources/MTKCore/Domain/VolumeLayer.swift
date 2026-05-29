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
    public var quantitativeMapping: QuantitativeScalarMapping?

    public init(dataset: VolumeDataset,
                transferFunction: VolumeTransferFunction,
                quantitativeMapping: QuantitativeScalarMapping? = nil) {
        self.dataset = dataset
        self.transferFunction = transferFunction
        self.quantitativeMapping = quantitativeMapping
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
                quantitativeMapping: QuantitativeScalarMapping? = nil,
                opacity: Float = 1,
                blendMode: VolumeLayerBlendMode = .sourceOver,
                baseWorldToLayerWorld: simd_float4x4 = matrix_identity_float4x4,
                isVisible: Bool = true) {
        self.init(id: id,
                  scalarVolume: ScalarVolumeLayer(dataset: dataset,
                                                  transferFunction: transferFunction,
                                                  quantitativeMapping: quantitativeMapping),
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

    public var quantitativeMapping: QuantitativeScalarMapping? {
        scalarVolume?.quantitativeMapping
    }

    public var quantitativeLegend: QuantitativeScalarLayerLegend? {
        quantitativeMapping?.legend(forLayerID: id)
    }

    public var clampedOpacity: Float {
        Self.clamp01(opacity)
    }

    public func settingLabelmapSegmentVisibility(label: UInt16,
                                                 isVisible: Bool) -> VolumeLayer {
        var layer = self
        layer.setLabelmapSegmentVisibility(label: label, isVisible: isVisible)
        return layer
    }

    public mutating func setLabelmapSegmentVisibility(label: UInt16,
                                                      isVisible: Bool) {
        guard case .labelmap(var labelmap) = content,
              let index = labelmap.segments.firstIndex(where: { $0.label == label }) else {
            return
        }
        labelmap.segments[index].isVisible = isVisible
        content = .labelmap(labelmap)
    }

    public func settingLabelmapSegmentOpacity(label: UInt16,
                                              opacity: Float) -> VolumeLayer {
        var layer = self
        layer.setLabelmapSegmentOpacity(label: label, opacity: opacity)
        return layer
    }

    public mutating func setLabelmapSegmentOpacity(label: UInt16,
                                                   opacity: Float) {
        guard case .labelmap(var labelmap) = content,
              let index = labelmap.segments.firstIndex(where: { $0.label == label }) else {
            return
        }
        labelmap.segments[index].color.w = Self.clamp01(opacity)
        content = .labelmap(labelmap)
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

public struct MPRScalarVolumeOverlay {
    public var scalarTexture: any MTLTexture
    public var colorLUTTexture: any MTLTexture
    public var pixelFormat: VolumePixelFormat
    public var opacity: Float
    public var blendMode: VolumeLayerBlendMode
    public var intensityRange: ClosedRange<Int32>
    public var originTexture: SIMD3<Float>
    public var axisUTexture: SIMD3<Float>
    public var axisVTexture: SIMD3<Float>

    public init(scalarTexture: any MTLTexture,
                colorLUTTexture: any MTLTexture,
                pixelFormat: VolumePixelFormat,
                opacity: Float,
                blendMode: VolumeLayerBlendMode,
                intensityRange: ClosedRange<Int32>,
                originTexture: SIMD3<Float>,
                axisUTexture: SIMD3<Float>,
                axisVTexture: SIMD3<Float>) {
        self.scalarTexture = scalarTexture
        self.colorLUTTexture = colorLUTTexture
        self.pixelFormat = pixelFormat
        self.opacity = opacity
        self.blendMode = blendMode
        self.intensityRange = intensityRange
        self.originTexture = originTexture
        self.axisUTexture = axisUTexture
        self.axisVTexture = axisVTexture
    }
}

extension MPRScalarVolumeOverlay: @unchecked Sendable {}

public enum ScalarVolumeColorLUTBuilder {
    public static let textureWidth = 256
    public static let textureHeight = 1

    public static func colors(for transferFunction: VolumeTransferFunction,
                              intensityRange: ClosedRange<Int32>) -> [SIMD4<Float>] {
        let lower = Float(intensityRange.lowerBound)
        let upper = Float(intensityRange.upperBound)
        guard textureWidth > 1 else {
            return [color(for: lower, transferFunction: transferFunction)]
        }

        return (0..<textureWidth).map { index in
            let t = Float(index) / Float(textureWidth - 1)
            let intensity = lower + (upper - lower) * t
            return color(for: intensity, transferFunction: transferFunction)
        }
    }

    public static func texture(for transferFunction: VolumeTransferFunction,
                               intensityRange: ClosedRange<Int32>,
                               device: any MTLDevice) throws -> any MTLTexture {
        let colors = colors(for: transferFunction, intensityRange: intensityRange)
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
        texture.label = "ScalarVolume.colorLUT"
        colors.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, textureWidth, textureHeight),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: textureWidth * MemoryLayout<SIMD4<Float>>.stride)
        }
        return texture
    }

    private static func color(for intensity: Float,
                              transferFunction: VolumeTransferFunction) -> SIMD4<Float> {
        let colour = interpolateColour(intensity: intensity,
                                       points: transferFunction.colourPoints)
        let opacity = interpolateOpacity(intensity: intensity,
                                         points: transferFunction.opacityPoints)
        return SIMD4<Float>(
            clamp01(colour.x),
            clamp01(colour.y),
            clamp01(colour.z),
            clamp01(colour.w * opacity)
        )
    }

    private static func interpolateColour(intensity: Float,
                                          points: [VolumeTransferFunction.ColourControlPoint]) -> SIMD4<Float> {
        let points = points.sorted { lhs, rhs in lhs.intensity < rhs.intensity }
        guard let first = points.first else { return SIMD4<Float>(1, 1, 1, 1) }
        guard let last = points.last else { return first.colour }
        if intensity <= first.intensity { return first.colour }
        if intensity >= last.intensity { return last.colour }
        for index in 0..<(points.count - 1) {
            let lhs = points[index]
            let rhs = points[index + 1]
            guard intensity >= lhs.intensity, intensity <= rhs.intensity else { continue }
            let delta = rhs.intensity - lhs.intensity
            guard abs(delta) > Float.ulpOfOne else { return rhs.colour }
            let t = (intensity - lhs.intensity) / delta
            return lhs.colour + (rhs.colour - lhs.colour) * t
        }
        return last.colour
    }

    private static func interpolateOpacity(intensity: Float,
                                           points: [VolumeTransferFunction.OpacityControlPoint]) -> Float {
        let points = points.sorted { lhs, rhs in lhs.intensity < rhs.intensity }
        guard let first = points.first else { return 1 }
        guard let last = points.last else { return first.opacity }
        if intensity <= first.intensity { return first.opacity }
        if intensity >= last.intensity { return last.opacity }
        for index in 0..<(points.count - 1) {
            let lhs = points[index]
            let rhs = points[index + 1]
            guard intensity >= lhs.intensity, intensity <= rhs.intensity else { continue }
            let delta = rhs.intensity - lhs.intensity
            guard abs(delta) > Float.ulpOfOne else { return rhs.opacity }
            let t = (intensity - lhs.intensity) / delta
            return lhs.opacity + (rhs.opacity - lhs.opacity) * t
        }
        return last.opacity
    }

    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum VolumeLayerMPRMapper {
    public static func textureBasis(for dataset: VolumeDataset,
                                    baseWorldToLayerWorld: simd_float4x4,
                                    plane: MPRPlaneGeometry) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        let geometry = DICOMGeometry(imageData: dataset.imageData)
        let layerOriginWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld)
        let layerUWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld + plane.axisUWorld) - layerOriginWorld
        let layerVWorld = baseWorldToLayerWorld.transformPoint(plane.originWorld + plane.axisVWorld) - layerOriginWorld
        let textureBasis = geometry.planeWorldToTex(originW: layerOriginWorld,
                                                    axisUW: layerUWorld,
                                                    axisVW: layerVWorld)
        return (textureBasis.originT, textureBasis.axisUT, textureBasis.axisVT)
    }

    public static func textureBasis(for labelmap: LabelmapVolume,
                                    baseWorldToLayerWorld: simd_float4x4,
                                    plane: MPRPlaneGeometry) -> (origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        textureBasis(for: labelmap.dataset,
                     baseWorldToLayerWorld: baseWorldToLayerWorld,
                     plane: plane)
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

    public static func makeScalarOverlay(for layer: VolumeLayer,
                                         baseFrame: MPRTextureFrame,
                                         scalarTexture: any MTLTexture,
                                         colorLUTTexture: any MTLTexture) -> MPRScalarVolumeOverlay? {
        guard layer.isVisible,
              layer.clampedOpacity > 0,
              let scalarVolume = layer.scalarVolume else {
            return nil
        }
        let basis = textureBasis(for: scalarVolume.dataset,
                                 baseWorldToLayerWorld: layer.baseWorldToLayerWorld,
                                 plane: baseFrame.planeGeometry)
        return MPRScalarVolumeOverlay(scalarTexture: scalarTexture,
                                      colorLUTTexture: colorLUTTexture,
                                      pixelFormat: scalarVolume.dataset.pixelFormat,
                                      opacity: layer.clampedOpacity,
                                      blendMode: layer.blendMode,
                                      intensityRange: scalarVolume.dataset.intensityRange,
                                      originTexture: basis.origin,
                                      axisUTexture: basis.axisU,
                                      axisVTexture: basis.axisV)
    }
}

public final class VolumeLayerResourceCache {
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

    private struct ScalarLUTKey: Hashable {
        struct FloatEntry: Hashable {
            let intensity: UInt32
            let value0: UInt32
            let value1: UInt32
            let value2: UInt32
            let value3: UInt32

            init(point: VolumeTransferFunction.ColourControlPoint) {
                self.intensity = point.intensity.bitPattern
                self.value0 = point.colour.x.bitPattern
                self.value1 = point.colour.y.bitPattern
                self.value2 = point.colour.z.bitPattern
                self.value3 = point.colour.w.bitPattern
            }

            init(point: VolumeTransferFunction.OpacityControlPoint) {
                self.intensity = point.intensity.bitPattern
                self.value0 = point.opacity.bitPattern
                self.value1 = 0
                self.value2 = 0
                self.value3 = 0
            }
        }

        let lowerBound: Int32
        let upperBound: Int32
        let opacityPoints: [FloatEntry]
        let colourPoints: [FloatEntry]

        init(scalarVolume: ScalarVolumeLayer) {
            self.lowerBound = scalarVolume.dataset.intensityRange.lowerBound
            self.upperBound = scalarVolume.dataset.intensityRange.upperBound
            self.opacityPoints = scalarVolume.transferFunction.opacityPoints
                .map(FloatEntry.init(point:))
            self.colourPoints = scalarVolume.transferFunction.colourPoints
                .map(FloatEntry.init(point:))
        }
    }

    private let lock = NSLock()
    private var cacheGeneration: UInt64 = 0
    private var labelmapTextures: [DatasetIdentity.Content: any MTLTexture] = [:]
    private var colorLUTTextures: [LUTKey: any MTLTexture] = [:]
    private var scalarTextures: [DatasetIdentity.Content: any MTLTexture] = [:]
    private var scalarColorLUTTextures: [ScalarLUTKey: any MTLTexture] = [:]

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

    public func makeMPRScalarOverlays(for layers: [VolumeLayer],
                                      baseFrame: MPRTextureFrame,
                                      device: any MTLDevice,
                                      commandQueue: any MTLCommandQueue) async throws -> [MPRScalarVolumeOverlay] {
        var overlays: [MPRScalarVolumeOverlay] = []
        for layer in layers {
            guard layer.isVisible,
                  let scalarVolume = layer.scalarVolume else {
                continue
            }
            let scalarTexture = try await texture(for: scalarVolume,
                                                  device: device,
                                                  commandQueue: commandQueue)
            let lutTexture = try colorLUTTexture(for: scalarVolume,
                                                 device: device)
            if let overlay = VolumeLayerMPRMapper.makeScalarOverlay(for: layer,
                                                                    baseFrame: baseFrame,
                                                                    scalarTexture: scalarTexture,
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
        scalarTextures.removeAll()
        scalarColorLUTTextures.removeAll()
    }

    private func texture(for labelmap: LabelmapVolume,
                         device: any MTLDevice,
                         commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        let key = DatasetIdentity.Content(dataset: labelmap.dataset)
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

    private func texture(for scalarVolume: ScalarVolumeLayer,
                         device: any MTLDevice,
                         commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        let key = DatasetIdentity.Content(dataset: scalarVolume.dataset)
        let cacheState = cachedScalarTexture(for: key, device: device)
        if let texture = cacheState.texture {
            return texture
        }

        let texture = try await VolumeTextureFactory(dataset: scalarVolume.dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        texture.label = "ScalarVolume.volumeTexture"
        storeScalarTexture(texture, for: key, generation: cacheState.generation)
        return texture
    }

    private func colorLUTTexture(for scalarVolume: ScalarVolumeLayer,
                                 device: any MTLDevice) throws -> any MTLTexture {
        let key = ScalarLUTKey(scalarVolume: scalarVolume)
        let cacheState = cachedScalarColorLUTTexture(for: key, device: device)
        if let texture = cacheState.texture {
            return texture
        }

        let texture = try ScalarVolumeColorLUTBuilder.texture(
            for: scalarVolume.transferFunction,
            intensityRange: scalarVolume.dataset.intensityRange,
            device: device
        )
        storeScalarColorLUTTexture(texture, for: key, generation: cacheState.generation)
        return texture
    }

    private func cachedLabelmapTexture(for key: DatasetIdentity.Content,
                                       device: any MTLDevice) -> (texture: (any MTLTexture)?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let texture = labelmapTextures[key],
           texture.device === device {
            return (texture, cacheGeneration)
        }
        return (nil, cacheGeneration)
    }

    private func cachedScalarTexture(for key: DatasetIdentity.Content,
                                     device: any MTLDevice) -> (texture: (any MTLTexture)?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let texture = scalarTextures[key],
           texture.device === device {
            return (texture, cacheGeneration)
        }
        return (nil, cacheGeneration)
    }

    private func storeLabelmapTexture(_ texture: any MTLTexture,
                                      for key: DatasetIdentity.Content,
                                      generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == cacheGeneration else {
            return
        }
        labelmapTextures[key] = texture
    }

    private func storeScalarTexture(_ texture: any MTLTexture,
                                    for key: DatasetIdentity.Content,
                                    generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == cacheGeneration else {
            return
        }
        scalarTextures[key] = texture
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

    private func cachedScalarColorLUTTexture(for key: ScalarLUTKey,
                                             device: any MTLDevice) -> (texture: (any MTLTexture)?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let texture = scalarColorLUTTextures[key],
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

    private func storeScalarColorLUTTexture(_ texture: any MTLTexture,
                                            for key: ScalarLUTKey,
                                            generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == cacheGeneration else {
            return
        }
        scalarColorLUTTextures[key] = texture
    }
}

extension VolumeLayerResourceCache: @unchecked Sendable {}

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
