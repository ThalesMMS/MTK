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

public final class VolumeCubeMaterial: SCNMaterial, SCNProgramDelegate {
    public typealias Preset = VolumeRenderingBuiltinPreset

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
        /// legacy (slabs espessos).
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

    private(set) var textureGenerator: VolumeTextureFactory = VolumeTextureFactory(part: .none)
    private let logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "VolumeCubeMaterial")

    public var tf: TransferFunction?
    public private(set) var transferFunctionDomain: ClosedRange<Float>?

    private var datasetHuRange: ClosedRange<Int32> = (-1024)...3071
    private var huWindow: ClosedRange<Int32>?

    public var scale: SIMD3<Float> { textureGenerator.scale }
    public var samplingStep: Float { Float(uniforms.renderingQuality) }
    public var datasetIntensityRange: ClosedRange<Int32> { datasetHuRange }

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
        // textura 1x1x1 sintética via `VolumeTextureFactory.placeholderDataset()`
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

    public func currentVolumeTexture() -> (any MTLTexture)? {
        dicomTexture
    }

    public func currentTransferFunctionTexture() -> (any MTLTexture)? {
        transferFunctionTexture
    }

    public var datasetMeta: (dimension: SIMD3<Int32>, resolution: SIMD3<Float>) {
        (textureGenerator.dimension, textureGenerator.resolution)
    }

    public var currentDataset: VolumeDataset {
        textureGenerator.dataset
    }

    public func snapshotUniforms() -> Uniforms {
        uniforms
    }

    public func setMethod(_ method: Method) {
        uniforms.method = method.idInt32

        cullMode = .front
        pushUniforms()
    }

    /// Troca o preset volumétrico embarcado (cabeça, tórax, placeholder). Útil
    /// como fallback quando não há DICOM disponível ou durante debugging.
    public func setPart(device: any MTLDevice, part: BodyPart) {
        apply(factory: VolumeTextureFactory(part: part), device: device)
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

    public func setLighting(on: Bool) {
        uniforms.isLightingOn = on ? 1 : 0
        pushUniforms()
    }

    public func setStep(_ step: Float) {
        uniforms.renderingQuality = Int32(step)
        pushUniforms()
    }

    @MainActor
    public func setShift(device: any MTLDevice, shift: Float) {
        tf?.shift = shift
        guard let tf, let texture = tf.makeTexture(device: device) else { return }
        setTransferFunctionTexture(texture)
        updateTransferFunctionDomain()
    }

    public func setDensityGate(floor: Float, ceil: Float) {
        uniforms.densityFloor = max(0, min(1, floor))
        uniforms.densityCeil = max(uniforms.densityFloor, min(1, ceil))
        pushUniforms()
    }

    public func setUseTFOnProjections(_ on: Bool) {
        uniforms.useTFProj = on ? 1 : 0
        pushUniforms()
    }

    public func setHuGate(enabled: Bool) {
        uniforms.useHuGate = enabled ? 1 : 0
        pushUniforms()
    }

    /// Aplica um mapeamento HU->TF pré-calculado, sincronizando os campos de
    /// gating e a faixa `voxelMin/Max` consumida pelo shader. A chamada também
    /// força uma atualização do buffer, o que impacta qualquer captura Metal
    /// aberta.
    public func setHuWindow(_ window: HuWindowMapping) {
        huWindow = window.minHU...window.maxHU
        uniforms.gateHuMin = window.minHU
        uniforms.gateHuMax = window.maxHU
        uniforms.voxelMinValue = window.minHU
        uniforms.voxelMaxValue = window.maxHU
        pushUniforms()
    }

    /// Calcula um `HuWindowMapping` a partir de intensidades absolutas,
    /// respeitando o range do dataset atual e o domínio vigente da transfer
    /// function. Serve como API amigável quando a camada superior manipula HU
    /// puros.
    public func setHuWindow(minHU: Int32, maxHU: Int32) {
        let mapping = VolumeCubeMaterial.makeHuWindowMapping(
            minHU: minHU,
            maxHU: maxHU,
            datasetRange: datasetHuRange,
            transferDomain: transferFunctionDomain
        )
        setHuWindow(mapping)
    }

    public struct HuWindowMapping: Equatable {
        public var minHU: Int32
        public var maxHU: Int32
        public var tfMin: Float
        public var tfMax: Float

        public init(minHU: Int32, maxHU: Int32, tfMin: Float, tfMax: Float) {
            self.minHU = minHU
            self.maxHU = maxHU
            self.tfMin = tfMin
            self.tfMax = tfMax
        }
    }

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

        let library = ShaderLibraryLoader.makeDefaultLibrary(on: metalDevice) { [logger] message in
            logger.debug("\(message)")
        }

        if let library {
            program.library = library
        } else {
            logger.error("Failed to load VolumeRendering.metallib; SceneKit shaders will be unavailable")
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
