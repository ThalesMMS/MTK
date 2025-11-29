//
//  VolumeTextureFactory.swift
//  MTK
//
//  Converts volumetric datasets into Metal textures and exposes built-in presets.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog
import simd
import ZIPFoundation

public final class VolumeTextureFactory {
    private(set) public var dataset: VolumeDataset
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeTextureFactory")
    private static let resourceLogger = Logger(subsystem: "com.mtk.volumerendering",
                                               category: "VolumeResources")

    public init(dataset: VolumeDataset) {
        self.dataset = dataset
    }

    public convenience init(preset: VolumeDatasetPreset) {
        self.init(dataset: VolumeTextureFactory.dataset(for: preset))
    }

    public var resolution: SIMD3<Float> { dataset.spacing.simd3Value }
    public var dimension: SIMD3<Int32> { dataset.dimensions.simd3Value }
    public var scale: SIMD3<Float> { dataset.scale.simd3Value }

    public func update(dataset: VolumeDataset) {
        self.dataset = dataset
    }

    public func generate(device: any MTLDevice) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Float
        descriptor.usage = [.shaderRead, .pixelFormatView]
        descriptor.width = dataset.dimensions.width
        descriptor.height = dataset.dimensions.height
        descriptor.depth = dataset.dimensions.depth

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Failed to create 3D texture (\(descriptor.width)x\(descriptor.height)x\(descriptor.depth))")
            return nil
        }

        // Convert Int16 data to Float16 for hardware linear filtering support
        let float16Data = dataset.data.withUnsafeBytes { buffer -> Data in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return Data() }
            let count = dataset.dimensions.voxelCount
            var outputData = Data(count: count * MemoryLayout<Float16>.stride)
            
            outputData.withUnsafeMutableBytes { outBuffer in
                guard let outPtr = outBuffer.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
                for i in 0..<count {
                    outPtr[i] = Float16(baseAddress[i])
                }
            }
            return outputData
        }

        let bytesPerRow = MemoryLayout<Float16>.stride * descriptor.width
        let bytesPerImage = bytesPerRow * descriptor.height

        float16Data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, descriptor.width, descriptor.height, descriptor.depth),
                mipmapLevel: 0,
                slice: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }
}

private extension VolumeTextureFactory {
    static func dataset(for preset: VolumeDatasetPreset) -> VolumeDataset {
        switch preset {
        case .head:
            return loadZippedResource(
                named: "head",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 511),
                spacing: VolumeSpacing(x: 0.000449, y: 0.000449, z: 0.000501),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .chest:
            return loadZippedResource(
                named: "chest",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 179),
                spacing: VolumeSpacing(x: 0.000586, y: 0.000586, z: 0.002),
                pixelFormat: .int16Signed,
                intensity: (-1024)...3071
            )
        case .none, .dicom:
            return placeholderDataset()
        }
    }

    static func placeholderDataset() -> VolumeDataset {
        let data = Data(count: VolumePixelFormat.int16Signed.bytesPerVoxel)
        return VolumeDataset(
            data: data,
            dimensions: VolumeDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071
        )
    }

    static func loadZippedResource(named name: String,
                                   dimensions: VolumeDimensions,
                                   spacing: VolumeSpacing,
                                   pixelFormat: VolumePixelFormat,
                                   intensity: ClosedRange<Int32>) -> VolumeDataset {
        guard let url = Bundle.module.url(forResource: name, withExtension: "raw.zip") else {
            resourceLogger.warning("Missing resource: \(name).raw.zip")
            return placeholderDataset()
        }

        return loadDataset(
            fromArchiveAt: url,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            intensity: intensity
        )
    }

    static func loadDataset(fromArchiveAt url: URL,
                            dimensions: VolumeDimensions,
                            spacing: VolumeSpacing,
                            pixelFormat: VolumePixelFormat,
                            intensity: ClosedRange<Int32>) -> VolumeDataset {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            resourceLogger.error("Unable to open archive at \(url.path): \(String(describing: error))")
            return placeholderDataset()
        }

        var data = Data(capacity: dimensions.voxelCount * pixelFormat.bytesPerVoxel)
        do {
            for entry in archive {
                _ = try archive.extract(entry) { buffer in
                    data.append(buffer)
                }
            }
        } catch {
            resourceLogger.error("Failed to extract archive \(url.lastPathComponent): \(String(describing: error))")
            return placeholderDataset()
        }

        if data.isEmpty {
            resourceLogger.warning("Archive \(url.lastPathComponent) extracted but returned empty data")
            return placeholderDataset()
        }

        return VolumeDataset(
            data: data,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: pixelFormat,
            intensityRange: intensity
        )
    }
}

private extension VolumeSpacing {
    var simd3Value: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

private extension VolumeDimensions {
    var simd3Value: SIMD3<Int32> {
        SIMD3<Int32>(Int32(width), Int32(height), Int32(depth))
    }
}

private extension VolumePixelFormat {
    var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .int16Signed:
            return .r16Sint
        case .int16Unsigned:
            return .r16Uint
        }
    }
}
