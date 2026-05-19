import Combine
import Foundation
@preconcurrency import Metal
import MTKCore
import simd

public struct ClinicalViewerSnapshotExport: Sendable, Equatable {
    public var filename: String
    public var data: Data
    public var metrics: SnapshotMetrics?

    public init(filename: String,
                data: Data,
                metrics: SnapshotMetrics?) {
        self.filename = filename
        self.data = data
        self.metrics = metrics
    }
}

public enum ClinicalViewerCoordinatorError: Error, Equatable, LocalizedError {
    case viewportUnavailable(String?)

    public var errorDescription: String? {
        switch self {
        case .viewportUnavailable(let message):
            if let message, !message.isEmpty {
                return message
            }
            return "Active viewport unavailable."
        }
    }
}

private enum ActiveClinicalViewerViewport {
    case single3D(VolumeViewport3D)
    case clinical(ClinicalViewportSession)
}

@MainActor
public final class ClinicalViewerCoordinator: ObservableObject {
    private let single3DFinalSamplingStep: Float
    private let snapshotExporter = TextureSnapshotExporter()

    @Published public private(set) var clinicalViewportSession: ClinicalViewportSession?
    @Published public private(set) var volumeViewport3D: VolumeViewport3D?
    @Published public private(set) var dataset: VolumeDataset?
    @Published public var mode: ClinicalViewerMode = .single3D
    @Published public var interactionMode: NativeVolume3DInteractionMode = .orbit
    @Published public var mprInteractionTool: ClinicalMPRInteractionTool = .crosshair
    @Published public var activeMPRAxis: MTKCore.Axis = .axial
    @Published public var mprSlicePositions: [MTKCore.Axis: Double] = [
        .axial: 0.5,
        .coronal: 0.5,
        .sagittal: 0.5
    ]
    @Published public var mprWindow: Double = 400
    @Published public var mprLevel: Double = 40
    @Published public var mprSlabThickness: Double = 3
    @Published public var mprViewportTransforms: [MTKCore.Axis: MPRViewportTransform] = [
        .axial: .identity,
        .coronal: .identity,
        .sagittal: .identity
    ]
    @Published public var volumeOpacityScale: Double = 1.0
    @Published public var errorMessage: String?
    @Published public var renderMethod: VolumetricRenderMethod = .dvr
    @Published public var transferPreset: ClinicalTransferFunctionPreset = .ctSoftTissue
    @Published public var showDebugOverlay = false
    @Published public var isExportingSnapshot = false
    @Published public var snapshotError: String?
    @Published public var cropEnabled = false
    @Published public var cropXMin: Double = 0
    @Published public var cropXMax: Double = 1
    @Published public var cropYMin: Double = 0
    @Published public var cropYMax: Double = 1
    @Published public var cropZMin: Double = 0
    @Published public var cropZMax: Double = 1
    @Published public var clipEnabled = false
    @Published public var clipAxis: MTKCore.Axis = .axial
    @Published public var clipPlaneOffset: Double = 0
    @Published public var clippingErrorMessage: String?
    @Published public private(set) var hudRenderTimeMilliseconds: Double?
    @Published public private(set) var hudPresentationTimeMilliseconds: Double?
    @Published public private(set) var hudUploadTimeMilliseconds: Double?
    @Published public private(set) var hudMemoryBytes: Int?
    @Published public private(set) var lastSnapshotMetrics: SnapshotMetrics?

    private var clinicalViewportSessionTask: Task<ClinicalViewportSession?, Never>?
    private var volumeViewport3DTask: Task<VolumeViewport3D?, Never>?
    private var snapshotMetricsClearTask: Task<Void, Never>?
    private var clinicalSessionCancellable: AnyCancellable?
    private var currentVolumeLayers: [VolumeLayer] = []
    private var currentSurfaceMeshLayers: [SurfaceMeshLayer] = []

    public init(single3DFinalSamplingStep: Float = 768) {
        self.single3DFinalSamplingStep = single3DFinalSamplingStep
    }

    public var isMetalAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public var canCaptureSnapshot: Bool {
        guard dataset != nil, !isExportingSnapshot else {
            return false
        }
        switch mode {
        case .single3D:
            return volumeViewport3D != nil
        case .clinical:
            return clinicalViewportSession != nil
        }
    }

    public var volumeLayers: [VolumeLayer] {
        currentVolumeLayers
    }

    public var surfaceMeshLayers: [SurfaceMeshLayer] {
        currentSurfaceMeshLayers
    }

    public func ensureActiveViewport() {
        switch mode {
        case .single3D:
            ensureVolumeViewport3D()
        case .clinical:
            ensureClinicalViewportSession()
        }
    }

    public func setMode(_ newMode: ClinicalViewerMode) {
        guard newMode != mode else { return }
        clearSnapshotMetrics()
        mode = newMode
        switch newMode {
        case .single3D:
            shutdownClinicalViewportSession()
            ensureVolumeViewport3D()
            Task { @MainActor [weak self] in
                guard let self, let viewport = await self.volumeViewportReady() else { return }
                if let dataset = self.dataset {
                    await viewport.applyDataset(dataset)
                }
                try? await self.applyCurrentConfiguration(to: viewport)
                await viewport.setVolumeLayers(self.currentVolumeLayers)
                await viewport.setSurfaceMeshLayers(self.currentSurfaceMeshLayers)
            }
        case .clinical:
            ensureClinicalViewportSession()
            Task { @MainActor [weak self] in
                guard let self, let session = await self.sessionReady() else { return }
                if let dataset = self.dataset {
                    try? await session.applyDataset(dataset)
                }
                try? await self.applyCurrentConfiguration(to: session)
                await session.setVolumeLayers(self.currentVolumeLayers)
                await session.setSurfaceMeshLayers(self.currentSurfaceMeshLayers)
            }
        }
    }

    public func ensureVolumeViewport3D() {
        guard isMetalAvailable else {
            errorMessage = "Metal is not available on this device."
            return
        }
        if let volumeViewport3D {
            Task { @MainActor [weak self, weak volumeViewport3D] in
                guard let self, let volumeViewport3D else { return }
                await self.configureSingle3DViewport(volumeViewport3D)
            }
            return
        }
        guard volumeViewport3DTask == nil else { return }

        volumeViewport3DTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                let viewport = try VolumeViewport3D(method: self.renderMethod)
                await self.configureSingle3DViewport(viewport)
                if let dataset = self.dataset {
                    await viewport.applyDataset(dataset)
                }
                try await self.applyCurrentConfiguration(to: viewport)
                await viewport.setVolumeLayers(self.currentVolumeLayers)
                await viewport.setSurfaceMeshLayers(self.currentSurfaceMeshLayers)
                self.volumeViewport3D = viewport
                self.errorMessage = nil
                self.volumeViewport3DTask = nil
                return viewport
            } catch {
                self.errorMessage = error.localizedDescription
                self.volumeViewport3DTask = nil
                return nil
            }
        }
    }

    public func ensureClinicalViewportSession() {
        guard isMetalAvailable else {
            errorMessage = "Metal is not available on this device."
            return
        }
        guard clinicalViewportSession == nil, clinicalViewportSessionTask == nil else { return }

        clinicalViewportSessionTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                let session = try await ClinicalViewportSession.make(dataset: self.dataset)
                try await self.applyCurrentConfiguration(to: session)
                await session.setVolumeLayers(self.currentVolumeLayers)
                await session.setSurfaceMeshLayers(self.currentSurfaceMeshLayers)
                self.clinicalViewportSession = session
                self.bindClinicalSession(session)
                self.syncMPRState(from: session)
                self.errorMessage = nil
                self.clinicalViewportSessionTask = nil
                return session
            } catch {
                self.errorMessage = error.localizedDescription
                self.clinicalViewportSessionTask = nil
                return nil
            }
        }
    }

    public func shutdownClinicalViewportSession() {
        clinicalViewportSessionTask?.cancel()
        clinicalViewportSessionTask = nil
        clearSnapshotMetrics()
        guard let session = clinicalViewportSession else { return }
        clinicalSessionCancellable = nil
        clinicalViewportSession = nil
        Task { @MainActor in
            await session.shutdown()
        }
    }

    public func shutdownActiveViewports() {
        shutdownClinicalViewportSession()
        volumeViewport3DTask?.cancel()
        volumeViewport3DTask = nil
        volumeViewport3D = nil
    }

    public func set3DInteractionMode(_ mode: NativeVolume3DInteractionMode) {
        interactionMode = mode
    }

    public func rotateSingleViewport(screenDelta: CGSize) {
        handleSingleViewportDrag(screenDelta: screenDelta)
    }

    public func handleSingleViewportDrag(screenDelta: CGSize) {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        let delta = SIMD2<Float>(Float(screenDelta.width), Float(screenDelta.height))
        let interactionMode = interactionMode
        Task { @MainActor in
            switch interactionMode {
            case .orbit:
                await viewport.rotateCamera(screenDelta: delta)
            case .pan:
                await viewport.panCamera(screenDelta: delta)
            }
        }
    }

    public func zoomSingleViewport(factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        zoomSingleViewportScale(Float(factor))
    }

    public func zoomSingleViewportStep(_ delta: Float) {
        guard delta.isFinite else { return }
        zoomSingleViewportScale(exp(delta))
    }

    public func resetSingleViewportCamera() {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor in
            await viewport.resetCamera()
        }
    }

    public func beginSingleViewportInteraction() {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor in
            await viewport.beginAdaptiveSamplingInteraction()
        }
    }

    public func endSingleViewportInteraction() {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor in
            await viewport.endAdaptiveSamplingInteraction()
        }
    }

    public func forceFinalSingleViewportQuality() {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor in
            await viewport.forceFinalRenderQuality()
        }
    }

    public func setMPRInteractionTool(_ tool: ClinicalMPRInteractionTool) {
        mprInteractionTool = tool
        clinicalViewportSession?.setMPRInteractionTool(tool)
    }

    public func setActiveMPRAxis(_ axis: MTKCore.Axis) {
        activeMPRAxis = axis
        clinicalViewportSession?.setActiveMPRAxis(axis)
        syncMPRState(from: clinicalViewportSession)
    }

    public func setMPRSlicePosition(axis: MTKCore.Axis, normalizedPosition: Double) {
        let clamped = min(max(normalizedPosition.isFinite ? normalizedPosition : 0.5, 0), 1)
        activeMPRAxis = axis
        mprSlicePositions[axis] = clamped
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.setMPRSlicePosition(axis: axis, normalizedPosition: Float(clamped))
            self.syncMPRState(from: session)
        }
    }

    public func setMPRSlabThickness(_ thickness: Double) {
        guard thickness.isFinite else { return }
        mprSlabThickness = min(max(thickness, 1), 99)
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.setMPRSlabThickness(self.mprSlabThickness)
            self.syncMPRState(from: session)
        }
    }

    public func zoomActiveMPR(factor: Float) {
        guard mode == .clinical, factor.isFinite, factor > 0 else { return }
        clinicalViewportSession?.zoomMPR(axis: activeMPRAxis, factor: factor)
        syncMPRState(from: clinicalViewportSession)
    }

    public func resetActiveMPRView() {
        guard mode == .clinical else { return }
        clinicalViewportSession?.resetMPRView(axis: activeMPRAxis)
        syncMPRState(from: clinicalViewportSession)
    }

    public func resetAllMPRViews() {
        guard mode == .clinical else { return }
        clinicalViewportSession?.resetAllMPRViews()
        syncMPRState(from: clinicalViewportSession)
    }

    public func applyMPRQuickWindowPreset(_ quickPreset: ClinicalViewerWindowQuickPreset) {
        let preset = quickPreset.windowLevelPreset
        mprWindow = preset.window
        mprLevel = preset.level
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.setMPRWindowLevel(window: preset.window, level: preset.level)
            self.syncMPRState(from: session)
        }
    }

    public func setVolumeOpacityScale(_ scale: Double) {
        guard scale.isFinite else { return }
        volumeOpacityScale = min(max(scale, 0.1), 2.0)
        reapplySingleViewportTransferFunction()
    }

    public func applyQuickPreset(_ quickPreset: ClinicalViewerTransferQuickPreset) {
        applyPreset(quickPreset.preset)
    }

    public func transferFunction(for preset: ClinicalTransferFunctionPreset,
                                 opacityScale: Double? = nil) throws -> TransferFunction {
        let transferFunction = try preset.loadTransferFunction()
        let scale = Float(min(max(opacityScale ?? volumeOpacityScale, 0.1), 2.0))
        return applyingOpacityScale(scale, to: transferFunction)
    }

    @discardableResult
    public func setRenderMethod(_ newMethod: VolumetricRenderMethod) -> Bool {
        clearSnapshotMetrics()
        let previousMethod = renderMethod
        renderMethod = newMethod
        switch mode {
        case .single3D:
            guard let viewport = volumeViewport3D else {
                ensureVolumeViewport3D()
                return true
            }
            Task { @MainActor [weak self] in
                await viewport.setRenderMethod(newMethod)
                self?.errorMessage = nil
            }
        case .clinical:
            guard let session = clinicalViewportSession else { return true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await session.setVolumeViewportMode(newMethod.clinicalViewportMode)
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                    if self.renderMethod == newMethod {
                        self.renderMethod = previousMethod
                    }
                }
            }
        }
        return true
    }

    public func applyPreset(_ newPreset: ClinicalTransferFunctionPreset) {
        clearSnapshotMetrics()
        let previousPreset = transferPreset
        let previousMethod = renderMethod
        transferPreset = newPreset
        renderMethod = VolumetricRenderMethod(renderMode: newPreset.renderingIntent.mode)
        switch mode {
        case .single3D:
            guard let viewport = volumeViewport3D else {
                ensureVolumeViewport3D()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await viewport.applyTransferFunction(self.transferFunction(for: newPreset))
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                    if self.transferPreset == newPreset {
                        self.transferPreset = previousPreset
                        self.renderMethod = previousMethod
                    }
                }
            }
        case .clinical:
            guard let session = clinicalViewportSession else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await session.applyClinicalTransferFunctionPreset(newPreset)
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                    if self.transferPreset == newPreset {
                        self.transferPreset = previousPreset
                        self.renderMethod = previousMethod
                    }
                }
            }
        }
    }

    public func applyDataset(_ dataset: VolumeDataset) async throws {
        clearSnapshotMetrics()
        self.dataset = dataset
        ensureActiveViewport()
        guard let viewport = await activeViewportReady() else {
            throw activeViewportUnavailableError()
        }
        try await applyDataset(dataset, to: viewport)
        try await applyCurrentConfiguration(to: viewport)
        errorMessage = nil
    }

    public func setVolumeLayers(_ layers: [VolumeLayer]) async {
        currentVolumeLayers = layers
        guard let viewport = await activeViewportReady() else { return }
        await setVolumeLayers(layers, on: viewport)
    }

    public func setSurfaceMeshLayers(_ layers: [SurfaceMeshLayer]) async {
        currentSurfaceMeshLayers = layers
        guard let viewport = await activeViewportReady() else { return }
        await setSurfaceMeshLayers(layers, on: viewport)
    }

    public func clearLayers() async {
        await setVolumeLayers([])
        await setSurfaceMeshLayers([])
    }

    public func setVolumeLayerVisibility(id: String, isVisible: Bool) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].isVisible = isVisible
        }
        guard let viewport = await activeViewportReady() else { return }
        await setVolumeLayerVisibility(id: id, isVisible: isVisible, on: viewport)
    }

    public func setVolumeLayerOpacity(id: String, opacity: Float) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].opacity = opacity
        }
        guard let viewport = await activeViewportReady() else { return }
        await setVolumeLayerOpacity(id: id, opacity: opacity, on: viewport)
    }

    public func setVolumeLayerBlendMode(id: String, blendMode: VolumeLayerBlendMode) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].blendMode = blendMode
        }
        guard let viewport = await activeViewportReady() else { return }
        await setVolumeLayerBlendMode(id: id, blendMode: blendMode, on: viewport)
    }

    public func setSurfaceMeshLayerVisibility(id: String, isVisible: Bool) async {
        if let index = currentSurfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            currentSurfaceMeshLayers[index].isVisible = isVisible
        }
        guard let viewport = await activeViewportReady() else { return }
        await setSurfaceMeshLayerVisibility(id: id, isVisible: isVisible, on: viewport)
    }

    public func setSurfaceMeshLayerOpacity(id: String, opacity: Float) async {
        if let index = currentSurfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            currentSurfaceMeshLayers[index].opacity = opacity
        }
        guard let viewport = await activeViewportReady() else { return }
        await setSurfaceMeshLayerOpacity(id: id, opacity: opacity, on: viewport)
    }

    public func setCropEnabled(_ enabled: Bool) {
        cropEnabled = enabled
        reapplyCropClip()
    }

    public func updateCropBound(axis: ClinicalViewerCropAxis,
                                isMin: Bool,
                                value: Double) {
        let clamped = min(max(value, 0), 1)
        switch (axis, isMin) {
        case (.x, true):
            cropXMin = min(clamped, cropXMax)
        case (.x, false):
            cropXMax = max(clamped, cropXMin)
        case (.y, true):
            cropYMin = min(clamped, cropYMax)
        case (.y, false):
            cropYMax = max(clamped, cropYMin)
        case (.z, true):
            cropZMin = min(clamped, cropZMax)
        case (.z, false):
            cropZMax = max(clamped, cropZMin)
        }
        reapplyCropClip()
    }

    public func setClipEnabled(_ enabled: Bool) {
        clipEnabled = enabled
        reapplyCropClip()
    }

    public func setClipAxis(_ axis: MTKCore.Axis) {
        clipAxis = axis
        reapplyCropClip()
    }

    public func updateClipPlaneOffset(_ offset: Double) {
        clipPlaneOffset = min(max(offset, -0.5), 0.5)
        reapplyCropClip()
    }

    public func resetCropClip() {
        cropEnabled = false
        cropXMin = 0
        cropXMax = 1
        cropYMin = 0
        cropYMax = 1
        cropZMin = 0
        cropZMax = 1
        clipEnabled = false
        clipAxis = .axial
        clipPlaneOffset = 0
        reapplyCropClip()
    }

    public func currentVolumeClippingState() throws -> VolumeClippingState {
        let cropBox: VolumeCropBox?
        if cropEnabled {
            cropBox = try VolumeCropBox(
                textureMin: SIMD3<Float>(Float(cropXMin), Float(cropYMin), Float(cropZMin)),
                textureMax: SIMD3<Float>(Float(cropXMax), Float(cropYMax), Float(cropZMax))
            )
        } else {
            cropBox = nil
        }

        let clipPlanes: [VolumeClipPlane]
        if clipEnabled, let dataset {
            clipPlanes = [
                try VolumeClipPlane(textureCenteredNormal: textureCenteredClipNormal(for: clipAxis),
                                    offset: Float(clipPlaneOffset),
                                    dataset: dataset)
            ]
        } else {
            clipPlanes = []
        }

        return try VolumeClippingState(cropBox: cropBox,
                                       clipPlanes: clipPlanes)
    }

    public func renderSnapshotFrame() async throws -> VolumeRenderFrame {
        guard let viewport = await activeViewportReady() else {
            throw activeViewportUnavailableError()
        }
        switch viewport {
        case .single3D(let volumeViewport):
            return try await volumeViewport.renderSnapshotFrame()
        case .clinical(let session):
            return try await session.renderVolumeSnapshotFrame()
        }
    }

    private func applyingOpacityScale(_ scale: Float,
                                      to transferFunction: TransferFunction) -> TransferFunction {
        var copy = transferFunction
        let resolvedScale = scale.isFinite ? scale : 1
        copy.alphaPoints = transferFunction.alphaPoints.map { point in
            TransferFunction.AlphaPoint(dataValue: point.dataValue,
                                        alphaValue: min(max(point.alphaValue * resolvedScale, 0), 1))
        }
        return copy
    }

    private func textureCenteredClipNormal(for axis: MTKCore.Axis) -> SIMD3<Float> {
        switch axis {
        case .axial:
            return SIMD3<Float>(0, 0, 1)
        case .sagittal:
            return SIMD3<Float>(1, 0, 0)
        case .coronal:
            return SIMD3<Float>(0, 1, 0)
        }
    }

    public func exportSnapshotPNGData() async throws -> ClinicalViewerSnapshotExport {
        guard !isExportingSnapshot else {
            throw ClinicalViewerCoordinatorError.viewportUnavailable("Snapshot export is already in progress.")
        }
        clearSnapshotMetrics()
        isExportingSnapshot = true
        snapshotError = nil
        defer { isExportingSnapshot = false }

        do {
            let frame = try await renderSnapshotFrame()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MTKSnapshotExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let filename = "mtk-\(renderMethod.rawValue)-snapshot-\(UUID().uuidString).png"
            let url = directory.appendingPathComponent(filename)
            try await snapshotExporter.writePNG(from: frame, to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let export = ClinicalViewerSnapshotExport(
                filename: url.deletingPathExtension().lastPathComponent,
                data: data,
                metrics: snapshotExporter.lastOperationMetrics()
            )
            lastSnapshotMetrics = export.metrics
            scheduleSnapshotMetricsClear()
            return export
        } catch {
            snapshotError = error.localizedDescription
            throw error
        }
    }

    public func refreshProfilingHUDMetrics() async {
        guard mode == .clinical, let session = clinicalViewportSession else {
            hudRenderTimeMilliseconds = nil
            hudPresentationTimeMilliseconds = nil
            hudUploadTimeMilliseconds = nil
            hudMemoryBytes = nil
            return
        }

        async let memoryMetrics = session.resourceMetrics()
        let timingSnapshot = session.latestTimingSnapshot

        let metrics = await memoryMetrics
        hudMemoryBytes = metrics.estimatedMemoryBytes
        hudRenderTimeMilliseconds = timingSnapshot.renderTime.map { $0 * 1000.0 }
        hudPresentationTimeMilliseconds = timingSnapshot.presentationTime.map { $0 * 1000.0 }
        hudUploadTimeMilliseconds = timingSnapshot.uploadTime.map { $0 * 1000.0 }
        if let renderError = session.lastRenderError {
            errorMessage = renderError.localizedDescription
        } else {
            errorMessage = nil
        }
    }

    private func configureSingle3DViewport(_ viewport: VolumeViewport3D) async {
        if viewport.adaptiveSamplingEnabled {
            await viewport.setAdaptiveSampling(false)
        }
        await viewport.setSamplingStep(single3DFinalSamplingStep)
    }

    private func zoomSingleViewportScale(_ scale: Float) {
        guard mode == .single3D,
              scale.isFinite,
              scale > 0,
              let viewport = volumeViewport3D else {
            return
        }
        Task { @MainActor in
            await viewport.zoomCamera(scale: scale)
        }
    }

    private func sessionReady() async -> ClinicalViewportSession? {
        if let session = clinicalViewportSession {
            bindClinicalSession(session)
            return session
        }
        ensureClinicalViewportSession()
        let session = await clinicalViewportSessionTask?.value
        if let session {
            bindClinicalSession(session)
            syncMPRState(from: session)
        }
        return session ?? clinicalViewportSession
    }

    private func bindClinicalSession(_ session: ClinicalViewportSession) {
        guard clinicalViewportSession === session, clinicalSessionCancellable == nil else { return }
        clinicalSessionCancellable = session.objectWillChange
            .sink { [weak self, weak session] _ in
                Task { @MainActor in
                    self?.syncMPRState(from: session)
                }
            }
    }

    private func syncMPRState(from session: ClinicalViewportSession?) {
        guard let session else { return }
        mprInteractionTool = session.mprInteractionTool
        activeMPRAxis = session.activeMPRAxis
        mprSlicePositions = session.normalizedPositions.mapValues { Double($0) }
        mprWindow = session.windowLevel.window
        mprLevel = session.windowLevel.level
        mprSlabThickness = session.slabThickness
        mprViewportTransforms = session.mprViewportTransforms
    }

    private func volumeViewportReady() async -> VolumeViewport3D? {
        if let viewport = volumeViewport3D {
            return viewport
        }
        ensureVolumeViewport3D()
        let viewport = await volumeViewport3DTask?.value
        return viewport ?? volumeViewport3D
    }

    private func activeViewportUnavailableError() -> ClinicalViewerCoordinatorError {
        ClinicalViewerCoordinatorError.viewportUnavailable(errorMessage)
    }

    private func activeViewportReady() async -> ActiveClinicalViewerViewport? {
        switch mode {
        case .single3D:
            guard let viewport = await volumeViewportReady() else { return nil }
            return .single3D(viewport)
        case .clinical:
            guard let session = await sessionReady() else { return nil }
            return .clinical(session)
        }
    }

    private func applyDataset(_ dataset: VolumeDataset,
                              to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.applyDataset(dataset)
        case .clinical(let session):
            try await session.applyDataset(dataset)
        }
    }

    private func applyCurrentConfiguration(to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            try await applyCurrentConfiguration(to: volumeViewport)
        case .clinical(let session):
            try await applyCurrentConfiguration(to: session)
        }
    }

    private func applyCurrentConfiguration(to session: ClinicalViewportSession) async throws {
        try await session.setVolumeViewportMode(renderMethod.clinicalViewportMode)
        try await session.setTransferFunction(transferPreset.loadTransferFunction())
        try await applyCropClip(to: session)
        session.setMPRInteractionTool(mprInteractionTool)
        session.setActiveMPRAxis(activeMPRAxis)

        if let dataset {
            let window = dataset.recommendedWindow ?? dataset.intensityRange
            await session.setMPRWindowLevel(window: Double(max(window.upperBound - window.lowerBound, 1)),
                                            level: Double(window.lowerBound + window.upperBound) / 2.0)
        }
        syncMPRState(from: session)
    }

    private func applyCurrentConfiguration(to viewport: VolumeViewport3D) async throws {
        await viewport.setRenderMethod(renderMethod)
        try await viewport.setTransferFunction(transferFunction(for: transferPreset))
        try await applyCropClip(to: viewport)

        if let dataset {
            let window = dataset.recommendedWindow ?? dataset.intensityRange
            await viewport.setWindowLevel(window: Double(max(window.upperBound - window.lowerBound, 1)),
                                          level: Double(window.lowerBound + window.upperBound) / 2.0)
        }
    }

    private func reapplySingleViewportTransferFunction() {
        clearSnapshotMetrics()
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await viewport.setTransferFunction(self.transferFunction(for: self.transferPreset))
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func reapplyCropClip() {
        clearSnapshotMetrics()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let viewport = await self.activeViewportReady() else { return }
            do {
                try await self.applyCropClip(to: viewport)
                self.clippingErrorMessage = nil
                self.errorMessage = nil
            } catch {
                self.clippingErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyCropClip(to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            try await applyCropClip(to: volumeViewport)
        case .clinical(let session):
            try await applyCropClip(to: session)
        }
    }

    private func applyCropClip(to session: ClinicalViewportSession) async throws {
        let clipping = try currentVolumeClippingState()
        try await session.setVolumeClipping(clipping)
        clippingErrorMessage = nil
    }

    private func applyCropClip(to viewport: VolumeViewport3D) async throws {
        let clipping = try currentVolumeClippingState()
        try await viewport.setVolumeClipping(clipping)
        clippingErrorMessage = nil
    }

    private func setVolumeLayers(_ layers: [VolumeLayer],
                                 on viewport: ActiveClinicalViewerViewport) async {
        currentVolumeLayers = layers
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setVolumeLayers(layers)
        case .clinical(let session):
            await session.setVolumeLayers(layers)
        }
    }

    private func setSurfaceMeshLayers(_ layers: [SurfaceMeshLayer],
                                      on viewport: ActiveClinicalViewerViewport) async {
        currentSurfaceMeshLayers = layers
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setSurfaceMeshLayers(layers)
        case .clinical(let session):
            await session.setSurfaceMeshLayers(layers)
        }
    }

    private func setVolumeLayerVisibility(id: String,
                                          isVisible: Bool,
                                          on viewport: ActiveClinicalViewerViewport) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].isVisible = isVisible
        }
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setVolumeLayerVisibility(id: id, isVisible: isVisible)
        case .clinical(let session):
            await session.setVolumeLayerVisibility(id: id, isVisible: isVisible)
        }
    }

    private func setVolumeLayerOpacity(id: String,
                                       opacity: Float,
                                       on viewport: ActiveClinicalViewerViewport) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].opacity = opacity
        }
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setVolumeLayerOpacity(id: id, opacity: opacity)
        case .clinical(let session):
            await session.setVolumeLayerOpacity(id: id, opacity: opacity)
        }
    }

    private func setVolumeLayerBlendMode(id: String,
                                         blendMode: VolumeLayerBlendMode,
                                         on viewport: ActiveClinicalViewerViewport) async {
        if let index = currentVolumeLayers.firstIndex(where: { $0.id == id }) {
            currentVolumeLayers[index].blendMode = blendMode
        }
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setVolumeLayerBlendMode(id: id, blendMode: blendMode)
        case .clinical(let session):
            await session.setVolumeLayerBlendMode(id: id, blendMode: blendMode)
        }
    }

    private func setSurfaceMeshLayerVisibility(id: String,
                                               isVisible: Bool,
                                               on viewport: ActiveClinicalViewerViewport) async {
        if let index = currentSurfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            currentSurfaceMeshLayers[index].isVisible = isVisible
        }
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setSurfaceMeshLayerVisibility(id: id, isVisible: isVisible)
        case .clinical(let session):
            await session.setSurfaceMeshLayerVisibility(id: id, isVisible: isVisible)
        }
    }

    private func setSurfaceMeshLayerOpacity(id: String,
                                            opacity: Float,
                                            on viewport: ActiveClinicalViewerViewport) async {
        if let index = currentSurfaceMeshLayers.firstIndex(where: { $0.id == id }) {
            currentSurfaceMeshLayers[index].opacity = opacity
        }
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.setSurfaceMeshLayerOpacity(id: id, opacity: opacity)
        case .clinical(let session):
            await session.setSurfaceMeshLayerOpacity(id: id, opacity: opacity)
        }
    }

    private func clearSnapshotMetrics() {
        snapshotMetricsClearTask?.cancel()
        snapshotMetricsClearTask = nil
        lastSnapshotMetrics = nil
    }

    private func scheduleSnapshotMetricsClear(after delayNanoseconds: UInt64 = 8_000_000_000) {
        snapshotMetricsClearTask?.cancel()
        snapshotMetricsClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.lastSnapshotMetrics = nil
            self?.snapshotMetricsClearTask = nil
        }
    }
}
