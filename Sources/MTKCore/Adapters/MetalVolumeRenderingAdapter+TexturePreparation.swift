//
//  MetalVolumeRenderingAdapter+TexturePreparation.swift
//  MTK
//
//  Texture preparation helpers for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — April 2026

import Metal

extension MetalVolumeRenderingAdapter {
    func prepareDatasetTexture(for dataset: VolumeDataset,
                               state: MetalState) throws -> any MTLTexture {
        let identity = DatasetIdentity(dataset: dataset)
        if let existing = state.volumeTexture,
           state.datasetIdentity == identity {
            return existing
        }

        let factory = VolumeTextureFactory(dataset: dataset)
        guard let texture = factory.generate(device: state.device) else {
            throw RenderingError.datasetTextureUnavailable
        }
        texture.label = "VolumeCompute.Dataset"
        state.volumeTexture = texture
        state.datasetIdentity = identity
        state.argumentManager.markAsNeedsUpdate(argumentIndex: .mainTexture)
        return texture
    }

    func prepareDatasetTexture(for dataset: VolumeDataset,
                               texture: any MTLTexture,
                               state: MetalState) -> any MTLTexture {
        let identity = DatasetIdentity(dataset: dataset)
        let sameTexture = state.volumeTexture.map {
            ($0 as AnyObject) === (texture as AnyObject)
        } ?? false

        if sameTexture, state.datasetIdentity == identity {
            return texture
        }

        texture.label = texture.label ?? "VolumeCompute.Dataset"
        state.volumeTexture = texture
        state.datasetIdentity = identity
        state.argumentManager.markAsNeedsUpdate(argumentIndex: .mainTexture)
        return texture
    }

    func prepareTransferTexture(for transfer: VolumeTransferFunction,
                                dataset: VolumeDataset,
                                state: MetalState) async throws -> any MTLTexture {
        if let cache = state.transferCache,
           cache.transfer == transfer,
           cache.intensityRange == dataset.intensityRange {
            return cache.texture
        }

        let resolvedTransfer = try makeTransferFunction(from: transfer,
                                                        dataset: dataset)
        let texture = await MainActor.run {
            TransferFunctions.texture(for: resolvedTransfer,
                                      device: state.device)
        }

        guard let texture else {
            throw RenderingError.transferTextureUnavailable
        }
        texture.label = "VolumeCompute.Transfer"
        state.transferCache = MetalState.TransferCache(transfer: transfer,
                                                       intensityRange: dataset.intensityRange,
                                                       texture: texture)
        return texture
    }

    func makeTransferFunction(from transfer: VolumeTransferFunction,
                              dataset: VolumeDataset) throws -> TransferFunction {
        var tf = TransferFunction()
        tf.minimumValue = Float(dataset.intensityRange.lowerBound)
        tf.maximumValue = Float(dataset.intensityRange.upperBound)
        tf.shift = 0
        tf.colorSpace = .linear
        tf.colourPoints = try sanitizeColourPoints(transfer.colourPoints)
        tf.alphaPoints = try sanitizeAlphaPoints(transfer.opacityPoints)
        return tf
    }

    func sanitizeColourPoints(_ points: [VolumeTransferFunction.ColourControlPoint]) throws -> [TransferFunction.ColorPoint] {
        let mapped = points.map { point -> TransferFunction.ColorPoint in
            let rgba = TransferFunction.RGBAColor(r: point.colour.x,
                                                  g: point.colour.y,
                                                  b: point.colour.z,
                                                  a: point.colour.w)
            return TransferFunction.ColorPoint(dataValue: point.intensity,
                                               colourValue: rgba)
        }
        if mapped.isEmpty {
            throw AdapterError.emptyColorPoints
        }
        return mapped
    }

    func sanitizeAlphaPoints(_ points: [VolumeTransferFunction.OpacityControlPoint]) throws -> [TransferFunction.AlphaPoint] {
        let mapped = points.map { point in
            TransferFunction.AlphaPoint(dataValue: point.intensity,
                                        alphaValue: point.opacity)
        }
        if mapped.isEmpty {
            throw AdapterError.emptyAlphaPoints
        }
        return mapped
    }
}
