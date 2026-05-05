//
//  MetalSurfaceMeshRenderer.swift
//  MTKCore
//
//  Minimal Metal triangle renderer for segmentation surface overlays.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

public enum MetalSurfaceMeshRendererError: Error, Equatable, LocalizedError {
    case commandQueueCreationFailed
    case commandQueueDeviceMismatch
    case shaderLibraryUnavailable
    case shaderLibraryDeviceMismatch
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed
    case depthStencilCreationFailed
    case invalidRenderTarget(String)
    case invalidMesh(String)
    case bufferCreationFailed
    case commandBufferCreationFailed
    case encoderCreationFailed
    case commandBufferFailed(String)
    case degenerateCamera

    public var errorDescription: String? {
        switch self {
        case .commandQueueCreationFailed:
            return "Metal surface mesh renderer could not create a command queue."
        case .commandQueueDeviceMismatch:
            return "Metal surface mesh renderer command queue belongs to a different device."
        case .shaderLibraryUnavailable:
            return "Metal surface mesh renderer could not load MTK.metallib."
        case .shaderLibraryDeviceMismatch:
            return "Metal surface mesh renderer shader library belongs to a different device."
        case .shaderFunctionUnavailable(let name):
            return "Metal surface mesh renderer missing shader function \(name)."
        case .pipelineCreationFailed:
            return "Metal surface mesh renderer could not create its render pipeline."
        case .depthStencilCreationFailed:
            return "Metal surface mesh renderer could not create its depth stencil state."
        case .invalidRenderTarget(let reason):
            return "Invalid surface mesh render target: \(reason)"
        case .invalidMesh(let reason):
            return "Invalid surface mesh: \(reason)"
        case .bufferCreationFailed:
            return "Metal surface mesh renderer could not create GPU buffers."
        case .commandBufferCreationFailed:
            return "Metal surface mesh renderer could not create a command buffer."
        case .encoderCreationFailed:
            return "Metal surface mesh renderer could not create a render encoder."
        case .commandBufferFailed(let description):
            return "Metal surface mesh renderer command buffer failed: \(description)"
        case .degenerateCamera:
            return "Metal surface mesh renderer received a degenerate camera."
        }
    }
}

public final class MetalSurfaceMeshRenderer: @unchecked Sendable {
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var color: SIMD4<Float>
        var texturePosition: SIMD3<Float>
    }

    private struct Uniforms {
        var viewProjectionMatrix: simd_float4x4
        var lightDirection: SIMD4<Float>
        var cropMin: SIMD4<Float>
        var cropMax: SIMD4<Float>
        var clipPlane0: SIMD4<Float>
        var clipPlane1: SIMD4<Float>
        var clipPlane2: SIMD4<Float>
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let opaqueDepthStencilState: any MTLDepthStencilState
    private let transparentDepthStencilState: any MTLDepthStencilState

    public init(device: any MTLDevice,
                commandQueue: (any MTLCommandQueue)? = nil,
                library: (any MTLLibrary)? = nil) throws {
        let queue: any MTLCommandQueue
        if let commandQueue {
            guard commandQueue.device === device else {
                throw MetalSurfaceMeshRendererError.commandQueueDeviceMismatch
            }
            queue = commandQueue
        } else if let createdQueue = device.makeCommandQueue() {
            queue = createdQueue
        } else {
            throw MetalSurfaceMeshRendererError.commandQueueCreationFailed
        }

        let resolvedLibrary: any MTLLibrary
        if let library {
            resolvedLibrary = library
        } else {
            do {
                resolvedLibrary = try ShaderLibraryLoader.loadLibrary(for: device)
            } catch {
                throw MetalSurfaceMeshRendererError.shaderLibraryUnavailable
            }
        }

        guard resolvedLibrary.device === device else {
            throw MetalSurfaceMeshRendererError.shaderLibraryDeviceMismatch
        }
        guard let vertexFunction = resolvedLibrary.makeFunction(name: "surface_mesh_vertex") else {
            throw MetalSurfaceMeshRendererError.shaderFunctionUnavailable("surface_mesh_vertex")
        }
        guard let fragmentFunction = resolvedLibrary.makeFunction(name: "surface_mesh_fragment") else {
            throw MetalSurfaceMeshRendererError.shaderFunctionUnavailable("surface_mesh_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MetalSurfaceMeshRenderer.Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float

        let pipeline: any MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalSurfaceMeshRendererError.pipelineCreationFailed
        }

        let opaqueDepthDescriptor = MTLDepthStencilDescriptor()
        opaqueDepthDescriptor.depthCompareFunction = .lessEqual
        opaqueDepthDescriptor.isDepthWriteEnabled = true
        guard let opaqueDepthStencilState = device.makeDepthStencilState(descriptor: opaqueDepthDescriptor) else {
            throw MetalSurfaceMeshRendererError.depthStencilCreationFailed
        }

        let transparentDepthDescriptor = MTLDepthStencilDescriptor()
        transparentDepthDescriptor.depthCompareFunction = .lessEqual
        transparentDepthDescriptor.isDepthWriteEnabled = false
        guard let transparentDepthStencilState = device.makeDepthStencilState(descriptor: transparentDepthDescriptor) else {
            throw MetalSurfaceMeshRendererError.depthStencilCreationFailed
        }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.opaqueDepthStencilState = opaqueDepthStencilState
        self.transparentDepthStencilState = transparentDepthStencilState
    }

    @discardableResult
    public func render(layers: [SurfaceMeshLayer],
                       dataset: VolumeDataset,
                       camera: VolumeRenderRequest.Camera,
                       targetTexture: any MTLTexture,
                       clipping: VolumeClippingState = .disabled,
                       clearTarget: Bool = false) async throws -> any MTLTexture {
        try validate(targetTexture)
        let visibleLayers = layers.filter { layer in
            layer.isVisible &&
                layer.clampedOpacity > 0 &&
                layer.mesh.isRenderable
        }
        guard !visibleLayers.isEmpty || clearTarget else {
            return targetTexture
        }

        let opaqueLayers = visibleLayers.filter { effectiveAlpha(for: $0) >= 0.999 }
        let transparentLayers = depthSortedTransparentLayers(
            visibleLayers.filter { effectiveAlpha(for: $0) < 0.999 },
            dataset: dataset,
            camera: camera
        )
        let opaqueInput = try makeBuffersInput(from: opaqueLayers,
                                               dataset: dataset)
        let transparentInput = try makeBuffersInput(from: transparentLayers,
                                                    dataset: dataset)
        guard !opaqueInput.indices.isEmpty || !transparentInput.indices.isEmpty || clearTarget else {
            return targetTexture
        }

        let opaqueBuffers = try makeBuffers(vertices: opaqueInput.vertices,
                                            indices: opaqueInput.indices,
                                            label: "SurfaceMesh.opaque")
        let transparentBuffers = try makeBuffers(vertices: transparentInput.vertices,
                                                 indices: transparentInput.indices,
                                                 label: "SurfaceMesh.transparent")
        let clipPlanes = try clipping.shaderClipPlanes(for: dataset)
        let cropBox = clipping.cropBox ?? .full
        var uniforms = Uniforms(
            viewProjectionMatrix: try makeViewProjectionMatrix(camera: camera,
                                                               viewportSize: (targetTexture.width, targetTexture.height)),
            lightDirection: SIMD4<Float>(simd_normalize(SIMD3<Float>(-0.4, -0.6, -0.7)), 0),
            cropMin: SIMD4<Float>(cropBox.textureMin, 0),
            cropMax: SIMD4<Float>(cropBox.textureMax, 0),
            clipPlane0: clipPlanes.0,
            clipPlane1: clipPlanes.1,
            clipPlane2: clipPlanes.2
        )
        guard let uniformBuffer = device.makeBuffer(bytes: &uniforms,
                                                    length: MemoryLayout<Uniforms>.stride,
                                                    options: [.storageModeShared]) else {
            throw MetalSurfaceMeshRendererError.bufferCreationFailed
        }
        uniformBuffer.label = "SurfaceMesh.uniforms"

        let depthTexture = try makeDepthTexture(width: targetTexture.width,
                                                height: targetTexture.height)
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = targetTexture
        renderPass.colorAttachments[0].loadAction = clearTarget ? .clear : .load
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.storeAction = .dontCare
        renderPass.depthAttachment.clearDepth = 1

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalSurfaceMeshRendererError.commandBufferCreationFailed
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw MetalSurfaceMeshRendererError.encoderCreationFailed
        }

        commandBuffer.label = "MetalSurfaceMeshRenderer.Render"
        encoder.label = "MetalSurfaceMeshRenderer.Encoder"
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        if let opaqueBuffers {
            encoder.setDepthStencilState(opaqueDepthStencilState)
            encoder.setVertexBuffer(opaqueBuffers.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: opaqueBuffers.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: opaqueBuffers.indices,
                                          indexBufferOffset: 0)
        }
        if let transparentBuffers {
            encoder.setDepthStencilState(transparentDepthStencilState)
            encoder.setVertexBuffer(transparentBuffers.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: transparentBuffers.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: transparentBuffers.indices,
                                          indexBufferOffset: 0)
        }
        encoder.endEncoding()

        try await complete(commandBuffer)
        return targetTexture
    }

    private struct BufferInput {
        var vertices: [Vertex]
        var indices: [UInt32]
    }

    private struct DrawBuffers {
        var vertices: any MTLBuffer
        var indices: any MTLBuffer
        var indexCount: Int
    }

    private func makeBuffersInput(from layers: [SurfaceMeshLayer],
                                  dataset: VolumeDataset) throws -> BufferInput {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        for layer in layers {
            let mesh = layer.mesh
            guard mesh.isRenderable else {
                throw MetalSurfaceMeshRendererError.invalidMesh("Layer \(layer.id) has mismatched vertices, normals, or indices.")
            }
            let alpha = layer.clampedOpacity * clamp01(meshAlpha(layer.material.color))
            guard alpha > 0 else { continue }
            let color = SIMD4<Float>(
                clamp01(layer.material.color.x),
                clamp01(layer.material.color.y),
                clamp01(layer.material.color.z),
                alpha
            )
            let start = UInt32(vertices.count)
            for vertexIndex in mesh.vertices.indices {
                let texturePosition = texturePosition(for: mesh.vertices[vertexIndex],
                                                      coordinateSpace: mesh.coordinateSpace,
                                                      dataset: dataset)
                let textureNormal = normal(for: mesh.normals[vertexIndex],
                                           coordinateSpace: mesh.coordinateSpace,
                                           dataset: dataset)
                vertices.append(Vertex(position: texturePosition - SIMD3<Float>(repeating: 0.5),
                                       normal: textureNormal,
                                       color: color,
                                       texturePosition: texturePosition))
            }
            indices.append(contentsOf: mesh.indices.map { start + $0 })
        }

        return BufferInput(vertices: vertices, indices: indices)
    }

    private func makeBuffers(vertices: [Vertex],
                             indices: [UInt32],
                             label: String) throws -> DrawBuffers? {
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices,
                                                   length: MemoryLayout<Vertex>.stride * vertices.count,
                                                   options: [.storageModeShared]),
              let indexBuffer = device.makeBuffer(bytes: indices,
                                                  length: MemoryLayout<UInt32>.stride * indices.count,
                                                  options: [.storageModeShared])
        else {
            throw MetalSurfaceMeshRendererError.bufferCreationFailed
        }
        vertexBuffer.label = "\(label).vertices"
        indexBuffer.label = "\(label).indices"
        return DrawBuffers(vertices: vertexBuffer,
                           indices: indexBuffer,
                           indexCount: indices.count)
    }

    private func depthSortedTransparentLayers(_ layers: [SurfaceMeshLayer],
                                              dataset: VolumeDataset,
                                              camera: VolumeRenderRequest.Camera) -> [SurfaceMeshLayer] {
        // Whole-layer sorting is an intentional approximation for non-intersecting clinical segments.
        layers.sorted { lhs, rhs in
            let lhsDistance = layerDistanceSquared(lhs, dataset: dataset, camera: camera)
            let rhsDistance = layerDistanceSquared(rhs, dataset: dataset, camera: camera)
            if lhsDistance == rhsDistance {
                return lhs.id < rhs.id
            }
            return lhsDistance > rhsDistance
        }
    }

    private func layerDistanceSquared(_ layer: SurfaceMeshLayer,
                                      dataset: VolumeDataset,
                                      camera: VolumeRenderRequest.Camera) -> Float {
        guard let bounds = layer.mesh.bounds else { return 0 }
        let center = texturePosition(for: bounds.center,
                                     coordinateSpace: layer.mesh.coordinateSpace,
                                     dataset: dataset)
        return simd_length_squared(center - camera.position)
    }

    private func effectiveAlpha(for layer: SurfaceMeshLayer) -> Float {
        layer.clampedOpacity * clamp01(meshAlpha(layer.material.color))
    }

    private func texturePosition(for vertex: SIMD3<Float>,
                                 coordinateSpace: SurfaceMeshCoordinateSpace,
                                 dataset: VolumeDataset) -> SIMD3<Float> {
        switch coordinateSpace {
        case .worldMillimeters:
            return dataset.imageData.worldToTexture.transformPoint(vertex)
        case .textureNormalized:
            return vertex
        }
    }

    private func normal(for normal: SIMD3<Float>,
                        coordinateSpace: SurfaceMeshCoordinateSpace,
                        dataset: VolumeDataset) -> SIMD3<Float> {
        let transformed: SIMD3<Float>
        switch coordinateSpace {
        case .worldMillimeters:
            let matrix = simd_float3x3(
                SIMD3<Float>(dataset.imageData.worldToTexture.columns.0.x,
                             dataset.imageData.worldToTexture.columns.0.y,
                             dataset.imageData.worldToTexture.columns.0.z),
                SIMD3<Float>(dataset.imageData.worldToTexture.columns.1.x,
                             dataset.imageData.worldToTexture.columns.1.y,
                             dataset.imageData.worldToTexture.columns.1.z),
                SIMD3<Float>(dataset.imageData.worldToTexture.columns.2.x,
                             dataset.imageData.worldToTexture.columns.2.y,
                             dataset.imageData.worldToTexture.columns.2.z)
            )
            transformed = matrix * normal
        case .textureNormalized:
            transformed = normal
        }
        let length = simd_length(transformed)
        return length > Float.ulpOfOne ? transformed / length : SIMD3<Float>(0, 0, 1)
    }

    private func validate(_ texture: any MTLTexture) throws {
        guard texture.device === device else {
            throw MetalSurfaceMeshRendererError.invalidRenderTarget("Texture belongs to a different Metal device.")
        }
        guard texture.textureType == .type2D else {
            throw MetalSurfaceMeshRendererError.invalidRenderTarget("Texture must be 2D.")
        }
        guard texture.pixelFormat == .bgra8Unorm else {
            throw MetalSurfaceMeshRendererError.invalidRenderTarget("Expected bgra8Unorm target, got \(texture.pixelFormat).")
        }
        guard texture.usage.contains(.renderTarget) else {
            throw MetalSurfaceMeshRendererError.invalidRenderTarget("Texture usage must include renderTarget.")
        }
    }

    private func makeDepthTexture(width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalSurfaceMeshRendererError.invalidRenderTarget("Could not create depth texture.")
        }
        texture.label = "SurfaceMesh.depth"
        return texture
    }

    private func complete(_ commandBuffer: any MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            commandBuffer.addCompletedHandler { completed in
                if let error = completed.error {
                    continuation.resume(throwing: MetalSurfaceMeshRendererError.commandBufferFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
            commandBuffer.commit()
        }
    }

    private func makeViewProjectionMatrix(camera: VolumeRenderRequest.Camera,
                                          viewportSize: (width: Int, height: Int)) throws -> simd_float4x4 {
        let centered = VolumeRenderRequest.Camera(
            position: camera.position - SIMD3<Float>(repeating: 0.5),
            target: camera.target - SIMD3<Float>(repeating: 0.5),
            up: camera.up,
            fieldOfView: camera.fieldOfView,
            projectionType: camera.projectionType
        )
        let aspect = max(Float(viewportSize.width) / Float(max(viewportSize.height, 1)), 1e-3)
        let view = try simd_float4x4(surfaceMeshLookAt: centered.position,
                                     target: centered.target,
                                     up: centered.up)
        let center = SIMD3<Float>.zero
        let distanceToCenter = simd_length(centered.position - center)
        let farPadding = distanceToCenter * 0.1 + 1
        let nearZ: Float = 0.01
        let farZ = max(distanceToCenter + farPadding, nearZ + 100)

        let projection: simd_float4x4
        if centered.projectionType == .orthographic {
            let viewHeight: Float = 2
            projection = simd_float4x4(surfaceMeshOrthographicWidth: viewHeight * aspect,
                                       height: viewHeight,
                                       nearZ: nearZ,
                                       farZ: farZ)
        } else {
            projection = simd_float4x4(surfaceMeshPerspectiveFovY: max(centered.fieldOfView * .pi / 180, 0.01),
                                       aspect: aspect,
                                       nearZ: nearZ,
                                       farZ: farZ)
        }
        return projection * view
    }

    private func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func meshAlpha(_ color: SIMD4<Float>) -> Float {
        color.w
    }
}

private extension simd_float4x4 {
    init(surfaceMeshLookAt eye: SIMD3<Float>,
         target: SIMD3<Float>,
         up: SIMD3<Float>) throws {
        let zAxis = simd_normalize(eye - target)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        guard zAxis.surfaceMeshAllFinite,
              xAxis.surfaceMeshAllFinite,
              yAxis.surfaceMeshAllFinite else {
            throw MetalSurfaceMeshRendererError.degenerateCamera
        }
        let translation = SIMD3<Float>(
            -simd_dot(xAxis, eye),
            -simd_dot(yAxis, eye),
            -simd_dot(zAxis, eye)
        )
        self = simd_float4x4(columns: (
            SIMD4<Float>(xAxis, 0),
            SIMD4<Float>(yAxis, 0),
            SIMD4<Float>(zAxis, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    init(surfaceMeshPerspectiveFovY fovY: Float,
         aspect: Float,
         nearZ: Float,
         farZ: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / max(aspect, 1e-3)
        let z = farZ / (nearZ - farZ)
        let wz = (farZ * nearZ) / (nearZ - farZ)
        self = simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, wz, 0)
        ))
    }

    init(surfaceMeshOrthographicWidth width: Float,
         height: Float,
         nearZ: Float,
         farZ: Float) {
        let range = nearZ - farZ
        self = simd_float4x4(columns: (
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1 / range, 0),
            SIMD4<Float>(0, 0, nearZ / range, 1)
        ))
    }
}

private extension SIMD3 where Scalar == Float {
    var surfaceMeshAllFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
