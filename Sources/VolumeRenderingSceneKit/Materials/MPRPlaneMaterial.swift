//
//  MPRPlaneMaterial.swift
//  Isis DICOM Viewer
//
//  Material SceneKit dedicado a planos de reconstrução multiplanar. Habilita MPR fino
//  ou thick slab com projeções, aplicando a mesma textura do volume para amostragem
//  consistente. Sincroniza uniforms com o shader Metal responsável pela renderização.
//
//  Thales Matheus Mendonça Santos - September 2025
//

import Metal
import OSLog
import SceneKit
import simd
import VolumeRenderingCore

public final class MPRPlaneMaterial: SCNMaterial, SCNProgramDelegate {
    public enum BlendMode: Int32, CaseIterable {
        case single = 0
        case mip = 1
        case minip = 2
        case mean = 3
    }

    public struct Uniforms: sizeable {
        var voxelMinValue: Int32 = -1024
        var voxelMaxValue: Int32 = 3071
        var blendMode: Int32 = BlendMode.single.rawValue
        var numSteps: Int32 = 1
        var flipVertical: Int32 = 0
        var slabHalf: Float = 0
        var _pad0: SIMD2<Float> = .zero

        var planeOrigin: SIMD3<Float> = .zero
        var _pad1: Float = 0
        var planeX: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
        var _pad2: Float = 0
        var planeY: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
        var _pad3: Float = 0

        public init() {}
    }

    private var uniforms = Uniforms()
    private let uniformsKey = "U"
    private let volumeKey = "volume"
    private var uniformBuffer: (any MTLBuffer)?
    private var volumeTexture: (any MTLTexture)?
    private let fallbackVolumeTexture: (any MTLTexture)

    public private(set) var dimension: SIMD3<Int32> = SIMD3<Int32>(1, 1, 1)
    public private(set) var resolution: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    private var textureFactory: VolumeTextureFactory = VolumeTextureFactory(part: .none)
    private let logger = Logger(subsystem: "com.isis.volumerenderingkit",
                                category: "MPRPlaneMaterial")

    public init(device: any MTLDevice) {
        fallbackVolumeTexture = MPRPlaneMaterial.makeFallbackVolumeTexture(device: device)
        super.init()
        let program = SCNProgram()
        program.vertexFunctionName = "mpr_vertex"
        program.fragmentFunctionName = "mpr_fragment"
        program.delegate = self
        program.handleBinding(ofBufferNamed: uniformsKey, frequency: .perFrame) { [weak self] _, _, _, renderer in
            guard let self,
                  let encoder = renderer.currentRenderCommandEncoder,
                  let buffer = self.uniformBuffer else { return }
            self.syncUniforms()
            encoder.setFragmentBuffer(buffer, offset: 0, index: 4)
        }
        self.program = program

        isDoubleSided = true
        writesToDepthBuffer = false
        readsFromDepthBuffer = false
        cullMode = .back

        uniformBuffer = device.makeBuffer(length: Uniforms.stride, options: .storageModeShared)
        uniformBuffer?.label = "MPRPlaneUniforms"
        syncUniforms()

        bindVolumeTexture(fallbackVolumeTexture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setDataset(dimension: SIMD3<Int32>, resolution: SIMD3<Float>) {
        self.dimension = dimension
        self.resolution = resolution
    }

    public func setPart(device: any MTLDevice, part: VolumeCubeMaterial.BodyPart) {
        apply(factory: VolumeTextureFactory(part: part), device: device)
    }

    public func setDataset(device: any MTLDevice,
                           dataset: VolumeDataset,
                           volumeTexture: (any MTLTexture)? = nil) {
        apply(factory: VolumeTextureFactory(dataset: dataset),
              device: device,
              overrideTexture: volumeTexture)
    }

    public func setHU(min: Int32, max: Int32) {
        uniforms.voxelMinValue = min
        uniforms.voxelMaxValue = max
        syncUniforms()
    }

    public func setBlend(_ mode: BlendMode) {
        uniforms.blendMode = mode.rawValue
        syncUniforms()
    }

    public func setSlab(thicknessInVoxels: Int, axis: Int, steps: Int) {
        let denominator: Float
        switch axis {
        case 0:
            denominator = max(1, Float(dimension.x))
        case 1:
            denominator = max(1, Float(dimension.y))
        default:
            denominator = max(1, Float(dimension.z))
        }
        uniforms.slabHalf = 0.5 * Float(thicknessInVoxels) / denominator
        uniforms.numSteps = Int32(max(1, steps))
        syncUniforms()
    }

    public func setAxial(slice index: Int) {
        let clamped = max(0, min(Int(dimension.z) - 1, index))
        let z = (Float(clamped) + 0.5) / max(1, Float(dimension.z))
        uniforms.planeOrigin = SIMD3<Float>(0, 0, z)
        uniforms.planeX = SIMD3<Float>(1, 0, 0)
        uniforms.planeY = SIMD3<Float>(0, 1, 0)
        setVerticalFlip(false)
        syncUniforms()
    }

    public func setSagittal(column index: Int) {
        let clamped = max(0, min(Int(dimension.x) - 1, index))
        let x = (Float(clamped) + 0.5) / max(1, Float(dimension.x))
        uniforms.planeOrigin = SIMD3<Float>(x, 0, 0)
        uniforms.planeX = SIMD3<Float>(0, 1, 0)
        uniforms.planeY = SIMD3<Float>(0, 0, 1)
        setVerticalFlip(false)
        syncUniforms()
    }

    public func setCoronal(row index: Int) {
        let clamped = max(0, min(Int(dimension.y) - 1, index))
        let y = (Float(clamped) + 0.5) / max(1, Float(dimension.y))
        uniforms.planeOrigin = SIMD3<Float>(0, y, 0)
        uniforms.planeX = SIMD3<Float>(1, 0, 0)
        uniforms.planeY = SIMD3<Float>(0, 0, 1)
        setVerticalFlip(false)
        syncUniforms()
    }

    public func setOblique(origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        uniforms.planeOrigin = origin
        uniforms.planeX = axisU
        uniforms.planeY = axisV
        syncUniforms()
    }

    public func setVerticalFlip(_ enabled: Bool) {
        uniforms.flipVertical = enabled ? 1 : 0
    }

    private func syncUniforms() {
        guard let buffer = uniformBuffer else { return }
        var current = uniforms
        memcpy(buffer.contents(), &current, Uniforms.stride)
    }
}

private extension MPRPlaneMaterial {
    func apply(factory: VolumeTextureFactory,
               device: any MTLDevice,
               overrideTexture: (any MTLTexture)? = nil) {
        textureFactory = factory
        guard let texture = overrideTexture ?? factory.generate(device: device) else {
            logger.error("Failed to generate 3D texture for MPR; binding fallback placeholder")
            bindVolumeTexture(fallbackVolumeTexture)
            return
        }

        guard texture.textureType == .type3D else {
            logger.fault("Volume texture must be 3D. Received type=\(texture.textureType.rawValue)")
            bindVolumeTexture(fallbackVolumeTexture)
            return
        }

        guard texture.pixelFormat == .r16Sint else {
            logger.fault("Volume texture must be r16Sint. Received pixelFormat=\(texture.pixelFormat.rawValue)")
            bindVolumeTexture(fallbackVolumeTexture)
            return
        }

        dimension = factory.dimension
        resolution = factory.resolution

        let range = factory.dataset.intensityRange
        uniforms.voxelMinValue = range.lowerBound
        uniforms.voxelMaxValue = range.upperBound
        syncUniforms()

        bindVolumeTexture(texture)
        logger.debug("MPR texture ready dim=\(self.dimension) spacing=\(self.resolution) type=\(texture.textureType.rawValue) pf=\(texture.pixelFormat.rawValue)")
    }
}

// MARK: - SCNProgramDelegate

extension MPRPlaneMaterial {
    public func program(_ program: SCNProgram, handleError error: any Error) {
        logger.error("SCNProgram error: \(error.localizedDescription)")
    }
}

private extension MPRPlaneMaterial {
    func bindVolumeTexture(_ texture: any MTLTexture) {
        volumeTexture = texture
        setValue(SCNMaterialProperty(contents: texture as Any), forKey: volumeKey)
    }

    static func makeFallbackVolumeTexture(device: any MTLDevice) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = 1
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "MPRVolumeFallback"
        var zero: Int16 = 0
        texture?.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                         mipmapLevel: 0,
                         slice: 0,
                         withBytes: &zero,
                         bytesPerRow: MemoryLayout<Int16>.stride,
                         bytesPerImage: MemoryLayout<Int16>.stride)
        return texture ?? MPRPlaneMaterial.nullFallbackTexture(device: device)
    }

    static func nullFallbackTexture(device: any MTLDevice) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Sint
        descriptor.width = 1
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Unable to allocate fallback 3D texture for MPR")
        }
        texture.label = "MPRVolumeFallback.Null"
        return texture
    }

}

#if DEBUG
@_spi(Testing) extension MPRPlaneMaterial {
    public func debugApply(factory: VolumeTextureFactory, device: any MTLDevice) {
        apply(factory: factory, device: device)
    }

    public func debugVolumeTexture() -> (any MTLTexture)? {
        volumeTexture
    }

    public func debugFallbackTexture() -> (any MTLTexture) {
        fallbackVolumeTexture
    }
}
#endif
