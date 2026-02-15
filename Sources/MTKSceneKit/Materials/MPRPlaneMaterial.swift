//
//  MPRPlaneMaterial.swift
//  MTK
//
//  Material SceneKit dedicado a planos de reconstrução multiplanar. Habilita MPR fino
//  ou thick slab com projeções, aplicando a mesma textura do volume para amostragem
//  consistente. Sincroniza uniforms com o shader Metal responsável pela renderização.
//
//  Thales Matheus Mendonça Santos — October 2025
//

import Metal
import SceneKit
import simd
import MTKCore

/// SceneKit material for multiplanar reconstruction (MPR) rendering.
///
/// `MPRPlaneMaterial` displays 2D slices extracted from a 3D volume texture, supporting
/// thin-slice MPR and thick-slab projections (MIP/MinIP/Mean). It binds the same volume texture
/// used by ``VolumeCubeMaterial``, ensuring consistent sampling across volumetric and planar views.
///
/// ## Overview
///
/// This material coordinates:
/// - **Slice orientation**: Axial, sagittal, coronal, or oblique planes defined by origin and axis vectors
/// - **Thick slabs**: Controlled by slab thickness and blend mode (single-slice, MIP, MinIP, average)
/// - **HU windowing**: Synchronizes min/max intensity thresholds with the volume material
/// - **Shader programs**: SceneKit SCNProgram wrapping Metal vertex/fragment functions (`mpr_vertex`, `mpr_fragment`)
///
/// ## Usage
///
/// Attach this material to a plane geometry for synchronized tri-planar viewing:
///
/// ```swift
/// let material = MPRPlaneMaterial(device: metalDevice)
/// material.setDataset(device: metalDevice, dataset: dicomVolume, volumeTexture: sharedTexture)
/// material.setAxial(slice: 128)
/// material.setHU(min: -500, max: 1200)
///
/// let planeGeometry = SCNPlane(width: 1, height: 1)
/// planeGeometry.firstMaterial = material
/// ```
///
/// ## Thick Slabs
///
/// Enable thick-slab projections with ``setSlab(thicknessInVoxels:axis:steps:)`` and select a blend mode:
/// - `.single`: Thin slice (default)
/// - `.mip`: Maximum intensity projection through slab
/// - `.minip`: Minimum intensity projection
/// - `.mean`: Average intensity across slab
///
/// ## Thread Safety
///
/// All methods are safe to call from any thread, as uniform updates use `memcpy` to a shared buffer.
///
public final class MPRPlaneMaterial: SCNMaterial, SCNProgramDelegate {
    /// Blend mode for thick-slab MPR projections.
    ///
    /// Controls how multiple samples along the slab normal are combined:
    /// - `.single`: Renders a single thin slice at the plane origin (no projection).
    /// - `.mip`: Maximum Intensity Projection—displays the brightest voxel along the slab.
    /// - `.minip`: Minimum Intensity Projection—displays the darkest voxel along the slab.
    /// - `.mean`: Average Intensity Projection—computes the mean value across the slab.
    ///
    /// Set via ``setBlend(_:)`` and paired with ``setSlab(thicknessInVoxels:axis:steps:)``.
    public enum BlendMode: Int32, CaseIterable {
        case single = 0
        case mip = 1
        case minip = 2
        case mean = 3
    }

    /// GPU-side uniform buffer matching the Metal shader's `MPRUniforms` struct.
    ///
    /// Synchronizes plane geometry, HU windowing, slab thickness, and blend mode with the
    /// `mpr_fragment` shader. Fields must match Metal struct layout exactly (including padding)
    /// to avoid alignment issues.
    ///
    /// - Note: Padding fields (`_pad0`, `_pad1`, etc.) ensure 16-byte alignment for SIMD vectors.
    public struct Uniforms: sizeable {
        public var voxelMinValue: Int32 = -1024
        public var voxelMaxValue: Int32 = 3071
        public var blendMode: Int32 = BlendMode.single.rawValue
        public var numSteps: Int32 = 1
        public var flipVertical: Int32 = 0
        public var slabHalf: Float = 0
        public var _pad0: SIMD2<Float> = .zero

        public var planeOrigin: SIMD3<Float> = .zero
        public var _pad1: Float = 0
        public var planeX: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
        public var _pad2: Float = 0
        public var planeY: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
        public var _pad3: Float = 0

        public init() {}
    }

    private let device: any MTLDevice
    private var uniforms = Uniforms()
    private let uniformsKey = "U"
    private let volumeKey = "volume"
    private var uniformBuffer: (any MTLBuffer)?
    private var volumeTexture: (any MTLTexture)?
    private let fallbackVolumeTexture: (any MTLTexture)

    /// Volume dimensions in voxels (width, height, depth).
    ///
    /// Updated via ``setDataset(dimension:resolution:)`` or ``setDataset(device:dataset:volumeTexture:)``.
    public private(set) var dimension: SIMD3<Int32> = SIMD3<Int32>(1, 1, 1)

    /// Voxel spacing in physical units (meters per voxel).
    ///
    /// Used to compute correct aspect ratios and slice positions.
    public private(set) var resolution: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    private var textureFactory: VolumeTextureFactory = VolumeTextureFactory(part: .none)
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "MPRPlaneMaterial")

    /// Initializes an MPR material bound to the specified Metal device.
    ///
    /// Sets up SceneKit shader programs (`mpr_vertex`, `mpr_fragment`), allocates a uniform buffer,
    /// and binds a 1×1×1 fallback texture until ``setDataset(device:dataset:volumeTexture:)`` is called.
    ///
    /// - Parameter device: Metal device for buffer and texture allocation.
    ///
    /// - Note: The material is configured as double-sided with depth writing disabled,
    ///         suitable for overlay rendering in synchronized tri-planar views.
    public init(device: any MTLDevice) {
        self.device = device
        fallbackVolumeTexture = MPRPlaneMaterial.makeFallbackVolumeTexture(device: device)
        super.init()
        let program = SCNProgram()
        program.vertexFunctionName = "mpr_vertex"
        program.fragmentFunctionName = "mpr_fragment"
        program.delegate = self
        assignProgramLibrary(program)
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

    /// Updates volume dimensions and voxel spacing without changing the texture binding.
    ///
    /// Useful when synchronizing metadata across multiple MPR materials sharing the same texture.
    ///
    /// - Parameters:
    ///   - dimension: Volume size in voxels.
    ///   - resolution: Voxel spacing in meters.
    public func setDataset(dimension: SIMD3<Int32>, resolution: SIMD3<Float>) {
        self.dimension = dimension
        self.resolution = resolution
    }

    /// Loads a preset volumetric dataset for testing or fallback scenarios.
    ///
    /// Generates a synthetic or embedded volume when DICOM data is unavailable.
    /// Typically used during development to verify shader behavior.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture generation.
    ///   - part: Preset volume type from ``VolumeCubeMaterial/BodyPart``.
    public func setPart(device: any MTLDevice, part: VolumeCubeMaterial.BodyPart) {
        apply(factory: VolumeTextureFactory(part: part), device: device)
    }

    /// Binds a volumetric dataset and optional pre-generated 3D texture.
    ///
    /// Updates dimension, resolution, intensity range, and volume texture. When `volumeTexture` is provided,
    /// it is used directly instead of generating a new texture. This enables shared texture bindings
    /// between ``VolumeCubeMaterial`` and multiple MPR planes, reducing memory overhead.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture generation (if needed).
    ///   - dataset: Volume data containing voxels, spacing, and intensity metadata.
    ///   - volumeTexture: Optional pre-generated 3D texture to reuse. Must be `.type3D` with `.r16Sint` pixel format.
    ///
    /// - Note: If texture validation fails (wrong type or pixel format), the material falls back to
    ///         a 1×1×1 placeholder texture and logs a fault-level error.
    public func setDataset(device: any MTLDevice,
                           dataset: VolumeDataset,
                           volumeTexture: (any MTLTexture)? = nil) {
        apply(factory: VolumeTextureFactory(dataset: dataset),
              device: device,
              overrideTexture: volumeTexture)
    }

    /// Sets the Hounsfield Unit window for intensity mapping.
    ///
    /// Voxels are normalized using these bounds before display. Should match the HU window
    /// applied to the corresponding ``VolumeCubeMaterial`` for consistent appearance.
    ///
    /// - Parameters:
    ///   - min: Minimum visible intensity (e.g., -1024 for air).
    ///   - max: Maximum visible intensity (e.g., 3071 for dense bone).
    public func setHU(min: Int32, max: Int32) {
        uniforms.voxelMinValue = min
        uniforms.voxelMaxValue = max
        syncUniforms()
    }

    /// Sets the blend mode for thick-slab projections.
    ///
    /// Determines how multiple samples along the slab normal are combined. Use `.single` for
    /// thin-slice MPR, or `.mip`/`.minip`/`.mean` for thick-slab projections.
    ///
    /// - Parameter mode: Desired blend mode from ``BlendMode``.
    ///
    /// - SeeAlso: ``setSlab(thicknessInVoxels:axis:steps:)``
    public func setBlend(_ mode: BlendMode) {
        uniforms.blendMode = mode.rawValue
        syncUniforms()
    }

    /// Configures thick-slab projection parameters.
    ///
    /// Enables projection modes by setting a non-zero slab thickness. The slab is centered
    /// on the plane origin and extends `±slabHalf` along the plane normal.
    ///
    /// - Parameters:
    ///   - thicknessInVoxels: Total slab thickness measured in voxels.
    ///   - axis: Primary axis perpendicular to the slab (0=X, 1=Y, 2=Z). Used to normalize thickness.
    ///   - steps: Number of samples to take through the slab. Higher values improve quality.
    ///
    /// - Note: To disable slab projection, call with `thicknessInVoxels: 0` and `setBlend(.single)`.
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

    /// Positions the plane to display an axial slice at the specified depth index.
    ///
    /// Axial slices are perpendicular to the Z-axis (superior-inferior in radiological convention).
    /// The plane origin is computed as `(0, 0, (index+0.5)/depth)` in normalized [0,1] texture coordinates.
    ///
    /// - Parameter index: Zero-based slice index. Clamped to `[0, dimension.z-1]`.
    ///
    /// - Note: Automatically disables vertical flip.
    public func setAxial(slice index: Int) {
        let clamped = max(0, min(Int(dimension.z) - 1, index))
        let z = (Float(clamped) + 0.5) / max(1, Float(dimension.z))
        uniforms.planeOrigin = SIMD3<Float>(0, 0, z)
        uniforms.planeX = SIMD3<Float>(1, 0, 0)
        uniforms.planeY = SIMD3<Float>(0, 1, 0)
        setVerticalFlip(false)
        syncUniforms()
    }

    /// Positions the plane to display a sagittal slice at the specified column index.
    ///
    /// Sagittal slices are perpendicular to the X-axis (left-right in radiological convention).
    /// The plane origin is computed as `((index+0.5)/width, 0, 0)` in normalized texture coordinates.
    ///
    /// - Parameter index: Zero-based column index. Clamped to `[0, dimension.x-1]`.
    ///
    /// - Note: Automatically disables vertical flip.
    public func setSagittal(column index: Int) {
        let clamped = max(0, min(Int(dimension.x) - 1, index))
        let x = (Float(clamped) + 0.5) / max(1, Float(dimension.x))
        uniforms.planeOrigin = SIMD3<Float>(x, 0, 0)
        uniforms.planeX = SIMD3<Float>(0, 1, 0)
        uniforms.planeY = SIMD3<Float>(0, 0, 1)
        setVerticalFlip(false)
        syncUniforms()
    }

    /// Positions the plane to display a coronal slice at the specified row index.
    ///
    /// Coronal slices are perpendicular to the Y-axis (anterior-posterior in radiological convention).
    /// The plane origin is computed as `(0, (index+0.5)/height, 0)` in normalized texture coordinates.
    ///
    /// - Parameter index: Zero-based row index. Clamped to `[0, dimension.y-1]`.
    ///
    /// - Note: Automatically disables vertical flip.
    public func setCoronal(row index: Int) {
        let clamped = max(0, min(Int(dimension.y) - 1, index))
        let y = (Float(clamped) + 0.5) / max(1, Float(dimension.y))
        uniforms.planeOrigin = SIMD3<Float>(0, y, 0)
        uniforms.planeX = SIMD3<Float>(1, 0, 0)
        uniforms.planeY = SIMD3<Float>(0, 0, 1)
        setVerticalFlip(false)
        syncUniforms()
    }

    /// Positions the plane to display an arbitrary oblique slice.
    ///
    /// Allows custom plane orientations not aligned with the anatomical axes. Useful for
    /// curved MPR, vessel tracking, or user-defined reformatting planes.
    ///
    /// - Parameters:
    ///   - origin: Plane origin in normalized [0,1] texture coordinates.
    ///   - axisU: Horizontal axis vector (typically normalized).
    ///   - axisV: Vertical axis vector (typically normalized).
    ///
    /// - Note: Axes should ideally be orthonormal. Non-orthogonal axes will produce skewed slices.
    public func setOblique(origin: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>) {
        uniforms.planeOrigin = origin
        uniforms.planeX = axisU
        uniforms.planeY = axisV
        syncUniforms()
    }

    /// Enables or disables vertical flipping of the displayed slice.
    ///
    /// Flips the Y-axis to match DICOM orientation conventions or correct inverted datasets.
    ///
    /// - Parameter enabled: `true` to flip vertically, `false` for standard orientation.
    public func setVerticalFlip(_ enabled: Bool) {
        uniforms.flipVertical = enabled ? 1 : 0
    }

    /// Captures the current uniform buffer state for debugging or serialization.
    ///
    /// - Returns: Copy of ``Uniforms`` struct matching GPU-side buffer contents.
    public func snapshotUniforms() -> Uniforms {
        uniforms
    }

    private func syncUniforms() {
        guard let buffer = uniformBuffer else { return }
        var current = uniforms
        memcpy(buffer.contents(), &current, Uniforms.stride)
    }
}

private extension MPRPlaneMaterial {
    func assignProgramLibrary(_ program: SCNProgram) {
        guard let metalDevice = device as? MTLDevice else {
            logger.fault("Unable to resolve MTLDevice for MPRPlaneMaterial shader binding")
            return
        }

        let library = ShaderLibraryLoader.makeDefaultLibrary(on: metalDevice) { [logger] message in
            logger.debug("\(message)")
        }

        if let library {
            program.library = library
        } else {
            logger.error("Failed to load VolumeRendering.metallib; MPR shaders will be unavailable")
        }
    }

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
        descriptor.usage = [.shaderRead, .pixelFormatView]
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
        descriptor.usage = [.shaderRead, .pixelFormatView]
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
