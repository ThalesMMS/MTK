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

struct VolumeRaycastToneBuffers: @unchecked Sendable {
    var channel1: (any MTLBuffer)?
    var channel2: (any MTLBuffer)?
    var channel3: (any MTLBuffer)?
    var channel4: (any MTLBuffer)?

    static let empty = VolumeRaycastToneBuffers()
}

struct VolumeRaycastPassInput: @unchecked Sendable {
    var volumeTexture: any MTLTexture
    var transferFunctionTexture: any MTLTexture
    var accelerationTexture: (any MTLTexture)?
    var toneBuffers: VolumeRaycastToneBuffers
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
    var debugFrameIndex: UInt64?

    init(volumeTexture: any MTLTexture,
         transferFunctionTexture: any MTLTexture,
         accelerationTexture: (any MTLTexture)? = nil,
         toneBuffers: VolumeRaycastToneBuffers = .empty,
         cameraUniforms: CameraUniforms,
         renderingParameters: VolumeRaycastPassRenderingParameters,
         shaderParameters: RenderingParameters,
         viewportSize: CGSize,
         clippingConfiguration: VolumeRaycastPassClippingConfiguration? = nil,
         huGate: ClosedRange<Int32>? = nil,
         optionValue: UInt16 = 0,
         targetViewSize: UInt16? = nil,
         quaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
         outputTexture: (any MTLTexture)? = nil,
         debugFrameIndex: UInt64? = nil) {
        self.volumeTexture = volumeTexture
        self.transferFunctionTexture = transferFunctionTexture
        self.accelerationTexture = accelerationTexture
        self.toneBuffers = toneBuffers
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
        self.debugFrameIndex = debugFrameIndex
    }
}

struct VolumeRaycastPassTiming: Sendable {
    var cpuDurationMilliseconds: Double
    var preCommitMilliseconds: Double
    var validationMilliseconds: Double
    var lockWaitMilliseconds: Double
    var encodeMilliseconds: Double
    var commandBufferCpuMilliseconds: Double
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
    private let perfLogger = Logger(subsystem: "com.mtk.volumerendering",
                                    category: "Benchmark.perf")

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
            let nsError = error as NSError
            Logger(subsystem: "com.mtk.volumerendering", category: "VolumeRaycastPass")
                .error("Failed to create volume_compute pipeline: \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
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

        let validationStartedAt = CFAbsoluteTimeGetCurrent()
        let viewport = try validate(input: input)
        let validationMilliseconds = Self.milliseconds(from: validationStartedAt)

        try Task.checkCancellation()
        let lockWaitStartedAt = CFAbsoluteTimeGetCurrent()
        try await inFlightLock.acquire()
        let lockWaitMilliseconds = Self.milliseconds(from: lockWaitStartedAt)

        do {
            try Task.checkCancellation()
            let encodeStartedAt = CFAbsoluteTimeGetCurrent()
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

            let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (viewport.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                 height: (viewport.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()

            let encodeMilliseconds = Self.milliseconds(from: encodeStartedAt)
            let commitStartedAt = CFAbsoluteTimeGetCurrent()
            if Logger.performanceLoggingEnabled {
                CommandBufferProfiler.captureTimes(for: commandBuffer,
                                                   label: "raycast",
                                                   category: input.renderingParameters.quality.profilerCategory)
            }
            let commandBufferID = Self.objectIdentifier(commandBuffer)
            let commandQueueID = Self.objectIdentifier(commandQueue)
            let outputTextureID = Self.objectIdentifier(outputTexture)
            logInteractionInfo(
                "[MTK3DInteraction] raycast.execute.commit frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) output=\(outputTexture.width)x\(outputTexture.height) quality=\(input.renderingParameters.quality) preCommitMs=\(Self.formatMilliseconds(Self.milliseconds(from: cpuStart, to: commitStartedAt))) encodeMs=\(Self.formatMilliseconds(encodeMilliseconds))"
            )
            let timing = try await complete(commandBuffer: commandBuffer,
                                            totalCpuStart: cpuStart,
                                            commandBufferCpuStart: commitStartedAt,
                                            preCommitMilliseconds: Self.milliseconds(from: cpuStart,
                                                                                    to: commitStartedAt),
                                            validationMilliseconds: validationMilliseconds,
                                            lockWaitMilliseconds: lockWaitMilliseconds,
                                            encodeMilliseconds: encodeMilliseconds)
            if ClinicalProfiler.shared.isRecordingEnabled {
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
            }
            if Logger.performanceLoggingEnabled {
                logRaycastPerf(input: input,
                               viewport: viewport,
                               timing: timing,
                               threadgroups: groups,
                               threadsPerThreadgroup: threadsPerThreadgroup)
            }
            logInteractionInfo(
                "[MTK3DInteraction] raycast.execute.complete frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) status=completed cpuMs=\(Self.formatMilliseconds(timing.cpuDurationMilliseconds)) gpuMs=\(Self.describeMilliseconds(timing.gpuDurationMilliseconds)) kernelMs=\(Self.describeMilliseconds(timing.kernelDurationMilliseconds))"
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

    func enqueue(input: VolumeRaycastPassInput,
                 commandQueue: any MTLCommandQueue) async throws -> VolumeRaycastPassOutput {
        let cpuStart = CFAbsoluteTimeGetCurrent()

        guard commandQueue.device === device else {
            throw VolumeRaycastPassError.commandQueueDeviceMismatch
        }

        let validationStartedAt = CFAbsoluteTimeGetCurrent()
        let viewport = try validate(input: input)
        let validationMilliseconds = Self.milliseconds(from: validationStartedAt)

        try Task.checkCancellation()
        let lockWaitStartedAt = CFAbsoluteTimeGetCurrent()
        try await inFlightLock.acquire()
        let lockWaitMilliseconds = Self.milliseconds(from: lockWaitStartedAt)

        do {
            try Task.checkCancellation()
            let encodeStartedAt = CFAbsoluteTimeGetCurrent()
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

            let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (viewport.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                 height: (viewport.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()

            let encodeMilliseconds = Self.milliseconds(from: encodeStartedAt)
            let commitStartedAt = CFAbsoluteTimeGetCurrent()
            let preCommitMilliseconds = Self.milliseconds(from: cpuStart, to: commitStartedAt)
            let initialTiming = VolumeRaycastPassTiming(
                cpuDurationMilliseconds: preCommitMilliseconds,
                preCommitMilliseconds: preCommitMilliseconds,
                validationMilliseconds: validationMilliseconds,
                lockWaitMilliseconds: lockWaitMilliseconds,
                encodeMilliseconds: encodeMilliseconds,
                commandBufferCpuMilliseconds: 0,
                gpuStartTime: nil,
                gpuEndTime: nil,
                gpuDurationMilliseconds: nil,
                kernelStartTime: nil,
                kernelEndTime: nil,
                kernelDurationMilliseconds: nil
            )

            let commandBufferID = Self.objectIdentifier(commandBuffer)
            let commandQueueID = Self.objectIdentifier(commandQueue)
            let outputTextureID = Self.objectIdentifier(outputTexture)
            logInteractionInfo(
                "[MTK3DInteraction] raycast.enqueue.commit frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) output=\(outputTexture.width)x\(outputTexture.height) quality=\(input.renderingParameters.quality) preCommitMs=\(Self.formatMilliseconds(preCommitMilliseconds)) encodeMs=\(Self.formatMilliseconds(encodeMilliseconds))"
            )
            commandBuffer.addCompletedHandler { [self, inFlightLock] buffer in
                let cpuEnd = CFAbsoluteTimeGetCurrent()
                defer {
                    Task {
                        await inFlightLock.release()
                    }
                }

                if let error = buffer.error {
                    Logger.error("CommandBuffer [raycast] failed: \(String(describing: buffer.status)) \(error.localizedDescription)",
                                 category: "com.mtk.volumerendering.Benchmark.perf")
                    Logger.info(
                        "[MTK3DInteraction] raycast.enqueue.complete frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) status=\(buffer.status.rawValue) error=\(error.localizedDescription)",
                        category: "com.mtk.volumerendering.VolumeRaycastPass"
                    )
                    return
                } else if buffer.status == .error {
                    Logger.error("CommandBuffer [raycast] failed with error status and no error object.",
                                 category: "com.mtk.volumerendering.Benchmark.perf")
                    Logger.info(
                        "[MTK3DInteraction] raycast.enqueue.complete frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) status=\(buffer.status.rawValue) error=nil",
                        category: "com.mtk.volumerendering.VolumeRaycastPass"
                    )
                    return
                }

                let timing = VolumeRaycastPassTiming(
                    cpuDurationMilliseconds: Self.milliseconds(from: cpuStart, to: cpuEnd),
                    preCommitMilliseconds: preCommitMilliseconds,
                    validationMilliseconds: validationMilliseconds,
                    lockWaitMilliseconds: lockWaitMilliseconds,
                    encodeMilliseconds: encodeMilliseconds,
                    commandBufferCpuMilliseconds: Self.milliseconds(from: commitStartedAt, to: cpuEnd),
                    gpuStartTime: Self.validTimestamp(buffer.gpuStartTime),
                    gpuEndTime: Self.validTimestamp(buffer.gpuEndTime),
                    gpuDurationMilliseconds: Self.interval(buffer.gpuStartTime, buffer.gpuEndTime),
                    kernelStartTime: Self.validTimestamp(buffer.kernelStartTime),
                    kernelEndTime: Self.validTimestamp(buffer.kernelEndTime),
                    kernelDurationMilliseconds: Self.interval(buffer.kernelStartTime, buffer.kernelEndTime)
                )
                if ClinicalProfiler.shared.isRecordingEnabled {
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
                        device: self.device
                    )
                }
                if Logger.performanceLoggingEnabled {
                    self.logRaycastPerf(input: input,
                                        viewport: viewport,
                                        timing: timing,
                                        threadgroups: groups,
                                        threadsPerThreadgroup: threadsPerThreadgroup)
                    Logger.info(
                        "[MTK3DInteraction] raycast.enqueue.complete frameIndex=\(Self.describe(input.debugFrameIndex)) commandBufferID=\(commandBufferID) commandQueueID=\(commandQueueID) outputTextureID=\(outputTextureID) status=completed cpuMs=\(Self.formatMilliseconds(timing.cpuDurationMilliseconds)) gpuMs=\(Self.describeMilliseconds(timing.gpuDurationMilliseconds)) kernelMs=\(Self.describeMilliseconds(timing.kernelDurationMilliseconds))",
                        category: "com.mtk.volumerendering.VolumeRaycastPass"
                    )
                }
            }
            commandBuffer.commit()

            return VolumeRaycastPassOutput(outputTexture: outputTexture,
                                           compositingMode: input.renderingParameters.compositingMode,
                                           quality: input.renderingParameters.quality,
                                           viewportSize: input.viewportSize,
                                           timing: initialTiming)
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

        guard let texture = OutputTextureFactory.makeTexture(
            device: device,
            width: width,
            height: height,
            label: "VolumeRaycastPass.Output"
        ) else {
            throw VolumeRaycastPassError.outputTextureUnavailable
        }
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
        guard texture.pixelFormat == OutputTextureFactory.defaultPixelFormat else {
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
        argumentManager.encode(input.toneBuffers.channel1, argumentIndex: .toneBufferCh1)
        argumentManager.encode(input.toneBuffers.channel2, argumentIndex: .toneBufferCh2)
        argumentManager.encode(input.toneBuffers.channel3, argumentIndex: .toneBufferCh3)
        argumentManager.encode(input.toneBuffers.channel4, argumentIndex: .toneBufferCh4)

        memcpy(cameraBuffer.contents(), &camera, CameraUniforms.stride)
    }

    private func complete(commandBuffer: any MTLCommandBuffer,
                          totalCpuStart: CFAbsoluteTime,
                          commandBufferCpuStart: CFAbsoluteTime,
                          preCommitMilliseconds: Double,
                          validationMilliseconds: Double,
                          lockWaitMilliseconds: Double,
                          encodeMilliseconds: Double) async throws -> VolumeRaycastPassTiming {
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
                    cpuDurationMilliseconds: Self.milliseconds(from: totalCpuStart,
                                                               to: cpuEnd),
                    preCommitMilliseconds: preCommitMilliseconds,
                    validationMilliseconds: validationMilliseconds,
                    lockWaitMilliseconds: lockWaitMilliseconds,
                    encodeMilliseconds: encodeMilliseconds,
                    commandBufferCpuMilliseconds: Self.milliseconds(from: commandBufferCpuStart,
                                                                    to: cpuEnd),
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

    private func logRaycastPerf(input: VolumeRaycastPassInput,
                                viewport: (width: Int, height: Int),
                                timing: VolumeRaycastPassTiming,
                                threadgroups: MTLSize,
                                threadsPerThreadgroup: MTLSize) {
        let gpuMinusKernel = timing.gpuDurationMilliseconds.flatMap { gpu in
            timing.kernelDurationMilliseconds.map { max(0, gpu - $0) }
        }
        let cpuMinusGpu = timing.gpuDurationMilliseconds.map {
            max(0, timing.commandBufferCpuMilliseconds - $0)
        }
        perfLogger.info(
            "[MTKPerf] raycast.phase viewport=\(viewport.width)x\(viewport.height) quality=\(input.renderingParameters.quality) compositing=\(input.renderingParameters.compositingMode) samplingDistance=\(format(input.renderingParameters.samplingDistance)) totalCPU=\(format(timing.cpuDurationMilliseconds))ms preCommit=\(format(timing.preCommitMilliseconds))ms validate=\(format(timing.validationMilliseconds))ms lockWait=\(format(timing.lockWaitMilliseconds))ms encode=\(format(timing.encodeMilliseconds))ms commandBufferCPU=\(format(timing.commandBufferCpuMilliseconds))ms gpu=\(format(timing.gpuDurationMilliseconds))ms kernel=\(format(timing.kernelDurationMilliseconds))ms gpuNonKernel=\(format(gpuMinusKernel))ms cpuMinusGPU=\(format(cpuMinusGpu))ms threadgroups=\(threadgroups.width)x\(threadgroups.height)x\(threadgroups.depth) threadsPerGroup=\(threadsPerThreadgroup.width)x\(threadsPerThreadgroup.height)x\(threadsPerThreadgroup.depth)"
        )
    }

    private func logInteractionInfo(_ message: @autoclosure () -> String) {
        guard Logger.performanceLoggingEnabled else { return }
        Logger.info(message(), category: "com.mtk.volumerendering.VolumeRaycastPass")
    }

    private static func validTimestamp(_ timestamp: CFTimeInterval) -> CFTimeInterval? {
        timestamp > 0 ? timestamp : nil
    }

    private static func milliseconds(from start: CFAbsoluteTime,
                                     to end: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        max(0, (end - start) * 1000.0)
    }

    private static func objectIdentifier(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    private static func describe(_ value: UInt64?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func describeMilliseconds(_ value: Double?) -> String {
        value.map(formatMilliseconds) ?? "nil"
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func interval(_ start: CFTimeInterval, _ end: CFTimeInterval) -> Double? {
        guard start > 0, end > 0, end >= start else { return nil }
        return (end - start) * 1000.0
    }

    private func format(_ value: Float) -> String {
        String(format: "%.5f", value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.3f", value)
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
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    func acquire() async throws {
        try Task.checkCancellation()
        if !isLocked {
            isLocked = true
            return
        }

        let id = nextWaiterID
        nextWaiterID &+= 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }
}
