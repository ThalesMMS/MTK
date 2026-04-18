import CoreGraphics
import Foundation
import Metal
import simd
import XCTest

@testable import MTKCore

// MARK: - Shared acceleration result error

enum AccelerationResultError: Error {
    case unexpectedUnavailable
}

// MARK: - Shared test helpers for raycaster tests

enum RaycasterTestHelpers {
    /// Asserts that a raycaster acceleration structure result is successful and
    /// returns the texture, failing the test and throwing otherwise.
    static func requireAccelerationTexture(
        from raycaster: MetalRaycaster,
        for dataset: VolumeDataset,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> any MTLTexture {
        switch raycaster.prepareAccelerationStructure(dataset: dataset) {
        case .success(let texture):
            return texture
        case .unavailable(let reason):
            XCTFail(
                "Expected .success after confirming MPS availability, got .unavailable(\(String(describing: reason)))",
                file: file,
                line: line
            )
            throw AccelerationResultError.unexpectedUnavailable
        case .failed(let error):
            XCTFail(
                "Expected .success after confirming MPS availability, got .failed(\(error.localizedDescription))",
                file: file,
                line: line
            )
            throw error
        }
    }

    static func commitAndWait(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            commandBuffer.commit()
        }
    }

    static func makeTestRenderingParameters(dataset: VolumeDataset, method: Int32) -> RenderingParameters {
        var params = RenderingParameters()
        params.material.method = method
        params.material.renderingQuality = 256
        params.material.voxelMinValue = dataset.intensityRange.lowerBound
        params.material.voxelMaxValue = dataset.intensityRange.upperBound
        params.material.datasetMinValue = dataset.intensityRange.lowerBound
        params.material.datasetMaxValue = dataset.intensityRange.upperBound
        params.material.dimX = Int32(dataset.dimensions.width)
        params.material.dimY = Int32(dataset.dimensions.height)
        params.material.dimZ = Int32(dataset.dimensions.depth)
        params.renderingStep = 1.0 / Float(max(params.material.renderingQuality, 1))
        params.earlyTerminationThreshold = 0.95
        params.intensityRatio = SIMD4<Float>(1, 0, 0, 0)
        return params
    }

    static func makeTestCameraUniforms() -> CameraUniforms {
        var camera = CameraUniforms()
        camera.modelMatrix = matrix_identity_float4x4
        camera.inverseModelMatrix = matrix_identity_float4x4
        camera.inverseViewProjectionMatrix = matrix_identity_float4x4
        camera.cameraPositionLocal = SIMD3<Float>(0, 0, -2)
        camera.frameIndex = 0
        camera.projectionType = 0
        return camera
    }

    static func makeTestTransferFunction(for dataset: VolumeDataset) -> TransferFunction {
        var tf = TransferFunction()
        tf.name = "TestTF"
        tf.minimumValue = Float(dataset.intensityRange.lowerBound)
        tf.maximumValue = Float(dataset.intensityRange.upperBound)
        tf.colorSpace = .linear
        tf.colourPoints = [
            .init(dataValue: tf.minimumValue, colourValue: .init(r: 1, g: 1, b: 1, a: 1)),
            .init(dataValue: tf.maximumValue, colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        tf.alphaPoints = [
            .init(dataValue: tf.minimumValue, alphaValue: 0.0),
            .init(dataValue: (tf.minimumValue + tf.maximumValue) * 0.5, alphaValue: 1.0),
            .init(dataValue: tf.maximumValue, alphaValue: 0.0)
        ]
        return tf
    }

    static func makeTestTransferTexture(
        for dataset: VolumeDataset,
        device: any MTLDevice
    ) async throws -> any MTLTexture {
        let tf = makeTestTransferFunction(for: dataset)
        let texture = await MainActor.run {
            TransferFunctions.texture(for: tf, device: device)
        }
        guard let texture else {
            throw XCTSkip("Failed to create transfer function texture")
        }
        return texture
    }
}