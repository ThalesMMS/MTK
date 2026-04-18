//
//  VolumeCubeMaterial.swift
//  MTK
//
//  Material SceneKit que encapsula o shader de volume Metal. Gera o cubo volumétrico
//  utilizado pelos modos de renderização direta e projeções, expondo controles de
//  iluminação, gating e transferência de função.
//
//  Thales Matheus Mendonça Santos — October 2025
//

import Metal
import SceneKit
import simd
import MTKCore

/// SceneKit material that wraps Metal volume rendering shaders for volumetric visualization.
///
/// `VolumeCubeMaterial` generates a volumetric cube geometry used by direct volume rendering (DVR)
/// and projection modes (MIP/MinIP/AIP). It exposes controls for lighting, Hounsfield Unit (HU) windowing,
/// transfer functions, and quality settings. The material binds a 3D texture and uniform buffer to
/// fragment shaders (`volume_vertex`, `volume_fragment`) that perform GPU-accelerated ray marching.
///
/// ## Overview
///
/// This material coordinates:
/// - **Volume data**: 3D textures generated from `VolumeDataset` via `VolumeTextureFactory`
/// - **Transfer functions**: 1D lookup textures mapping intensity to RGBA for tissue classification
/// - **Uniforms**: GPU buffer containing rendering parameters (method, quality, HU windows, dimensions)
/// - **Shader programs**: SceneKit SCNProgram wrapping Metal vertex/fragment functions
///
/// ## Usage
///
/// Attach this material to a cube geometry to render medical volumes:
///
/// ```swift
/// let material = VolumeCubeMaterial(device: metalDevice)
/// material.setDataset(device: metalDevice, dataset: dicomVolume)
/// material.setPreset(device: metalDevice, preset: .softTissue)
/// material.setMethod(.dvr)
/// material.setHuWindow(minHU: -500, maxHU: 1200)
///
/// let cubeGeometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
/// cubeGeometry.firstMaterial = material
/// ```
///
/// ## Rendering Methods
///
/// The material supports multiple ray marching strategies via ``Method``:
/// - `.dvr`: Direct Volume Rendering with transfer function compositing
/// - `.mip`: Maximum Intensity Projection
/// - `.minip`: Minimum Intensity Projection
/// - `.avg`: Average Intensity Projection
/// - `.surf`: Surface rendering (isosurface extraction)
///
/// ## Thread Safety
///
/// Methods marked `@MainActor` (texture operations) must run on the main thread.
/// Uniform updates (`setHuWindow`, `setLighting`) are thread-safe when called sequentially.
///
public final class VolumeCubeMaterial: SCNMaterial, SCNProgramDelegate {
    /// Alias for transfer function presets provided by `VolumeRenderingBuiltinPreset`.
    public typealias Preset = VolumeRenderingBuiltinPreset

    /// Volume rendering method controlling the ray marching algorithm used by fragment shaders.
    ///
    /// Each method corresponds to a specialized Metal kernel in `volume_compute.metal`:
    /// - `.surf`: Isosurface extraction using gradient-based detection
    /// - `.dvr`: Direct volume rendering with transfer function compositing and opacity accumulation
    /// - `.mip`: Maximum intensity projection (useful for angiography, bone visualization)
    /// - `.minip`: Minimum intensity projection (useful for air/lung imaging)
    /// - `.avg`: Average intensity projection (slab averaging)
    ///
    /// The selected method is passed to the GPU via the ``Uniforms/method`` field.
    public enum Method: String, CaseIterable, Identifiable {
        case surf
        case dvr
        case mip
        case minip
        case avg

        public var id: RawValue { rawValue }

        public var idInt32: Int32 {
            switch self {
            case .surf:  return 0
            case .dvr:   return 1
            case .mip:   return 2
            case .minip: return 3
            case .avg:   return 4
            }
        }
    }

    /// Preset volumetric datasets for testing and fallback scenarios.
    ///
    /// Used by ``setPart(device:part:)`` to load synthetic or embedded volumes when
    /// DICOM data is unavailable. The `.dicom` case represents user-loaded clinical data.
    public enum BodyPart: String, CaseIterable, Identifiable {
        case none
        case chest
        case head
        case dicom

        public var id: RawValue { rawValue }

        public var displayName: String {
            switch self {
            case .none:
                return "none"
            case .dicom:
                return "DICOM"
            default:
                return rawValue
            }
        }
    }

    /// Buffer consumido pelo shader `volume_fragment` (ver `mtk.metal`).
    /// Mantém flags de iluminação, parâmetros de ray marching, janelas HU e
    /// metadados geométricos que precisam casar bit a bit com a struct Metal de
    /// mesmo nome. Cada campo aqui tem a correspondência direta descrita abaixo.
    public struct Uniforms: sizeable {
        /// Flag usada pelos kernels de volume para decidir se aplicam iluminação
        /// difusa/especular durante a composição.
        public var isLightingOn: Int32 = 1

        /// Inverte a marcha do raio em `direct_volume_rendering` quando `1`,
        /// fazendo o shader consumir o volume de trás para frente.
        public var isBackwardOn: Int32 = 0

        /// Método de renderização consumido pela função `volume_fragment` para
        /// decidir qual kernel especializado chamar.
        public var method: Int32 = Method.dvr.idInt32

        /// Número de passos de ray marching (`quality`) para amostragem do
        /// volume, passado diretamente para os utilitários `VR::initRayMarch`.
        public var renderingQuality: Int32 = 512

        /// Limites de intensidade HU utilizados pelos kernels para normalizar o
        /// voxel corrente antes de consultar a transfer function.
        public var voxelMinValue: Int32 = -1024
        public var voxelMaxValue: Int32 = 3071

        /// Faixa integral completa do dataset, usada pelos kernels para
        /// normalizar valores absolutos independentemente da janela atual.
        public var datasetMinValue: Int32 = -1024
        public var datasetMaxValue: Int32 = 3071

        /// Faixa de densidade normalizada mantida para gating de projeções
        /// espessas.
        public var densityFloor: Float = 0.02
        public var densityCeil: Float = 1.0

        /// Janelas HU e flag de gating avaliadas em `projection_rendering` e
        /// `direct_volume_rendering` para descartar voxels fora do intervalo.
        public var gateHuMin: Int32 = -900
        public var gateHuMax: Int32 = -500
        public var useHuGate: Int32 = 0

        /// Dimensões do volume em voxels, utilizadas pelo shader para calcular
        /// gradientes corretos considerando o espaçamento real das amostras.
        public var dimX: Int32 = 1
        public var dimY: Int32 = 1
        public var dimZ: Int32 = 1

        /// Flag preservada para projeções espessas utilizarem a mesma transfer
        /// function do DVR quando necessária.
        public var useTFProj: Int32 = 0

        /// Espaços reservados para manter alinhamento com a struct Metal.
        public var _pad0: Int32 = 0
        public var _pad1: Int32 = 0
        public var _pad2: Int32 = 0

        public init() {}
    }

    private let device: any MTLDevice
    private var uniforms = Uniforms()
    private let uniformsKey = "uniforms"
    private let dicomKey = "dicom"
    private let tfKey = "transferColor"
    private var uniformsBuffer: (any MTLBuffer)?
    private var dicomTexture: (any MTLTexture)?
    private var transferFunctionTexture: (any MTLTexture)?

    private(set) var textureGenerator: VolumeTextureFactory = VolumeTextureFactory(
        dataset: VolumeTextureFactory.debugPlaceholderDataset()
    )
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeCubeMaterial")

    public var tf: TransferFunction?
    public private(set) var transferFunctionDomain: ClosedRange<Float>?

    private var datasetHuRange: ClosedRange<Int32> = (-1024)...3071
    private var huWindow: ClosedRange<Int32>?

    /// Physical scale of the volume cube in SceneKit world coordinates.
    ///
    /// Derived from dataset spacing and dimensions via `VolumeTextureFactory`.
    /// Useful for positioning overlays and calculating correct aspect ratios.
    public var scale: SIMD3<Float> { textureGenerator.scale }

    /// Current ray marching sampling step count.
    ///
    /// Higher values increase quality at the cost of performance. Typical range: 256-1024.
    public var samplingStep: Float { Float(uniforms.renderingQuality) }

    /// Full intensity range of the active dataset in Hounsfield Units.
    ///
    /// Represents the actual data bounds, not the current windowing. Use ``setHuWindow(minHU:maxHU:)``
    /// to adjust the visible intensity range.
    public var datasetIntensityRange: ClosedRange<Int32> { datasetHuRange }

    /// Initializes a volume material bound to the specified Metal device.
    ///
    /// Sets up SceneKit shader programs (`volume_vertex`, `volume_fragment`), allocates uniform buffers,
    /// and loads a placeholder 1×1×1 volume until ``setDataset(device:dataset:volumeTexture:)`` is called.
    ///
    /// - Parameter device: Metal device for texture and buffer allocation. Must support Metal shading language.
    ///
    /// - Note: The initializer automatically calls ``setPart(device:part:)`` with `.none` to generate
    ///         a synthetic fallback texture, ensuring the material is always renderable.
    public init(device: any MTLDevice) {
        self.device = device
        super.init()

        let program = SCNProgram()
        program.vertexFunctionName = "volume_vertex"
        program.fragmentFunctionName = "volume_fragment"
        program.delegate = self
        assignProgramLibrary(program)
        self.program = program

        // Ao depurar problemas de binding (ex.: textura preta), confira se o
        // `uniformsKey` está chegando ao índice 4 no `MTLRenderCommandEncoder`.
        // Uma captura do Metal Frame ou `GPU Validation` ajudam a identificar
        // desalinhamentos entre esta struct e a contrapartida Metal.
        program.handleBinding(ofBufferNamed: uniformsKey, frequency: .perFrame) { [weak self] _, _, _, renderer in
            guard let self,
                  let encoder = renderer.currentRenderCommandEncoder,
                  let buffer = self.uniformsBuffer else { return }
            encoder.setFragmentBuffer(buffer, offset: 0, index: 4)
        }

        cullMode = .front
        writesToDepthBuffer = true

        // Estratégia de fallback: inicializa com `BodyPart.none`, que gera uma
        // textura 1x1x1 sintética via `VolumeTextureFactory.debugPlaceholderDataset()`
        // e define um domínio HU padrão (-1024...3071) até que um dataset real
        // seja carregado.
        setPart(device: device, part: .none)
        makeUniformBufferIfNeeded()
        pushUniforms()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Returns the currently bound 3D volume texture.
    ///
    /// - Returns: Metal texture in `.r16Sint` format containing voxel intensities, or `nil` if no dataset loaded.
    public func currentVolumeTexture() -> (any MTLTexture)? {
        dicomTexture
    }

    /// Returns the currently bound 1D transfer function texture.
    ///
    /// - Returns: Metal texture mapping normalized intensity [0,1] to RGBA, or `nil` if no preset applied.
    public func currentTransferFunctionTexture() -> (any MTLTexture)? {
        transferFunctionTexture
    }

    /// Volume dimensions (in voxels) and voxel spacing (in meters).
    ///
    /// Useful for MPR plane calculations and coordinate transformations.
    public var datasetMeta: (dimension: SIMD3<Int32>, resolution: SIMD3<Float>) {
        (textureGenerator.dimension, textureGenerator.resolution)
    }

    /// The active `VolumeDataset` containing raw voxel data, spacing, and intensity metadata.
    public var currentDataset: VolumeDataset {
        textureGenerator.dataset
    }

    /// Captures the current uniform buffer state for debugging or serialization.
    ///
    /// - Returns: Copy of ``Uniforms`` struct matching GPU-side buffer contents.
    public func snapshotUniforms() -> Uniforms {
        uniforms
    }

    /// Sets the volume rendering method (DVR, MIP, MinIP, etc.).
    ///
    /// Updates the ``Uniforms/method`` field and pushes uniforms to the GPU. The fragment shader
    /// reads this value to dispatch the appropriate ray marching kernel.
    ///
    /// - Parameter method: Desired rendering algorithm from ``Method`` enum.
    public func setMethod(_ method: Method) {
        uniforms.method = method.idInt32

        cullMode = .front
        pushUniforms()
    }

    /// Troca o preset volumétrico embarcado (cabeça, tórax, placeholder). Útil
    /// como fallback quando não há DICOM disponível ou durante debugging.
    public func setPart(device: any MTLDevice, part: BodyPart) {
        do {
            apply(factory: try VolumeTextureFactory(part: part), device: device)
        } catch {
            logger.error("Failed to load volume preset \(part.rawValue): \(String(describing: error)); binding debug placeholder")
            apply(
                factory: VolumeTextureFactory(dataset: VolumeTextureFactory.debugPlaceholderDataset()),
                device: device
            )
        }
    }

    /// Substitui o volume ativo por um dataset clínico. Além de subir a textura
    /// 3D (ou reutilizar `volumeTexture` quando fornecida), esta chamada
    /// recalcula dimensões, intervalo de intensidades e o domínio da transfer
    /// function para manter o shader coerente. Dispara `pushUniforms()` para
    /// reenfileirar o buffer, portanto invalida bindings anteriores.
    @MainActor
    public func setDataset(device: any MTLDevice,
                           dataset: VolumeDataset,
                           volumeTexture: (any MTLTexture)? = nil) {
        apply(factory: VolumeTextureFactory(dataset: dataset),
              device: device,
              overrideTexture: volumeTexture)
    }

    /// Carrega um preset de transfer function da biblioteca embutida. Além de
    /// atualizar `tf`, gera uma nova textura 1D Metal, reatribui a propriedade
    /// `transferColor` do material e recalcula o domínio efetivo usado pelas
    /// janelas HU. Falhas na geração são reportadas via `logger`.
    @MainActor
    public func setPreset(device: any MTLDevice, preset: Preset) {
        guard let transfer = VolumeTransferFunctionLibrary.transferFunction(for: preset) else {
            logger.warning("Preset \(preset.rawValue) not available in library")
            return
        }
        tf = transfer
        guard let texture = transfer.makeTexture(device: device, logger: logger) else {
            logger.error("Failed to build transfer function texture for preset \(preset.rawValue)")
            return
        }
        setTransferFunctionTexture(texture)
        updateTransferFunctionDomain()
    }

    @MainActor
    public func setTransferFunctionTexture(_ texture: any MTLTexture) {
        transferFunctionTexture = texture
        setValue(SCNMaterialProperty(contents: texture as Any), forKey: tfKey)
        updateTransferFunctionDomain()
    }

    /// Enables or disables Phong lighting calculations during volume rendering.
    ///
    /// When enabled, the fragment shader computes diffuse and specular lighting based on
    /// gradient-derived surface normals. Useful for enhancing depth perception in DVR mode.
    ///
    /// - Parameter on: `true` to enable lighting, `false` for unlit compositing.
    public func setLighting(on: Bool) {
        uniforms.isLightingOn = on ? 1 : 0
        pushUniforms()
    }

    /// Sets the ray marching step count (rendering quality).
    ///
    /// Higher step counts produce smoother gradients and more accurate opacity accumulation
    /// at the cost of performance. Typical values: 256 (fast), 512 (balanced), 1024 (high quality).
    ///
    /// - Parameter step: Number of samples along each ray. Must be positive.
    public func setStep(_ step: Float) {
        uniforms.renderingQuality = Int32(step)
        pushUniforms()
    }

    /// Shifts the transfer function along the intensity axis without rebuilding the preset.
    ///
    /// Regenerates the 1D transfer function texture with the specified offset, allowing
    /// real-time windowing adjustments without modifying the underlying curve.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture allocation.
    ///   - shift: Intensity offset applied to the transfer function domain.
    @MainActor
    public func setShift(device: any MTLDevice, shift: Float) {
        tf?.shift = shift
        guard let tf, let texture = tf.makeTexture(device: device) else { return }
        setTransferFunctionTexture(texture)
        updateTransferFunctionDomain()
    }

    /// Sets normalized density gating thresholds for projection rendering modes.
    ///
    /// Used by thick slab projections (MIP/MinIP/AIP) to clamp accumulated density values.
    /// Values are clamped to [0,1] range, with `ceil` forced to be ≥ `floor`.
    ///
    /// - Parameters:
    ///   - floor: Minimum normalized density (default: 0.02).
    ///   - ceil: Maximum normalized density (default: 1.0).
    public func setDensityGate(floor: Float, ceil: Float) {
        uniforms.densityFloor = max(0, min(1, floor))
        uniforms.densityCeil = max(uniforms.densityFloor, min(1, ceil))
        pushUniforms()
    }

    /// Controls whether projection modes (MIP/MinIP/AIP) apply the transfer function.
    ///
    /// When enabled, projected intensities are mapped through the active transfer function
    /// before display. When disabled, raw intensity values are used.
    ///
    /// - Parameter on: `true` to enable transfer function lookups in projections.
    public func setUseTFOnProjections(_ on: Bool) {
        uniforms.useTFProj = on ? 1 : 0
        pushUniforms()
    }

    /// Enables or disables Hounsfield Unit gating during ray marching.
    ///
    /// When enabled, voxels outside ``Uniforms/gateHuMin`` and ``Uniforms/gateHuMax``
    /// are discarded before transfer function evaluation. Useful for isolating specific
    /// tissue types (e.g., bone, air).
    ///
    /// - Parameter enabled: `true` to activate HU-based gating.
    public func setHuGate(enabled: Bool) {
        uniforms.useHuGate = enabled ? 1 : 0
        pushUniforms()
    }

    /// Applies a pre-computed HU-to-transfer-function mapping.
    ///
    /// Synchronizes gating fields (``Uniforms/gateHuMin``, ``Uniforms/gateHuMax``) and
    /// visible intensity range (``Uniforms/voxelMinValue``, ``Uniforms/voxelMaxValue``)
    /// with the provided mapping. Forces a uniform buffer update.
    ///
    /// - Parameter window: ``HuWindowMapping`` containing absolute HU bounds and normalized TF coordinates.
    public func setHuWindow(_ window: HuWindowMapping) {
        huWindow = window.minHU...window.maxHU
        uniforms.gateHuMin = window.minHU
        uniforms.gateHuMax = window.maxHU
        uniforms.voxelMinValue = window.minHU
        uniforms.voxelMaxValue = window.maxHU
        pushUniforms()
    }

    /// Sets the visible HU window using absolute intensity values.
    ///
    /// Computes a ``HuWindowMapping`` that respects the dataset's intensity range and
    /// the active transfer function domain. Provides a convenient API when working with
    /// raw Hounsfield Units (e.g., from DICOM Window Center/Width tags).
    ///
    /// - Parameters:
    ///   - minHU: Minimum visible intensity (typically -1024 for air).
    ///   - maxHU: Maximum visible intensity (e.g., 3071 for dense bone/metal).
    public func setHuWindow(minHU: Int32, maxHU: Int32) {
        let mapping = VolumeCubeMaterial.makeHuWindowMapping(
            minHU: minHU,
            maxHU: maxHU,
            datasetRange: datasetHuRange,
            transferDomain: transferFunctionDomain
        )
        setHuWindow(mapping)
    }

    /// Mapping between absolute Hounsfield Units and normalized transfer function coordinates.
    ///
    /// Used to synchronize HU windowing parameters with transfer function sampling.
    /// The `tfMin`/`tfMax` fields represent normalized [0,1] coordinates into the 1D transfer function texture,
    /// while `minHU`/`maxHU` represent the corresponding absolute intensity values in Hounsfield Units.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let mapping = HuWindowMapping(minHU: -500, maxHU: 1200, tfMin: 0.25, tfMax: 0.75)
    /// material.setHuWindow(mapping)
    /// ```
    public struct HuWindowMapping: Equatable {
        /// Minimum Hounsfield Unit value for the visible window.
        public var minHU: Int32

        /// Maximum Hounsfield Unit value for the visible window.
        public var maxHU: Int32

        /// Normalized transfer function coordinate [0,1] corresponding to `minHU`.
        public var tfMin: Float

        /// Normalized transfer function coordinate [0,1] corresponding to `maxHU`.
        public var tfMax: Float

        /// Creates a new HU-to-TF mapping.
        ///
        /// - Parameters:
        ///   - minHU: Lower intensity bound in Hounsfield Units.
        ///   - maxHU: Upper intensity bound in Hounsfield Units.
        ///   - tfMin: Normalized TF coordinate for `minHU`.
        ///   - tfMax: Normalized TF coordinate for `maxHU`.
        public init(minHU: Int32, maxHU: Int32, tfMin: Float, tfMax: Float) {
            self.minHU = minHU
            self.maxHU = maxHU
            self.tfMin = tfMin
            self.tfMax = tfMax
        }
    }

    /// Creates a ``HuWindowMapping`` from absolute HU values, clamping to dataset and transfer function domains.
    ///
    /// Normalizes the requested HU window against the dataset's intensity range, then maps it into
    /// the transfer function's coordinate space. Ensures numerical stability when the dataset range
    /// is degenerate or the window is out-of-bounds.
    ///
    /// - Parameters:
    ///   - minHU: Requested minimum intensity.
    ///   - maxHU: Requested maximum intensity.
    ///   - datasetRange: Actual intensity range of the loaded volume.
    ///   - transferDomain: Intensity domain covered by the active transfer function, or `nil` to use `datasetRange`.
    ///
    /// - Returns: A clamped and normalized ``HuWindowMapping`` suitable for ``setHuWindow(_:)``.
    public static func makeHuWindowMapping(minHU: Int32,
                                           maxHU: Int32,
                                           datasetRange: ClosedRange<Int32>,
                                           transferDomain: ClosedRange<Float>?) -> HuWindowMapping {
        let resolvedWindow = normalizedWindow(
            minHU: minHU,
            maxHU: maxHU,
            datasetRange: datasetRange
        )

        let domain = transferDomain ?? ClosedRange(
            uncheckedBounds: (
                lower: Float(datasetRange.lowerBound),
                upper: Float(datasetRange.upperBound)
            )
        )

        let lowerBound = domain.lowerBound
        let upperBound = domain.upperBound
        let span = upperBound - lowerBound

        let normalized: (Float) -> Float = { value in
            guard span.magnitude > .ulpOfOne else { return 0 }
            let clamped = max(lowerBound, min(value, upperBound))
            return (clamped - lowerBound) / span
        }

        let lower = normalized(Float(resolvedWindow.lowerBound))
        let upper = normalized(Float(resolvedWindow.upperBound))

        let tfMin = min(lower, upper)
        let tfMax = max(lower, upper)

        return HuWindowMapping(
            minHU: resolvedWindow.lowerBound,
            maxHU: resolvedWindow.upperBound,
            tfMin: tfMin,
            tfMax: tfMax
        )
    }

    /// Clamps and normalizes an HU window to ensure it falls within the dataset's intensity range.
    ///
    /// Handles edge cases where the requested window is inverted, out-of-bounds, or degenerate.
    /// Guarantees a non-empty range is returned even when input parameters are invalid.
    ///
    /// - Parameters:
    ///   - minHU: Requested lower bound.
    ///   - maxHU: Requested upper bound.
    ///   - datasetRange: Valid intensity range of the volume.
    ///
    /// - Returns: A clamped range where `lowerBound < upperBound`, or a minimally expanded range if input is degenerate.
    static func normalizedWindow(minHU: Int32, maxHU: Int32, datasetRange: ClosedRange<Int32>) -> ClosedRange<Int32> {
        let clampedMin = max(datasetRange.lowerBound, min(minHU, datasetRange.upperBound))
        let candidateMax = max(datasetRange.lowerBound, min(maxHU, datasetRange.upperBound))
        let clampedMax = max(clampedMin, candidateMax)

        if clampedMax > clampedMin {
            return clampedMin...clampedMax
        }

        if datasetRange.lowerBound < datasetRange.upperBound {
            return datasetRange.lowerBound...datasetRange.upperBound
        }

        let anchor = datasetRange.lowerBound
        let expandedMin = anchor == Int32.min ? anchor : anchor - 1
        let expandedMax = anchor == Int32.max ? anchor : anchor + 1

        if expandedMax > expandedMin {
            return expandedMin...expandedMax
        }

        let fallbackMax = anchor == Int32.max ? anchor : anchor + 1
        return min(anchor, fallbackMax)...max(anchor, fallbackMax)
    }

    private func pushUniforms() {
        makeUniformBufferIfNeeded()

        guard let buffer = uniformsBuffer else {
            logger.error("Missing uniforms buffer when attempting to push uniforms")
            return
        }

        var copy = uniforms
        withUnsafePointer(to: &copy) { pointer in
            buffer.contents().copyMemory(from: pointer, byteCount: Uniforms.stride)
        }
#if os(macOS)
        // Only notify managed buffers; shared storage does not require (and cannot use) didModifyRange.
        if buffer.storageMode == .managed {
            buffer.didModifyRange(0..<Uniforms.stride)
        }
#endif
    }

    private func setDicomTexture(_ texture: any MTLTexture) {
        dicomTexture = texture
        setValue(SCNMaterialProperty(contents: texture as Any), forKey: dicomKey)
    }
}

private extension VolumeCubeMaterial {
    func assignProgramLibrary(_ program: SCNProgram) {
        guard let metalDevice = device as? MTLDevice else {
            logger.fault("Unable to resolve MTLDevice for VolumeCubeMaterial shader binding")
            return
        }

        do {
            program.library = try ShaderLibraryLoader.loadLibrary(for: metalDevice)
        } catch {
            // Volume rendering cannot proceed without assigning program.library from the required MTK.metallib.
            logger.fault("Failed to load MTK.metallib via ShaderLibraryLoader.loadLibrary(for:) for VolumeCubeMaterial program.library: \(error.localizedDescription)")
            fatalError("Failed to load MTK.metallib for VolumeCubeMaterial SceneKit shaders: \(error.localizedDescription)")
        }
    }

    func apply(factory: VolumeTextureFactory,
               device: any MTLDevice,
               overrideTexture: (any MTLTexture)? = nil) {
        textureGenerator = factory
        guard let texture = overrideTexture ?? factory.generate(device: device) else {
            logger.error("Failed to generate 3D texture for dataset")
            return
        }

        setDicomTexture(texture)

        let dimension = factory.dimension
        uniforms.dimX = dimension.x
        uniforms.dimY = dimension.y
        uniforms.dimZ = dimension.z

        let range = factory.dataset.intensityRange
        datasetHuRange = range
        uniforms.datasetMinValue = range.lowerBound
        uniforms.datasetMaxValue = range.upperBound
        transferFunctionDomain = ClosedRange(
            uncheckedBounds: (
                lower: Float(range.lowerBound),
                upper: Float(range.upperBound)
            )
        )
        let effectiveWindow = huWindow ?? range
        let resolvedWindow = VolumeCubeMaterial.normalizedWindow(
            minHU: effectiveWindow.lowerBound,
            maxHU: effectiveWindow.upperBound,
            datasetRange: range
        )
        let mapping = VolumeCubeMaterial.makeHuWindowMapping(
            minHU: resolvedWindow.lowerBound,
            maxHU: resolvedWindow.upperBound,
            datasetRange: range,
            transferDomain: transferFunctionDomain
        )
        uniforms.voxelMinValue = mapping.minHU
        uniforms.voxelMaxValue = mapping.maxHU
        uniforms.gateHuMin = mapping.minHU
        uniforms.gateHuMax = mapping.maxHU

        pushUniforms()
    }

    func makeUniformBufferIfNeeded() {
        guard uniformsBuffer == nil else { return }
        uniformsBuffer = device.makeBuffer(length: Uniforms.stride, options: .storageModeShared)
        uniformsBuffer?.label = "VolumeCubeMaterial.uniforms"
    }
}

private extension VolumeCubeMaterial {
    /// Mantém o domínio da transfer function alinhado com o preset atual ou,
    /// em fallback, com o intervalo bruto do dataset. Útil para evitar janelas
    /// vazias quando a TF ainda não foi carregada.
    func updateTransferFunctionDomain() {
        if let tf {
            let shift = tf.shift
            let minValue = tf.minimumValue + shift
            let maxValue = tf.maximumValue + shift
            if maxValue >= minValue {
                transferFunctionDomain = minValue...maxValue
            } else {
                transferFunctionDomain = maxValue...minValue
            }
        }

        if transferFunctionDomain == nil {
            // Fallback de domínio quando não há TF válida: usa o range de HU do
            // volume atual, garantindo que `setHuWindow` normalize corretamente.
            transferFunctionDomain = ClosedRange(
                uncheckedBounds: (
                    lower: Float(datasetHuRange.lowerBound),
                    upper: Float(datasetHuRange.upperBound)
                )
            )
        }
    }
}

extension VolumeCubeMaterial {
    public func program(_ program: SCNProgram, handleError error: any Error) {
        logger.error("SceneKit program error: \(error.localizedDescription)")
    }
}


#if DEBUG
@_spi(Testing) extension VolumeCubeMaterial {
    public func debugVolumeTexture() -> (any MTLTexture)? {
        dicomTexture
    }
}
#endif
