//
//  MPRVolumeTextureCache.swift
//  MTKUI
//
//  Shared MPR volume texture cache.
//

import Foundation
import Metal
import MTKCore

@MainActor
final class MPRVolumeTextureCache {
    typealias TextureProvider = @MainActor (VolumeDataset, any MTLDevice, any MTLCommandQueue) async throws -> any MTLTexture

    private var cached: (dataset: VolumeDataset, texture: any MTLTexture)?
    private var pending: (dataset: VolumeDataset, task: Task<any MTLTexture, Error>)?
    private let textureProvider: TextureProvider

    init(textureProvider: @escaping TextureProvider = { dataset, device, commandQueue in
        try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
    }) {
        self.textureProvider = textureProvider
    }

    /// Provide a texture for the given volume dataset, using an internal cache and an in-flight task to avoid redundant generation.
    /// - Parameter dataset: The `VolumeDataset` whose texture is requested.
    /// - Returns: The `MTLTexture` corresponding to `dataset`.
    /// - Throws: Any error produced while generating the texture.
    func texture(for dataset: VolumeDataset,
                 device: any MTLDevice,
                 commandQueue: any MTLCommandQueue) async throws -> any MTLTexture {
        if let cached,
           cached.dataset == dataset {
            return cached.texture
        }
        if let pending,
           pending.dataset == dataset {
            let texture = try await pending.task.value
            if self.pending?.dataset == dataset {
                cached = (dataset, texture)
                self.pending = nil
            }
            return texture
        }

        let task = Task { @MainActor in
            try await textureProvider(dataset, device, commandQueue)
        }
        pending = (dataset, task)
        do {
            let texture = try await task.value
            if pending?.dataset == dataset {
                cached = (dataset, texture)
                pending = nil
            }
            return texture
        } catch {
            if pending?.dataset == dataset {
                pending = nil
            }
            throw error
        }
    }

    /// Clears the cached texture and any pending texture-generation task.
    /// 
    /// Removes the stored (dataset, texture) cache entry and the reference to an in-flight task so subsequent requests will generate a new texture.
    func invalidate() {
        pending?.task.cancel()
        cached = nil
        pending = nil
    }

    var textureIdentifier: ObjectIdentifier? {
        guard let texture = cached?.texture else { return nil }
        return ObjectIdentifier(texture as AnyObject)
    }
}
