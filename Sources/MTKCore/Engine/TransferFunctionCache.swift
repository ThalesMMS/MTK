//
//  TransferFunctionCache.swift
//  MTK
//
//  Focused transfer-function texture access/caching facade used by VolumeResourceManager.
//  This does not replace TransferFunctions' internal texture cache; it tracks textures
//  acquired by the engine for resource metrics/debugging and centralizes conversion from
//  VolumeTransferFunction -> TransferFunction.
//

import Foundation
@preconcurrency import Metal
import OSLog

final class TransferFunctionCache {
    private struct TransferTextureEntry {
        var texture: any MTLTexture
        var estimatedBytes: Int
        var lastAccessTime: CFAbsoluteTime

        var metadata: VolumeResourceHandle.Metadata {
            VolumeResourceHandle.Metadata(
                resourceType: .transferFunction,
                debugLabel: texture.label,
                estimatedBytes: estimatedBytes,
                pixelFormat: texture.pixelFormat,
                storageMode: texture.storageMode,
                dimensions: VolumeResourceHandle.Metadata.Dimensions(
                    width: texture.width,
                    height: texture.height,
                    depth: texture.depth
                )
            )
        }
    }

    private var transferTextureEntries: [ObjectIdentifier: TransferTextureEntry] = [:]
    private let lock = NSLock()
    private let logger = os.Logger(subsystem: "com.mtk.volumerendering",
                                   category: "TransferFunctionCache")

    @MainActor
    func texture(for preset: VolumeRenderingBuiltinPreset,
                 device: any MTLDevice) -> (any MTLTexture)? {
        guard let texture = TransferFunctions.texture(for: preset, device: device) else {
            return nil
        }

        track(texture)
        return texture
    }

    @MainActor
    func texture(for function: VolumeTransferFunction,
                 device: any MTLDevice,
                 options: TransferFunctions.TextureOptions? = nil) -> (any MTLTexture)? {
        guard let transferFunction = makeTransferFunction(from: function),
              let texture = TransferFunctions.texture(for: transferFunction,
                                                      device: device,
                                                      options: options ?? .default) else {
            return nil
        }

        track(texture)
        return texture
    }

    var estimatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return transferTextureEntries.values.reduce(0) { $0 + $1.estimatedBytes }
    }

    var textureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return transferTextureEntries.count
    }

    var metadata: [VolumeResourceHandle.Metadata] {
        lock.lock()
        defer { lock.unlock() }
        return transferTextureEntries.values.map(\.metadata)
    }

    func debugLastAccessTime(for texture: any MTLTexture) -> CFAbsoluteTime? {
        lock.lock()
        defer { lock.unlock() }
        return transferTextureEntries[ObjectIdentifier(texture as AnyObject)]?.lastAccessTime
    }

    private func track(_ texture: any MTLTexture) {
        let id = ObjectIdentifier(texture as AnyObject)
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        defer { lock.unlock() }
        if var entry = transferTextureEntries[id] {
            entry.lastAccessTime = now
            transferTextureEntries[id] = entry
        } else {
            transferTextureEntries[id] = TransferTextureEntry(
                texture: texture,
                estimatedBytes: ResourceMemoryEstimator.estimate(for: texture),
                lastAccessTime: now
            )
        }
    }

    private func makeTransferFunction(from function: VolumeTransferFunction) -> TransferFunction? {
        guard !function.colourPoints.isEmpty,
              !function.opacityPoints.isEmpty
        else {
            logger.debug("Skipping empty transfer function colourPointCount=\(function.colourPoints.count) opacityPointCount=\(function.opacityPoints.count) function=\(String(describing: function))")
            return nil
        }

        let intensityValues = function.colourPoints.map(\.intensity) + function.opacityPoints.map(\.intensity)
        let minimum = intensityValues.min() ?? -1024
        let maximum = intensityValues.max() ?? 3071

        var transfer = TransferFunction()
        transfer.name = "VolumeResourceManager.TransferFunction"
        transfer.minimumValue = min(minimum, maximum)
        transfer.maximumValue = max(minimum, maximum)
        transfer.shift = 0
        transfer.colorSpace = .linear
        transfer.colourPoints = function.colourPoints.map { point in
            TransferFunction.ColorPoint(
                dataValue: point.intensity,
                colourValue: TransferFunction.RGBAColor(
                    r: point.colour.x,
                    g: point.colour.y,
                    b: point.colour.z,
                    a: point.colour.w
                )
            )
        }
        transfer.alphaPoints = function.opacityPoints.map { point in
            TransferFunction.AlphaPoint(dataValue: point.intensity,
                                        alphaValue: point.opacity)
        }
        return transfer
    }
}
