//
//  VolumeRaycastPass.swift
//  MTK
//
//  Compute raycast pass for the official Metal render graph.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

struct VolumeRaycastPassRenderingParameters: Sendable {
    var quality: VolumeRenderRequest.Quality
    var samplingDistance: Float
    var compositingMode: VolumeRenderRequest.Compositing
}

struct VolumeRaycastPassClippingConfiguration: Sendable, Equatable {
    var trimXMin: Float
    var trimXMax: Float
    var trimYMin: Float
    var trimYMax: Float
    var trimZMin: Float
    var trimZMax: Float
    var clipPlane0: SIMD4<Float>
    var clipPlane1: SIMD4<Float>
    var clipPlane2: SIMD4<Float>

    init(shaderParameters: RenderingParameters) {
        trimXMin = shaderParameters.trimXMin
        trimXMax = shaderParameters.trimXMax
        trimYMin = shaderParameters.trimYMin
        trimYMax = shaderParameters.trimYMax
        trimZMin = shaderParameters.trimZMin
        trimZMax = shaderParameters.trimZMax
        clipPlane0 = shaderParameters.clipPlane0
        clipPlane1 = shaderParameters.clipPlane1
        clipPlane2 = shaderParameters.clipPlane2
    }
}

struct VolumeRaycastPassInput: @unchecked Sendable {
    var volumeTexture: any MTLTexture
    var transferFunctionTexture: any MTLTexture
    var accelerationTexture: (any MTLTexture)?
    var cameraUniforms: CameraUniforms
    var renderingParameters: VolumeRaycastPassRenderingParameters
    var clippingConfiguration: VolumeRaycastPassClippingConfiguration
    var huGate: ClosedRange<Int32>?
    var viewportSize: CGSize
    var shaderParameters: RenderingParameters
    var optionValue: UInt16
    var targetViewSize: UInt16
    var quaternion: SIMD4<Float>
    var outputTexture: (any MTLTexture)?

    init(volumeTexture: any MTLTexture,
         transferFunctionTexture: any MTLTexture,
         accelerationTexture: (any MTLTexture)? = nil,
         cameraUniforms: CameraUniforms,
         renderingParameters: VolumeRaycastPassRenderingParameters,
         shaderParameters: RenderingParameters,
         viewportSize: CGSize,
         clippingConfiguration: VolumeRaycastPassClippingConfiguration? = nil,
         huGate: ClosedRange<Int32>? = nil,
         optionValue: UInt16 = 0,
         targetViewSize: UInt16? = nil,
         quaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
         outputTexture: (any MTLTexture)? = nil) {
        self.volumeTexture = volumeTexture
        self.transferFunctionTexture = transferFunctionTexture
        self.accelerationTexture = accelerationTexture
        self.cameraUniforms = cameraUniforms
        self.renderingParameters = renderingParameters
        self.clippingConfiguration = clippingConfiguration ?? VolumeRaycastPassClippingConfiguration(
            shaderParameters: shaderParameters
        )
        self.huGate = huGate
        self.viewportSize = viewportSize
        self.shaderParameters = shaderParameters
        self.optionValue = optionValue
        self.targetViewSize = targetViewSize ?? UInt16(clamping: max(Int(viewportSize.width),
                                                                     Int(viewportSize.height)))
        self.quaternion = quaternion
        self.outputTexture = outputTexture
    }
}

struct VolumeRaycastPassTiming: Sendable {
    var cpuDurationMilliseconds: Double
    var gpuStartTime: CFTimeInterval?
    var gpuEndTime: CFTimeInterval?
    var gpuDurationMilliseconds: Double?
    var kernelStartTime: CFTimeInterval?
    var kernelEndTime: CFTimeInterval?
    var kernelDurationMilliseconds: Double?
}

struct VolumeRaycastPassOutput: @unchecked Sendable {
    var outputTexture: any MTLTexture
    var compositingMode: VolumeRenderRequest.Compositing
    var quality: VolumeRenderRequest.Quality
    var viewportSize: CGSize
    var timing: VolumeRaycastPassTiming
}

enum VolumeRaycastPassError: Error, Equatable {
    case missingTextures
    case invalidDimensions(width: Int, height: Int)
    case degenerateCamera
    case commandQueueDeviceMismatch
    case commandBufferCreationFailed
    case commandEncodingFailed
    case commandBufferExecutionFailed(underlyingDescription: String)
    case outputTextureUnavailable
    case invalidOutputTexture(String)
}

/// Official compute raycasting pass for the clinical render graph.
///
/// Profiling is intentionally split into three phases: upload, raycast, and present.
/// Dataset/transfer upload timing belongs to the resource manager, this pass records
/// only `volume_compute` dispatch timing, and presentation timing is captured by
/// `PresentationPass`. Keeping those phases separate makes preview/HQ tuning and
/// multi-viewport scheduling observable without adding legacy view glue or CPU image readback
/// to the canonical rendering path.
final class VolumeRaycastPass: @unchecked Sendable {
    let argumentManager: ArgumentEncoderManager

    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let cameraBuffer: any MTLBuffer
    private let inFlightLock = VolumeRaycastPassLock()

    init(device: any MTLDevice,
         library: any MTLLibrary,
         debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) throws {
        guard library.device === device else {
            throw MetalVolumeRenderingAdapter.InitializationError.shaderLibraryDeviceMismatch
        }
        guard let function = library.makeFunction(name: "volume_compute") else {
            throw MetalVolumeRenderingAdapter.InitializationError.computeFunctionNotFound
        }

        let pipeline: any MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalVolumeRenderingAdapter.InitializationError.pipelineCreationFailed
        }

        // StorageModePolicy.md: camera uniforms are CPU-written shader inputs.
        guard let cameraBuffer = device.makeBuffer(length: CameraUniforms.stride,
                                                   options: [.storageModeShared])
        else {
            throw MetalVolumeRenderingAdapter.InitializationError.cameraBufferAllocationFailed
        }

        self.device = device
        self.pipeline = pipeline
        self.argumentManager = ArgumentEncoderManager(
            device: device,
            mtlFunction: function,
            debugOptions: debugOptions
        )
        self.cameraBuffer = cameraBuffer
        self.cameraBuffer.label = "VolumeRaycastPass.CameraUniforms"
    }

    convenience init(device: any MTLDevice,
                     debugOptions: VolumeRenderingDebugOptions = VolumeRenderingDebugOptions()) throws {
        let library = try ShaderLibraryLoader.loadLibrary(for: device)
        try self.init(device: device, library: library, debugOptions: debugOptions)
    }

    func execute(input: VolumeRaycastPassInput,
                 commandQueue: any MTLCommandQueue) async throws -> VolumeRaycastPassOutput {
        let cpuStart = CFAbsoluteTimeGetCurrent()

        guard commandQueue.device === device else {
            throw VolumeRaycastPassError.commandQueueDeviceMismatch
        }

        let viewport = try validate(input: input)

        await inFlightLock.acquire()

        do {
            let outputTexture = try input.outputTexture ?? prepareOutputTexture(
                width: viewport.width,
                height: viewport.height,
                device: device
            )

            encode(input: input, outputTexture: outputTexture)

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw VolumeRaycastPassError.commandBufferCreationFailed
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw VolumeRaycastPassError.commandEncodingFailed
            }

            commandBuffer.label = "VolumeRaycastPass.Raycast"
            encoder.label = "VolumeRaycastPass.CommandEncoder"
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(argumentManager.argumentBuffer, offset: 0, index: 0)
            encoder.setBuffer(cameraBuffer, offset: 0, index: 1)
            argumentManager.registerResources(on: encoder)

            let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (viewport.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                 height: (viewport.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()

            CommandBufferProfiler.captureTimes(for: commandBuffer,
                                               label: "raycast",
                                               category: input.renderingParameters.quality.profilerCategory)
            let timing = try await complete(commandBuffer: commandBuffer,
                                            cpuStart: cpuStart)
            ClinicalProfiler.shared.recordSample(
                stage: .volumeRaycast,
                cpuTime: timing.cpuDurationMilliseconds,
                gpuTime: timing.gpuDurationMilliseconds,
                viewport: ProfilingViewportContext(
                    width: viewport.width,
                    height: viewport.height,
                    viewportType: "volume3D",
                    quality: input.renderingParameters.quality,
                    renderMode: input.renderingParameters.compositingMode
                ),
                metadata: [
                    "kernelTimeMilliseconds": timing.kernelDurationMilliseconds.map { String(format: "%.6f", $0) } ?? "",
                    "samplingDistance": String(input.renderingParameters.samplingDistance)
                ],
                device: device
            )
            let output = VolumeRaycastPassOutput(outputTexture: outputTexture,
                                                 compositingMode: input.renderingParameters.compositingMode,
                                                 quality: input.renderingParameters.quality,
                                                 viewportSize: input.viewportSize,
                                                 timing: timing)
            await inFlightLock.release()
            return output
        } catch {
            await inFlightLock.release()
            throw error
        }
    }

    func prepareOutputTexture(width: Int,
                              height: Int,
                              device: any MTLDevice) throws -> any MTLTexture {
        guard width > 0, height > 0 else {
            throw VolumeRaycastPassError.invalidDimensions(width: width, height: height)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw VolumeRaycastPassError.outputTextureUnavailable
        }
        texture.label = "VolumeRaycastPass.Output"
        return texture
    }

    private func validate(input: VolumeRaycastPassInput) throws -> (width: Int, height: Int) {
        let width = Int(input.viewportSize.width.rounded(.down))
        let height = Int(input.viewportSize.height.rounded(.down))
        guard width > 0, height > 0 else {
            throw VolumeRaycastPassError.invalidDimensions(width: width, height: height)
        }

        guard input.volumeTexture.textureType == .type3D,
              input.volumeTexture.width > 0,
              input.volumeTexture.height > 0,
              input.volumeTexture.depth > 0,
              input.transferFunctionTexture.width > 0,
              input.transferFunctionTexture.height > 0 else {
            throw VolumeRaycastPassError.missingTextures
        }

        if let outputTexture = input.outputTexture {
            guard outputTexture.width == width, outputTexture.height == height else {
                throw VolumeRaycastPassError.invalidDimensions(width: outputTexture.width,
                                                               height: outputTexture.height)
            }
            try validateOutputTextureContract(outputTexture)
        }

        guard input.cameraUniforms.inverseViewProjectionMatrix.isFinite,
              input.cameraUniforms.modelMatrix.isFinite,
              input.cameraUniforms.inverseModelMatrix.isFinite,
              input.cameraUniforms.cameraPositionLocal.isFinite else {
            throw VolumeRaycastPassError.degenerateCamera
        }

        return (width, height)
    }

    private func validateOutputTextureContract(_ texture: any MTLTexture) throws {
        guard texture.device === device else {
            throw VolumeRaycastPassError.invalidOutputTexture("Output texture must belong to the pass device.")
        }
        guard texture.textureType == .type2D else {
            throw VolumeRaycastPassError.invalidOutputTexture("Output texture must be a 2D texture.")
        }
        guard texture.pixelFormat == .bgra8Unorm else {
            throw VolumeRaycastPassError.invalidOutputTexture("Output texture pixel format must be bgra8Unorm.")
        }
        guard texture.storageMode == .private else {
            throw VolumeRaycastPassError.invalidOutputTexture("Output texture storage mode must be private.")
        }
        guard texture.usage.contains(.shaderWrite) else {
            throw VolumeRaycastPassError.invalidOutputTexture("Output texture usage must include shaderWrite.")
        }
    }

    private func encode(input: VolumeRaycastPassInput,
                        outputTexture: any MTLTexture) {
        var parameters = input.shaderParameters
        var optionValue = input.optionValue
        var targetViewSize = input.targetViewSize
        var quaternion = input.quaternion
        var camera = input.cameraUniforms

        argumentManager.encodeTexture(input.volumeTexture, argumentIndex: .mainTexture)
        argumentManager.encodeTexture(input.transferFunctionTexture, argumentIndex: .transferTextureCh1)
        argumentManager.encodeTexture(input.transferFunctionTexture, argumentIndex: .transferTextureCh2)
        argumentManager.encodeTexture(input.transferFunctionTexture, argumentIndex: .transferTextureCh3)
        argumentManager.encodeTexture(input.transferFunctionTexture, argumentIndex: .transferTextureCh4)
        argumentManager.encodeTexture(input.accelerationTexture, argumentIndex: .accelerationTexture)
        argumentManager.setOutputTexture(outputTexture)
        argumentManager.encodeSampler(filter: .linear)
        argumentManager.encode(&parameters, argumentIndex: .renderParams)
        argumentManager.encode(&optionValue, argumentIndex: .optionValue)
        argumentManager.encode(&quaternion, argumentIndex: .quaternion)
        argumentManager.encode(&targetViewSize, argumentIndex: .targetViewSize)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh1)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh2)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh3)
        argumentManager.encode(nil, argumentIndex: .toneBufferCh4)

        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)
    }

    private func complete(commandBuffer: any MTLCommandBuffer,
                          cpuStart: CFAbsoluteTime) async throws -> VolumeRaycastPassTiming {
        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                let cpuEnd = CFAbsoluteTimeGetCurrent()

                if let error = buffer.error {
                    let description = "\(String(describing: buffer.status)): \(error.localizedDescription)"
                    continuation.resume(throwing: VolumeRaycastPassError.commandBufferExecutionFailed(
                        underlyingDescription: description
                    ))
                    return
                } else if buffer.status == .error {
                    continuation.resume(throwing: VolumeRaycastPassError.commandBufferExecutionFailed(
                        underlyingDescription: "Metal command buffer finished with error status but no error object."
                    ))
                    return
                }

                continuation.resume(returning: VolumeRaycastPassTiming(
                    cpuDurationMilliseconds: max(0, (cpuEnd - cpuStart) * 1000.0),
                    gpuStartTime: Self.validTimestamp(buffer.gpuStartTime),
                    gpuEndTime: Self.validTimestamp(buffer.gpuEndTime),
                    gpuDurationMilliseconds: Self.interval(buffer.gpuStartTime, buffer.gpuEndTime),
                    kernelStartTime: Self.validTimestamp(buffer.kernelStartTime),
                    kernelEndTime: Self.validTimestamp(buffer.kernelEndTime),
                    kernelDurationMilliseconds: Self.interval(buffer.kernelStartTime, buffer.kernelEndTime)
                ))
            }
            commandBuffer.commit()
        }
    }

    private static func validTimestamp(_ timestamp: CFTimeInterval) -> CFTimeInterval? {
        timestamp > 0 ? timestamp : nil
    }

    private static func interval(_ start: CFTimeInterval, _ end: CFTimeInterval) -> Double? {
        guard start > 0, end > 0, end >= start else { return nil }
        return (end - start) * 1000.0
    }
}

private extension simd_float4x4 {
    var isFinite: Bool {
        columns.0.isFinite &&
            columns.1.isFinite &&
            columns.2.isFinite &&
            columns.3.isFinite
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

private extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}

private extension VolumeRenderRequest.Quality {
    var profilerCategory: String {
        switch self {
        case .preview, .interactive:
            return "Benchmark.preview"
        case .production:
            return "Benchmark.final"
        }
    }
}

private actor VolumeRaycastPassLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
