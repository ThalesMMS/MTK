import Combine
import CoreGraphics
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
    case stack2D(StackViewport)
}

@MainActor
public final class ClinicalViewerCoordinator: ObservableObject {
    private let single3DFinalSamplingStep: Float
    private let volumeRenderQualitySettingsStore: VolumeRenderQualitySettingsStoring
    private let snapshotExporter = TextureSnapshotExporter()

    @Published public private(set) var clinicalViewportSession: ClinicalViewportSession?
    @Published public private(set) var volumeViewport3D: VolumeViewport3D?
    @Published public private(set) var stack2DViewport: StackViewport?
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
    @Published public var mprWindowPreset: MPRWindowPreset = .default
    @Published public var mprCLUTPreset: Volume3DCLUTPreset = .defaultPreset
    @Published public var isMPRWindowInverted = false
    @Published public var mprROIKind: ViewerROIKind = .distance
    @Published public private(set) var mprROIAnnotations: [ViewerROIAnnotation] = []
    @Published public var mprSlabBlendMode: MPRSlabBlendOption = .mean
    @Published public var mprSlabThickness: Double = 3
    @Published public var isMPRAnnotationsVisible = true
    @Published public var isMPRCrosshairVisible = true
    @Published public var selectedMPRScreenLayout: MPRScreenLayout = .defaultLayout
    @Published public var mprViewportTransforms: [MTKCore.Axis: MPRViewportTransform] = [
        .axial: .identity,
        .coronal: .identity,
        .sagittal: .identity
    ]
    @Published public var twoDAxis: MTKCore.Axis = .axial
    @Published public var twoDTool: Clinical2DTool = .scroll
    @Published public private(set) var twoDWindowLevelState = TwoDWindowLevelState.default
    @Published public var twoDTransform = Viewer2DTransform.identity
    @Published public private(set) var twoDSliceIndex = 0
    @Published public private(set) var twoDSliceCount = 0
    @Published public var twoDROIKind: ViewerROIKind = .distance
    @Published public private(set) var twoDROIAnnotations: [ViewerROIAnnotation] = []
    @Published public private(set) var twoDSyncState = ViewerSyncState.default
    @Published public var twoDScrollSettings = TwoDScrollSettings.default
    @Published public var twoDHUDSettings = TwoDHUDSettings.default
    @Published public var twoDMetadataOverlaySettings = ClinicalViewportMetadataOverlaySettings.default
    @Published public var twoDResliceAxis: MTKCore.Axis = .axial
    @Published public private(set) var keyImageNavigationState = KeyImageNavigationState()
    private var preferredTwoDSyncLocation = ViewerSyncState.default.syncLocation
    @Published public var volumeOpacityScale: Double = 1.0
    @Published public var errorMessage: String?
    @Published public var renderMethod: VolumetricRenderMethod = .dvr
    @Published public var transferPreset: ClinicalTransferFunctionPreset = .ctSoftTissue
    @Published public var volume3DWindowPreset: Volume3DWindowPreset = .default
    @Published public var volume3DCLUTPreset: Volume3DCLUTPreset = .defaultPreset
    @Published public var volume3DRotationTarget: Volume3DRotationTarget = .model
    @Published public var showDebugOverlay = false
    @Published public var isExportingSnapshot = false
    @Published public var adaptiveSamplingEnabled = true
    @Published public private(set) var volumeRenderQualitySettings: VolumeRenderQualitySettings
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
    @Published public var volumeBrushState = VolumeBrushState()
    @Published public private(set) var volumeBrushCursor: CGPoint?
    @Published public private(set) var volumeBrushMaskHasEdits = false
    @Published public private(set) var hudRenderTimeMilliseconds: Double?
    @Published public private(set) var hudPresentationTimeMilliseconds: Double?
    @Published public private(set) var hudUploadTimeMilliseconds: Double?
    @Published public private(set) var hudMemoryBytes: Int?
    @Published public private(set) var lastSnapshotMetrics: SnapshotMetrics?
    @Published public private(set) var rtDoseOverlays: [RTDoseVolumeOverlay] = []
    @Published public private(set) var rtStructureContourOverlays: [RTStructureContourOverlay] = []
    @Published public private(set) var rtStructureContourConfiguration = RTStructureContourOverlayConfiguration.default
    @Published public private(set) var mprPresentationStates: [MTKCore.Axis: MPRPresentationState] = [:]
    @Published public private(set) var structuredReportViewerState: StructuredReportViewerState?
    @Published public private(set) var hangingProtocolResolvedLayout: HangingProtocolResolvedLayout?
    @Published public private(set) var hangingProtocolSlotAssignments: [HangingProtocolResolvedViewport] = []

    private var clinicalViewportSessionTask: Task<ClinicalViewportSession?, Never>?
    private var volumeViewport3DTask: Task<VolumeViewport3D?, Never>?
    private var stack2DViewportTask: Task<StackViewport?, Never>?
    private var snapshotMetricsClearTask: Task<Void, Never>?
    private var clinicalSessionCancellable: AnyCancellable?
    private var currentVolumeLayers: [VolumeLayer] = []
    private var currentSurfaceMeshLayers: [SurfaceMeshLayer] = []
    private var currentRTDoseLayerIDs = Set<String>()
    private var hangingProtocolDefinition: HangingProtocolDefinition?
    private var hangingProtocolContext: HangingProtocolContext?
    private var volumeBrushMaskedDataset: VolumeDataset?
    private var activeTwoDInteractionCount = 0
    private var twoDROIStore = ViewerROIStore()

    public init(single3DFinalSamplingStep: Float = 768,
                volumeRenderQualitySettingsStore: VolumeRenderQualitySettingsStoring = UserDefaultsVolumeRenderQualitySettingsStore()) {
        self.single3DFinalSamplingStep = single3DFinalSamplingStep
        self.volumeRenderQualitySettingsStore = volumeRenderQualitySettingsStore
        self.volumeRenderQualitySettings = volumeRenderQualitySettingsStore.loadVolumeRenderQualitySettings() ?? .default
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
            return false
        case .stack2D:
            return false
        }
    }

    public var twoDWindowLevel: WindowLevelShift {
        twoDWindowLevelState.windowLevel
    }

    public var twoDWindowPreset: Volume3DWindowPreset {
        twoDWindowLevelState.selectedWindowPreset
    }

    public var twoDCLUTPreset: Clinical2DCLUT {
        twoDWindowLevelState.clut
    }

    public var isTwoDWindowInverted: Bool {
        twoDWindowLevelState.isInverted
    }

    public var isTwoDSyncEnabled: Bool {
        twoDSyncState.hasActiveSyncChannels
    }

    public var currentTwoDPanelIdentity: ViewerPanelIdentity {
        ViewerPanelIdentity(panelID: "stack2D.primary", dataset: dataset)
    }

    public var canSyncTwoDLocation: Bool {
        currentTwoDPanelIdentity.datasetIdentifier != nil ||
            currentTwoDPanelIdentity.frameOfReferenceUID != nil
    }

    public var canUseTwoDReslice: Bool {
        guard let dataset else { return false }
        return Self.supportsTwoDReslice(dataset)
    }

    public var twoDResliceDisabledMessage: String? {
        guard let dataset else { return "No dataset loaded." }
        return Self.supportsTwoDReslice(dataset) ? nil : "2D reslice requires a volumetric dataset."
    }

    public var volumeLayers: [VolumeLayer] {
        currentVolumeLayers
    }

    public var surfaceMeshLayers: [SurfaceMeshLayer] {
        currentSurfaceMeshLayers
    }

    public var quantitativeScalarLegends: [QuantitativeScalarLayerLegend] {
        currentVolumeLayers.compactMap(\.quantitativeLegend)
    }

    public var volumeBrushEditedDataset: VolumeDataset? {
        volumeBrushMaskedDataset
    }

    public func ensureActiveViewport() {
        switch mode {
        case .single3D:
            ensureVolumeViewport3D()
        case .clinical:
            ensureClinicalViewportSession()
        case .stack2D:
            ensureStack2DViewport()
        }
    }

    public func setMode(_ newMode: ClinicalViewerMode) {
        guard newMode != mode else { return }
        clearSnapshotMetrics()
        mode = newMode
        switch newMode {
        case .single3D:
            // The clinical viewport session is kept alive/cached to allow instant switching back to MPR.
            ensureVolumeViewport3D()
            Task { @MainActor [weak self] in
                guard let self, let viewport = await self.volumeViewportReady() else { return }
                if let dataset = self.dataset {
                    await viewport.applyDataset(dataset)
                }
                try? await self.applyCurrentConfiguration(to: viewport)
                await viewport.setVolumeLayers(self.currentVolumeLayers)
                await viewport.setSurfaceMeshLayers(self.currentSurfaceMeshLayers)
                await viewport.setPrimaryVolumeDatasetOverride(self.volumeBrushMaskedDataset)
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
        case .stack2D:
            ensureStack2DViewport()
            Task { @MainActor [weak self] in
                guard let self, let viewport = await self.stack2DReady() else { return }
                if let dataset = self.dataset {
                    await viewport.applyDataset(dataset)
                }
                await self.applyCurrentConfiguration(to: viewport)
                await viewport.setVolumeLayers(self.currentVolumeLayers)
                self.sync2DState(from: viewport)
                self.errorMessage = nil
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
                await viewport.setPrimaryVolumeDatasetOverride(self.volumeBrushMaskedDataset)
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

    public func ensureStack2DViewport() {
        guard isMetalAvailable else {
            errorMessage = "Metal is not available on this device."
            return
        }
        if let stack2DViewport {
            sync2DState(from: stack2DViewport)
            Task { @MainActor [weak self, weak stack2DViewport] in
                guard let self, let stack2DViewport else { return }
                await self.applyCurrentConfiguration(to: stack2DViewport)
            }
            return
        }
        guard stack2DViewportTask == nil else { return }

        createStack2DViewport(axis: twoDAxis,
                              initialSliceIndex: twoDSliceIndex)
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

    public func shutdownStack2DViewport() {
        stack2DViewportTask?.cancel()
        stack2DViewportTask = nil
        clearSnapshotMetrics()
        stack2DViewport = nil
        twoDSliceIndex = 0
        twoDSliceCount = 0
        twoDROIAnnotations = []
    }

    private func createStack2DViewport(axis: MTKCore.Axis,
                                       initialSliceIndex: Int) {
        stack2DViewportTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                let viewport = try StackViewport(axis: axis,
                                                 initialSliceIndex: initialSliceIndex)
                if let dataset = self.dataset {
                    await viewport.applyDataset(dataset)
                }
                await self.applyCurrentConfiguration(to: viewport)
                await viewport.setVolumeLayers(self.currentVolumeLayers)
                self.stack2DViewport = viewport
                self.sync2DState(from: viewport)
                self.errorMessage = nil
                self.stack2DViewportTask = nil
                return viewport
            } catch {
                self.errorMessage = error.localizedDescription
                self.stack2DViewportTask = nil
                return nil
            }
        }
    }

    public func shutdownActiveViewports() {
        shutdownClinicalViewportSession()
        shutdownStack2DViewport()
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
            case .transferFunction:
                await viewport.adjustTransferFunctionShift(screenDelta: delta)
            case .crop:
                break
            case .brush:
                break
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

    public func set3DOrientation(_ orientation: Volume3DAnatomicalOrientation) {
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        interactionMode = .orbit
        Task { @MainActor in
            await viewport.setCameraOrientation(orientation)
        }
    }

    public func reset3DOrientation() {
        resetSingleViewportCamera()
        interactionMode = .orbit
    }

    public func set3DRotationTarget(_ target: Volume3DRotationTarget) {
        guard target.isEnabled else { return }
        volume3DRotationTarget = target
        interactionMode = .orbit
    }

    public func reset3DRotation() {
        switch volume3DRotationTarget {
        case .model:
            guard mode == .single3D, let viewport = volumeViewport3D else { return }
            interactionMode = .orbit
            Task { @MainActor in
                await viewport.resetCameraRotation()
            }
        case .cropBox:
            break
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

    public func setMPRROIKind(_ kind: ViewerROIKind) {
        guard kind.isImplementedInMPRFirstDelivery else { return }
        mprROIKind = kind
        mprInteractionTool = .roi
        clinicalViewportSession?.setMPRROIKind(kind)
        syncMPRState(from: clinicalViewportSession)
    }

    public func deleteMPRROIsInActiveView() {
        clinicalViewportSession?.deleteMPRROIsInActiveView()
        syncMPRState(from: clinicalViewportSession)
    }

    public func deleteAllMPRROIs() {
        clinicalViewportSession?.deleteAllMPRROIs()
        syncMPRState(from: clinicalViewportSession)
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

    public func setMPRSlabBlendMode(_ blendMode: MPRSlabBlendOption) {
        mprSlabBlendMode = blendMode
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.setMPRSlabBlendMode(blendMode)
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

    public func setMPRScreenLayout(_ layout: MPRScreenLayout) {
        selectedMPRScreenLayout = layout
    }

    public func setTwoDTool(_ tool: Clinical2DTool) {
        twoDTool = tool
    }

    public func setTwoDAxis(_ axis: MTKCore.Axis) {
        set2DResliceAxis(axis)
    }

    public func set2DResliceAxis(_ axis: MTKCore.Axis) {
        guard canUseTwoDReslice else {
            errorMessage = twoDResliceDisabledMessage
            return
        }
        twoDTool = .reslice
        guard axis != twoDAxis else { return }
        let normalizedPosition = currentTwoDNormalizedSlicePosition(default: 0.5)
        let mappedSliceIndex = Self.twoDSliceIndex(forNormalizedPosition: normalizedPosition,
                                                   axis: axis,
                                                   dataset: dataset)
        twoDAxis = axis
        twoDResliceAxis = axis
        twoDSliceCount = Self.twoDSliceCount(for: axis, in: dataset)
        twoDSliceIndex = mappedSliceIndex
        publishTwoDROIAnnotations()
        guard mode == .stack2D else { return }
        stack2DViewportTask?.cancel()
        stack2DViewportTask = nil
        stack2DViewport = nil
        clearSnapshotMetrics()
        if isMetalAvailable {
            createStack2DViewport(axis: axis,
                                  initialSliceIndex: mappedSliceIndex)
        } else {
            errorMessage = "Metal is not available on this device."
        }
    }

    public func setTwoDSliceIndex(_ index: Int) {
        let upperBound = twoDSliceCount > 0 ? twoDSliceCount - 1 : Int.max
        twoDSliceIndex = min(max(index, 0), upperBound)
        syncKeyImageSelectionForCurrentSlice()
        publishTwoDROIAnnotations()
        guard let stack2DViewport else { return }
        Task { @MainActor [weak self, weak stack2DViewport] in
            guard let self, let stack2DViewport else { return }
            await stack2DViewport.setSliceIndex(self.twoDSliceIndex)
            self.sync2DState(from: stack2DViewport)
        }
    }

    public var hasResolvedKeyImages: Bool {
        keyImageNavigationState.hasResolvedImages
    }

    public var isKeyImageFilterEnabled: Bool {
        keyImageNavigationState.isFilterEnabled
    }

    public func applyKeyImageNavigationState(_ state: KeyImageNavigationState) {
        keyImageNavigationState = state
        syncKeyImageSelectionForCurrentSlice()
    }

    public func setKeyImageFilterEnabled(_ enabled: Bool) {
        var next = keyImageNavigationState
        next.setFilterEnabled(enabled)
        keyImageNavigationState = next
        if enabled, let image = next.selectedImage ?? next.resolvedImages.first {
            setTwoDSliceIndex(image.sliceIndex)
        }
    }

    @discardableResult
    public func navigateToNextKeyImage() -> ResolvedKeyImage? {
        navigateKeyImages(by: 1)
    }

    @discardableResult
    public func navigateToPreviousKeyImage() -> ResolvedKeyImage? {
        navigateKeyImages(by: -1)
    }

    @discardableResult
    public func navigateKeyImages(by offset: Int) -> ResolvedKeyImage? {
        guard offset != 0, keyImageNavigationState.hasResolvedImages else {
            return keyImageNavigationState.selectedImage
        }
        var next = keyImageNavigationState
        let image = next.selectRelative(toSliceIndex: twoDSliceIndex,
                                        offset: offset,
                                        wrapping: twoDScrollSettings.loopThroughImages)
        keyImageNavigationState = next
        if let image {
            setTwoDSliceIndex(image.sliceIndex)
        }
        return image
    }

    public func setTwoDWindowLevel(window: Double, level: Double) {
        setTwoDWindowLevel(window: window,
                           level: level,
                           presetID: Volume3DWindowPreset.other.rawValue)
    }

    public func applyTwoDWindowPreset(_ preset: Volume3DWindowPreset) {
        twoDTool = .windowLevel
        switch preset {
        case .default:
            let resolved = defaultTwoDWindowLevel()
            setTwoDWindowLevel(window: resolved.window,
                               level: resolved.level,
                               presetID: preset.rawValue)
        case .endoscopy, .other:
            var next = twoDWindowLevelState
            next.presetID = preset.rawValue
            twoDWindowLevelState = next
        case .abdomen, .bone, .brain, .lungs:
            guard let windowPreset = preset.windowLevelPreset else { return }
            setTwoDWindowLevel(window: windowPreset.window,
                               level: windowPreset.level,
                               presetID: preset.rawValue)
        }
    }

    public func applyTwoDCLUTPreset(_ preset: Clinical2DCLUT) {
        var next = twoDWindowLevelState
        next.clut = preset
        twoDWindowLevelState = next
        twoDTool = .windowLevel
        applyTwoDWindowPresentationToViewport()
    }

    public func toggleTwoDWindowInverted() {
        var next = twoDWindowLevelState
        next.isInverted.toggle()
        twoDWindowLevelState = next
        twoDTool = .windowLevel
        applyTwoDWindowPresentationToViewport()
    }

    private func setTwoDWindowLevel(window: Double,
                                    level: Double,
                                    presetID: String?) {
        guard let next = twoDWindowLevelState.applying(window: window,
                                                       level: level,
                                                       presetID: presetID) else {
            return
        }
        twoDWindowLevelState = next
        twoDTool = .windowLevel
        applyTwoDWindowLevelToViewport()
    }

    private func applyTwoDWindowLevelToViewport() {
        let state = twoDWindowLevelState
        guard let stack2DViewport else { return }
        Task { @MainActor [weak self, weak stack2DViewport] in
            guard let self, let stack2DViewport else { return }
            await stack2DViewport.setWindowLevel(window: state.window,
                                                 level: state.level)
            stack2DViewport.setWindowPresentation(isInverted: state.isInverted,
                                                  clut: state.clut)
            self.sync2DState(from: stack2DViewport)
        }
    }

    private func applyTwoDWindowPresentationToViewport() {
        let state = twoDWindowLevelState
        guard let stack2DViewport else { return }
        stack2DViewport.setWindowPresentation(isInverted: state.isInverted,
                                              clut: state.clut)
        sync2DState(from: stack2DViewport)
    }

    private func applyTwoDTransformToViewport() {
        guard let stack2DViewport else { return }
        stack2DViewport.setViewportTransform(twoDTransform)
        sync2DState(from: stack2DViewport)
    }

    public func setTwoDTransform(_ transform: Viewer2DTransform) {
        let zoom = transform.zoom.isFinite ? max(transform.zoom, 0.01) : 1
        let panX = transform.pan.x.isFinite ? transform.pan.x : 0
        let panY = transform.pan.y.isFinite ? transform.pan.y : 0
        let rotation = transform.rotationRadians.isFinite ? transform.rotationRadians : 0
        twoDTransform = Viewer2DTransform(
            zoom: zoom,
            pan: SIMD2<Double>(panX, panY),
            rotationRadians: rotation,
            isFlippedHorizontally: transform.isFlippedHorizontally,
            isFlippedVertically: transform.isFlippedVertically
        )
        applyTwoDTransformToViewport()
    }

    public func scrollTwoD(by steps: Int) {
        guard steps != 0 else { return }
        twoDTool = .scroll
        if keyImageNavigationState.isFilterEnabled, keyImageNavigationState.hasResolvedImages {
            navigateKeyImages(by: steps)
            return
        }
        let target: Int
        if twoDSliceCount > 0, twoDScrollSettings.loopThroughImages {
            target = Self.wrappedTwoDSliceIndex(twoDSliceIndex + steps, count: twoDSliceCount)
        } else {
            let upperBound = twoDSliceCount > 0 ? twoDSliceCount - 1 : Int.max
            target = min(max(twoDSliceIndex + steps, 0), upperBound)
        }
        setTwoDSliceIndex(target)
    }

    public func set2DScrollSettings(_ settings: TwoDScrollSettings) {
        twoDScrollSettings = settings
        twoDTool = .scroll
    }

    public func set2DScrollSpeed(_ speed: Double) {
        var settings = twoDScrollSettings
        settings.speed = speed.isFinite ? max(speed, 0.1) : 1.0
        set2DScrollSettings(settings)
    }

    public func set2DImageSortMode(_ sortMode: TwoDImageSortMode) {
        var settings = twoDScrollSettings
        settings.sortMode = sortMode
        set2DScrollSettings(settings)
    }

    public func set2DLoopThroughImages(_ enabled: Bool) {
        var settings = twoDScrollSettings
        settings.loopThroughImages = enabled
        set2DScrollSettings(settings)
    }

    public func set2DOnScreenControls(_ enabled: Bool) {
        var settings = twoDScrollSettings
        settings.showsOnScreenControls = enabled
        set2DScrollSettings(settings)
    }

    public func set2DHUDSettings(_ settings: TwoDHUDSettings) {
        twoDHUDSettings = settings
    }

    public func set2DMetadataOverlaySettings(_ settings: ClinicalViewportMetadataOverlaySettings) {
        twoDMetadataOverlaySettings = settings
    }

    public func scroll2D(by delta: Int) {
        scrollTwoD(by: delta)
    }

    public func set2DSliceIndex(_ index: Int) {
        setTwoDSliceIndex(index)
    }

    public func adjustTwoDWindowLevel(screenDelta: CGSize) {
        guard screenDelta.width.isFinite, screenDelta.height.isFinite else { return }
        twoDTool = .windowLevel
        setTwoDWindowLevel(window: twoDWindowLevel.window + Double(screenDelta.width) * 2,
                           level: twoDWindowLevel.level - Double(screenDelta.height) * 2)
    }

    public func panTwoD(deltaNormalized: SIMD2<Double>) {
        guard deltaNormalized.x.isFinite, deltaNormalized.y.isFinite else { return }
        var transform = twoDTransform
        transform.pan += deltaNormalized
        setTwoDTransform(transform)
    }

    public func zoomTwoD(factor: Double,
                         anchor: SIMD2<Double> = SIMD2<Double>(repeating: 0.5)) {
        guard factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite else {
            return
        }
        var transform = twoDTransform
        transform.zoom *= factor
        setTwoDTransform(transform)
    }

    public func rotateTwoD(byRadians radians: Double) {
        guard radians.isFinite else { return }
        var transform = twoDTransform
        transform.rotationRadians += radians
        setTwoDTransform(transform)
        twoDTool = .rotation
    }

    public func beginTwoDInteraction() {
        activeTwoDInteractionCount += 1
        guard activeTwoDInteractionCount == 1,
              let stack2DViewport else {
            return
        }
        Task { @MainActor [weak stack2DViewport] in
            await stack2DViewport?.beginAdaptiveSamplingInteraction()
        }
    }

    public func endTwoDInteraction() {
        guard activeTwoDInteractionCount > 0 else { return }
        activeTwoDInteractionCount -= 1
        guard activeTwoDInteractionCount == 0,
              let stack2DViewport else {
            return
        }
        Task { @MainActor [weak stack2DViewport] in
            await stack2DViewport?.endAdaptiveSamplingInteraction()
        }
    }

    public func handleTwoDROIInteraction(_ interaction: Clinical2DROIInteraction) {
        guard interaction.axis == twoDAxis else { return }
        twoDTool = .roi
        let points = ViewerROIPointFactory.points(kind: interaction.kind,
                                                  start: interaction.startImagePoint,
                                                  end: interaction.endImagePoint)
        guard !points.isEmpty else { return }
        let annotation = ViewerROIAnnotation(
            kind: interaction.kind,
            axis: interaction.axis,
            sliceIndex: interaction.sliceIndex,
            seriesIdentifier: currentTwoDSeriesIdentifier,
            normalizedImagePoints: points,
            text: interaction.kind == .text ? "Annotation" : nil,
            measurement: twoDMeasurement(kind: interaction.kind,
                                         axis: interaction.axis,
                                         points: points)
        )
        twoDROIStore.add(annotation)
        publishTwoDROIAnnotations()
    }

    private static func wrappedTwoDSliceIndex(_ index: Int,
                                              count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    public func resetTwoDTransform() {
        setTwoDTransform(.identity)
    }

    public func rotateTwoD(byDegrees degrees: Double) {
        guard degrees.isFinite else { return }
        var transform = twoDTransform
        transform.rotationRadians += degrees * .pi / 180.0
        setTwoDTransform(transform)
        twoDTool = .rotation
    }

    public func rotate2D(deltaDegrees degrees: Double) {
        rotateTwoD(byDegrees: degrees)
    }

    public func rotate2DClockwise90() {
        rotateTwoD(byDegrees: 90)
    }

    public func rotate2DCounterClockwise90() {
        rotateTwoD(byDegrees: -90)
    }

    public func flip2DHorizontal() {
        flipTwoDHorizontal()
    }

    public func flip2DVertical() {
        flipTwoDVertical()
    }

    public func reset2DTransform() {
        resetTwoDTransform()
    }

    public func flipTwoDHorizontal() {
        var transform = twoDTransform
        transform.isFlippedHorizontally.toggle()
        setTwoDTransform(transform)
        twoDTool = .rotation
    }

    public func flipTwoDVertical() {
        var transform = twoDTransform
        transform.isFlippedVertically.toggle()
        setTwoDTransform(transform)
        twoDTool = .rotation
    }

    public func setTwoDROIKind(_ kind: ViewerROIKind) {
        twoDROIKind = kind
        twoDTool = .roi
    }

    public func twoDROIAnnotations(axis: MTKCore.Axis? = nil,
                                   sliceIndex: Int? = nil) -> [ViewerROIAnnotation] {
        twoDROIStore.annotations(axis: axis ?? twoDAxis,
                                 sliceIndex: sliceIndex ?? twoDSliceIndex,
                                 seriesIdentifier: currentTwoDSeriesIdentifier)
    }

    public func deleteTwoDROIsInView() {
        twoDROIStore.deleteAnnotations(axis: twoDAxis,
                                       sliceIndex: twoDSliceIndex,
                                       seriesIdentifier: currentTwoDSeriesIdentifier)
        twoDTool = .roi
        publishTwoDROIAnnotations()
    }

    public func deleteAllTwoDROIs() {
        twoDROIStore.deleteAll(seriesIdentifier: currentTwoDSeriesIdentifier)
        twoDTool = .roi
        publishTwoDROIAnnotations()
    }

    public func setTwoDSyncEnabled(_ enabled: Bool) {
        if enabled {
            twoDSyncState.syncTransforms = true
            twoDSyncState.syncWindowLevel = true
            twoDSyncState.syncLocation = preferredTwoDSyncLocation && canSyncTwoDLocation
        } else {
            preferredTwoDSyncLocation = twoDSyncState.syncLocation
            twoDSyncState.syncTransforms = false
            twoDSyncState.syncWindowLevel = false
            twoDSyncState.syncLocation = false
        }
        twoDTool = .sync
    }

    public func setTwoDSyncOption(_ option: ViewerSyncOption,
                                  enabled: Bool) {
        if option == .location {
            let allowed = enabled && canSyncTwoDLocation
            preferredTwoDSyncLocation = allowed
            twoDSyncState = twoDSyncState.setting(.location, enabled: allowed)
        } else {
            twoDSyncState = twoDSyncState.setting(option, enabled: enabled)
        }
        twoDTool = .sync
    }

    public func setMPRAnnotationsVisible(_ visible: Bool) {
        isMPRAnnotationsVisible = visible
    }

    public func setMPRCrosshairVisible(_ visible: Bool) {
        isMPRCrosshairVisible = visible
    }

    public func applyMPRQuickWindowPreset(_ quickPreset: ClinicalViewerWindowQuickPreset) {
        let preset = quickPreset.windowLevelPreset
        let resolvedPreset = MPRWindowPreset.allCases.first { $0.quickPreset == quickPreset } ?? .other
        mprWindowPreset = resolvedPreset
        mprWindow = preset.window
        mprLevel = preset.level
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.applyMPRWindowPreset(resolvedPreset)
            self.syncMPRState(from: session)
        }
    }

    public func applyMPRWindowPreset(_ preset: MPRWindowPreset) {
        mprWindowPreset = preset
        if let quickPreset = preset.quickPreset {
            let windowPreset = quickPreset.windowLevelPreset
            mprWindow = windowPreset.window
            mprLevel = windowPreset.level
        } else if preset == .default, let range = defaultMPRWindowRange() {
            let window = WindowLevelShift(range: range)
            mprWindow = window.window
            mprLevel = window.level
        }
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.applyMPRWindowPreset(preset)
            self.syncMPRState(from: session)
        }
    }

    public func setMPRWindowLevel(window: Double, level: Double) {
        guard window.isFinite, level.isFinite else { return }
        mprWindowPreset = .other
        mprWindow = max(window, 1)
        mprLevel = level
        guard mode == .clinical else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = await self.sessionReady() else { return }
            await session.setMPRWindowLevel(window: window, level: level)
            self.syncMPRState(from: session)
        }
    }

    public func applyMPRCLUTPreset(_ preset: Volume3DCLUTPreset) {
        mprCLUTPreset = preset
        guard mode == .clinical else { return }
        clinicalViewportSession?.setMPRCLUTPreset(preset)
    }

    public func setMPRWindowInverted(_ inverted: Bool) {
        isMPRWindowInverted = inverted
        guard mode == .clinical else { return }
        clinicalViewportSession?.setMPRWindowInverted(inverted)
    }

    public func setVolumeOpacityScale(_ scale: Double) {
        guard scale.isFinite else { return }
        volumeOpacityScale = min(max(scale, 0.1), 2.0)
        reapplySingleViewportTransferFunction()
        if mode == .clinical, let session = clinicalViewportSession {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await session.setTransferFunction(self.transferFunction(for: self.transferPreset))
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func setAdaptiveSamplingEnabled(_ enabled: Bool) {
        adaptiveSamplingEnabled = enabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let volumeViewport = self.volumeViewport3D {
                await volumeViewport.setAdaptiveSampling(enabled)
            }
            if let session = self.clinicalViewportSession {
                await session.setAdaptiveSampling(enabled)
            }
        }
    }

    public func setVolumeRenderQualitySettings(_ settings: VolumeRenderQualitySettings) {
        let sanitized = settings.sanitized
        volumeRenderQualitySettings = sanitized
        volumeRenderQualitySettingsStore.saveVolumeRenderQualitySettings(sanitized)
        clearSnapshotMetrics()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let volumeViewport = self.volumeViewport3D {
                await volumeViewport.setVolumeRenderQualitySettings(sanitized)
            }
            if let session = self.clinicalViewportSession {
                await session.setVolumeRenderQualitySettings(sanitized)
            }
        }
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

    public func volume3DTransferFunction(for preset: ClinicalTransferFunctionPreset,
                                         opacityScale: Double? = nil) throws -> TransferFunction {
        volume3DCLUTPreset.transferFunction(
            basedOn: try transferFunction(for: preset, opacityScale: opacityScale)
        )
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
        case .stack2D:
            break
        }
        return true
    }

    public func applyPreset(_ newPreset: ClinicalTransferFunctionPreset) {
        clearSnapshotMetrics()
        let previousPreset = transferPreset
        let previousMethod = renderMethod
        transferPreset = newPreset
        renderMethod = VolumetricRenderMethod(renderMode: newPreset.renderingIntent.mode)
        volume3DWindowPreset = Volume3DWindowPreset.preset(for: newPreset)
        switch mode {
        case .single3D:
            guard let viewport = volumeViewport3D else {
                ensureVolumeViewport3D()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await viewport.applyTransferFunction(self.volume3DTransferFunction(for: newPreset))
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
                    try await session.applyTransferFunction(self.transferFunction(for: newPreset))
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                    if self.transferPreset == newPreset {
                        self.transferPreset = previousPreset
                        self.renderMethod = previousMethod
                    }
                }
            }
        case .stack2D:
            break
        }
    }

    public func applyVolume3DWindowPreset(_ preset: Volume3DWindowPreset) {
        clearSnapshotMetrics()
        volume3DWindowPreset = preset
        let newPreset = preset.clinicalTransferFunctionPreset
        let previousPreset = transferPreset
        let previousMethod = renderMethod
        transferPreset = newPreset
        renderMethod = VolumetricRenderMethod(renderMode: newPreset.renderingIntent.mode)
        guard mode == .single3D else { return }
        guard let viewport = volumeViewport3D else {
            ensureVolumeViewport3D()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await viewport.applyTransferFunction(self.volume3DTransferFunction(for: newPreset))
                await self.applyVolume3DWindowPresetWindow(preset, to: viewport)
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

    public func applyVolume3DCLUTPreset(_ preset: Volume3DCLUTPreset) {
        clearSnapshotMetrics()
        volume3DCLUTPreset = preset
        guard mode == .single3D, let viewport = volumeViewport3D else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await viewport.setTransferFunction(self.volume3DTransferFunction(for: self.transferPreset))
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func applyDataset(_ dataset: VolumeDataset) async throws {
        clearSnapshotMetrics()
        self.dataset = dataset
        publishTwoDROIAnnotations()
        resolveDefaultTwoDWindowLevelIfNeeded()
        resetCropClipState()
        resetVolumeBrushMaskState()
        if let volumeViewport3D {
            await volumeViewport3D.setPrimaryVolumeDatasetOverride(nil)
        }
        ensureActiveViewport()
        guard let viewport = await activeViewportReady() else {
            throw activeViewportUnavailableError()
        }
        try await applyDataset(dataset, to: viewport)
        try await applyCurrentConfiguration(to: viewport)
        errorMessage = nil
    }

    public func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler? = nil
    ) async throws where S.Element == VolumeUploadSlice {
        clearSnapshotMetrics()
        self.dataset = dataset
        publishTwoDROIAnnotations()
        resolveDefaultTwoDWindowLevelIfNeeded()
        resetCropClipState()
        resetVolumeBrushMaskState()
        if let volumeViewport3D {
            await volumeViewport3D.setPrimaryVolumeDatasetOverride(nil)
        }
        ensureActiveViewport()
        guard let viewport = await activeViewportReady() else {
            throw activeViewportUnavailableError()
        }
        try await applyVolumeUpload(referenceDataset: dataset,
                                    uploadDescriptor: uploadDescriptor,
                                    slices: slices,
                                    progress: progress,
                                    to: viewport)
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
        rtDoseOverlays = []
        currentRTDoseLayerIDs.removeAll()
        if let session = clinicalViewportSession {
            await session.setRTDoseOverlays([])
        }
        await setVolumeLayers([])
        await setSurfaceMeshLayers([])
    }

    public func setRTDoseOverlays(_ overlays: [RTDoseVolumeOverlay]) async {
        let previousDoseLayerIDs = currentRTDoseLayerIDs
        let newDoseLayerIDs = Set(overlays.map(\.volumeLayer.id))
        rtDoseOverlays = overlays
        currentRTDoseLayerIDs = newDoseLayerIDs
        currentVolumeLayers = currentVolumeLayers.filter { layer in
            !previousDoseLayerIDs.contains(layer.id) && !newDoseLayerIDs.contains(layer.id)
        } + overlays.map(\.volumeLayer)

        if let session = clinicalViewportSession {
            await session.setRTDoseOverlays(overlays)
        }
        guard let viewport = await activeViewportReady() else { return }
        await setVolumeLayers(currentVolumeLayers, on: viewport)
    }

    public func setRTDoseOverlayOpacity(id: String, opacity: Float) async {
        guard let index = rtDoseOverlays.firstIndex(where: { $0.id == id || $0.volumeLayer.id == id }) else {
            return
        }
        var overlays = rtDoseOverlays
        overlays[index] = overlays[index].settingOpacity(opacity)
        await setRTDoseOverlays(overlays)
    }

    public func setRTDoseColorLookupTable(id: String,
                                          colorLookupTable: RTDoseColorLookupTable) async {
        guard let index = rtDoseOverlays.firstIndex(where: { $0.id == id || $0.volumeLayer.id == id }) else {
            return
        }
        var overlays = rtDoseOverlays
        overlays[index] = overlays[index].settingColorLookupTable(colorLookupTable)
        await setRTDoseOverlays(overlays)
    }

    public func setRTStructureContourOverlays(_ overlays: [RTStructureContourOverlay]) {
        rtStructureContourOverlays = overlays
        clinicalViewportSession?.setRTStructureContourOverlays(overlays)
        publishTwoDROIAnnotations()
        syncMPRState(from: clinicalViewportSession)
    }

    public func setRTStructureContourConfiguration(_ configuration: RTStructureContourOverlayConfiguration) {
        rtStructureContourConfiguration = configuration
        clinicalViewportSession?.setRTStructureContourConfiguration(configuration)
        publishTwoDROIAnnotations()
        syncMPRState(from: clinicalViewportSession)
    }

    public func setRTStructureContourSliceTolerance(_ tolerance: Double) {
        var configuration = rtStructureContourConfiguration
        configuration.sliceToleranceMillimeters = tolerance.isFinite ? max(tolerance, 0) : 1
        setRTStructureContourConfiguration(configuration)
    }

    public func applyMPRPresentationState(_ presentationState: MPRPresentationState,
                                          to axis: MTKCore.Axis) async {
        mprPresentationStates[axis] = presentationState
        if let session = await sessionReady() {
            await session.applyMPRPresentationState(presentationState, to: axis)
            syncMPRState(from: session)
        }
    }

    public func clearMPRPresentationState(for axis: MTKCore.Axis) {
        mprPresentationStates.removeValue(forKey: axis)
        clinicalViewportSession?.clearMPRPresentationState(for: axis)
        syncMPRState(from: clinicalViewportSession)
    }

    public func applyStructuredReportViewerState(_ state: StructuredReportViewerState?) {
        structuredReportViewerState = state
        clinicalViewportSession?.applyStructuredReportViewerState(state)
    }

    public func selectStructuredReportFinding(id: CADFindingOverlayItem.ID?) {
        guard var state = structuredReportViewerState else { return }
        state.selectFinding(id: id)
        applyStructuredReportViewerState(state)
    }

    @discardableResult
    public func applyHangingProtocol(_ definition: HangingProtocolDefinition,
                                     context: HangingProtocolContext? = nil) async -> HangingProtocolResolvedLayout? {
        hangingProtocolDefinition = definition
        hangingProtocolContext = context
        guard let session = await sessionReady() else {
            hangingProtocolResolvedLayout = nil
            hangingProtocolSlotAssignments = []
            return nil
        }
        let resolved = await session.applyHangingProtocol(definition, context: context)
        hangingProtocolResolvedLayout = resolved
        hangingProtocolSlotAssignments = resolved?.viewports ?? []
        if let resolved {
            selectedMPRScreenLayout = resolved.screenLayout
        }
        syncMPRState(from: session)
        return resolved
    }

    public func clearHangingProtocol() {
        hangingProtocolDefinition = nil
        hangingProtocolContext = nil
        hangingProtocolResolvedLayout = nil
        hangingProtocolSlotAssignments = []
        clinicalViewportSession?.clearHangingProtocol()
        syncMPRState(from: clinicalViewportSession)
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
        resetCropClipState()
        reapplyCropClip()
    }

    public func setVolumeBrushEnabled(_ enabled: Bool) {
        volumeBrushState = volumeBrushState.settingEnabled(enabled)
        if enabled {
            interactionMode = .brush
        } else if interactionMode == .brush {
            interactionMode = .orbit
            volumeBrushCursor = nil
        }
    }

    public func setVolumeBrushSizeMM(_ size: Double) {
        volumeBrushState = volumeBrushState.settingBrushSizeMM(size)
    }

    public func adjustVolumeBrushSizeMM(by delta: Double) {
        volumeBrushState = volumeBrushState.adjustingBrushSizeMM(by: delta)
    }

    public func setVolumeBrushMode(_ mode: VolumeBrushMode) {
        volumeBrushState = volumeBrushState.settingMode(mode)
    }

    public func applyVolumeBrush(at screenPoint: CGPoint) {
        volumeBrushCursor = screenPoint
        guard mode == .single3D,
              volumeBrushState.isEnabled,
              let dataset,
              let viewport = volumeViewport3D else {
            return
        }

        do {
            let pick = try viewport.pickVolume(screenPoint: screenPoint,
                                              dataset: dataset)
            let result = try VolumeBrushMask.applyingStroke(
                to: dataset,
                existingMaskedData: volumeBrushMaskedDataset?.data,
                centerVoxel: pick.voxel.continuousIndex,
                brushSizeMM: volumeBrushState.brushSizeMM,
                mode: volumeBrushState.mode
            )
            volumeBrushMaskedDataset = result.dataset
            volumeBrushMaskHasEdits = true
            clearSnapshotMetrics()
            Task { @MainActor in
                await viewport.setPrimaryVolumeDatasetOverride(result.dataset)
            }
            errorMessage = nil
        } catch {
            guard !isNonFatalBrushPickError(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func endVolumeBrushStroke() {
        volumeBrushCursor = nil
    }

    public func resetVolumeBrushMask() {
        volumeBrushMaskedDataset = nil
        volumeBrushMaskHasEdits = false
        volumeBrushCursor = nil
        clearSnapshotMetrics()
        guard let volumeViewport3D else { return }
        Task { @MainActor in
            await volumeViewport3D.setPrimaryVolumeDatasetOverride(nil)
        }
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
        case .stack2D:
            throw ClinicalViewerCoordinatorError.viewportUnavailable("2D snapshot export is not available yet.")
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
        await viewport.setAdaptiveSampling(adaptiveSamplingEnabled)
        await viewport.setSamplingStep(single3DFinalSamplingStep)
        await viewport.setVolumeRenderQualitySettings(volumeRenderQualitySettings)
        await viewport.setPrimaryVolumeDatasetOverride(volumeBrushMaskedDataset)
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
        mprWindowPreset = session.mprWindowPreset
        mprCLUTPreset = session.mprCLUTPreset
        isMPRWindowInverted = session.isMPRWindowInverted
        mprROIKind = session.mprROIKind
        mprROIAnnotations = session.mprROIAnnotations
        mprSlabBlendMode = session.mprSlabBlendMode
        mprSlabThickness = session.slabThickness
        mprViewportTransforms = session.mprViewportTransforms
        rtDoseOverlays = session.rtDoseOverlays
        rtStructureContourOverlays = session.rtStructureContourOverlays
        rtStructureContourConfiguration = session.rtStructureContourConfiguration
        adaptiveSamplingEnabled = session.adaptiveSamplingEnabled
    }

    private func sync2DState(from viewport: StackViewport?) {
        guard let viewport else { return }
        twoDAxis = viewport.axis
        twoDResliceAxis = viewport.axis
        twoDSliceIndex = viewport.sliceIndex
        twoDSliceCount = viewport.sliceCount
        syncKeyImageSelectionForCurrentSlice()
        publishTwoDROIAnnotations()
    }

    private func syncKeyImageSelectionForCurrentSlice() {
        guard keyImageNavigationState.hasResolvedImages else { return }
        var next = keyImageNavigationState
        guard next.selectImage(containingSliceIndex: twoDSliceIndex) != nil else { return }
        keyImageNavigationState = next
    }

    private func currentTwoDNormalizedSlicePosition(default defaultValue: Float) -> Float {
        if twoDSliceCount > 1 {
            return min(max(Float(twoDSliceIndex) / Float(twoDSliceCount - 1), 0), 1)
        }
        if let position = stack2DViewport?.state.slice?.normalizedPosition, position.isFinite {
            return min(max(position, 0), 1)
        }
        return min(max(defaultValue, 0), 1)
    }

    private static func twoDSliceCount(for axis: MTKCore.Axis,
                                       in dataset: VolumeDataset?) -> Int {
        guard let dimensions = dataset?.dimensions else { return 0 }
        switch axis {
        case .axial:
            return dimensions.depth
        case .coronal:
            return dimensions.height
        case .sagittal:
            return dimensions.width
        }
    }

    private static func twoDSliceIndex(forNormalizedPosition position: Float,
                                       axis: MTKCore.Axis,
                                       dataset: VolumeDataset?) -> Int {
        let count = twoDSliceCount(for: axis, in: dataset)
        guard count > 1 else { return 0 }
        let normalized = min(max(position.isFinite ? position : 0.5, 0), 1)
        return Int((Float(count - 1) * normalized).rounded())
    }

    private static func supportsTwoDReslice(_ dataset: VolumeDataset) -> Bool {
        dataset.dimensions.width > 1
            && dataset.dimensions.height > 1
            && dataset.dimensions.depth > 1
    }

    private var currentTwoDSeriesIdentifier: String? {
        Self.twoDSeriesIdentifier(for: dataset)
    }

    private func publishTwoDROIAnnotations() {
        let manualAnnotations = twoDROIStore.annotations(axis: twoDAxis,
                                                         sliceIndex: twoDSliceIndex,
                                                         seriesIdentifier: currentTwoDSeriesIdentifier)
        let rtAnnotations: [ViewerROIAnnotation]
        if let dataset {
            rtAnnotations = RTStructureContourOverlayProjector.annotations(
                for: rtStructureContourOverlays,
                dataset: dataset,
                axis: twoDAxis,
                sliceIndex: twoDSliceIndex,
                configuration: rtStructureContourConfiguration
            )
        } else {
            rtAnnotations = []
        }
        twoDROIAnnotations = manualAnnotations + rtAnnotations
    }

    private func twoDMeasurement(kind: ViewerROIKind,
                                 axis: MTKCore.Axis,
                                 points: [CGPoint]) -> ViewerROIMeasurement? {
        ViewerROIMeasurementCalculator.measurement(kind: kind,
                                                   axis: axis,
                                                   normalizedImagePoints: points,
                                                   dimensions: dataset?.dimensions,
                                                   spacing: dataset?.spacing)
    }

    private static func twoDSeriesIdentifier(for dataset: VolumeDataset?) -> String? {
        guard let dataset else { return nil }
        if let seriesUID = dataset.imageData.clinicalMetadata?.seriesInstanceUID,
           !seriesUID.isEmpty {
            return seriesUID
        }
        return [
            "\(dataset.dimensions.width)x\(dataset.dimensions.height)x\(dataset.dimensions.depth)",
            "\(dataset.spacing.x),\(dataset.spacing.y),\(dataset.spacing.z)",
            "\(dataset.pixelFormat)",
            "\(dataset.data.count)"
        ].joined(separator: "|")
    }

    private func defaultMPRWindowRange() -> ClosedRange<Int32>? {
        guard let dataset else { return nil }
        return dataset.recommendedWindow ?? dataset.intensityRange
    }

    private func defaultTwoDWindowLevel() -> WindowLevelShift {
        guard let range = dataset?.recommendedWindow ?? dataset?.intensityRange else {
            return TwoDWindowLevelState.default.windowLevel
        }
        return WindowLevelShift(range: range)
    }

    private func resolveDefaultTwoDWindowLevelIfNeeded() {
        guard twoDWindowPreset == .default else { return }
        let resolved = defaultTwoDWindowLevel()
        twoDWindowLevelState = TwoDWindowLevelState(window: resolved.window,
                                                   level: resolved.level,
                                                   presetID: Volume3DWindowPreset.default.rawValue,
                                                   isInverted: twoDWindowLevelState.isInverted,
                                                   clut: twoDWindowLevelState.clut)
    }

    private func volumeViewportReady() async -> VolumeViewport3D? {
        if let viewport = volumeViewport3D {
            return viewport
        }
        ensureVolumeViewport3D()
        let viewport = await volumeViewport3DTask?.value
        return viewport ?? volumeViewport3D
    }

    private func stack2DReady() async -> StackViewport? {
        if let viewport = stack2DViewport {
            return viewport
        }
        ensureStack2DViewport()
        let viewport = await stack2DViewportTask?.value
        if let viewport {
            sync2DState(from: viewport)
        }
        return viewport ?? stack2DViewport
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
        case .stack2D:
            guard let viewport = await stack2DReady() else { return nil }
            return .stack2D(viewport)
        }
    }

    private func applyDataset(_ dataset: VolumeDataset,
                              to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            await volumeViewport.applyDataset(dataset)
        case .clinical(let session):
            try await session.applyDataset(dataset)
        case .stack2D(let viewport):
            await viewport.applyDataset(dataset)
            sync2DState(from: viewport)
        }
    }

    private func applyVolumeUpload<S: AsyncSequence>(
        referenceDataset dataset: VolumeDataset,
        uploadDescriptor: VolumeUploadDescriptor,
        slices: S,
        progress: VolumeUploadProgressHandler?,
        to viewport: ActiveClinicalViewerViewport
    ) async throws where S.Element == VolumeUploadSlice {
        switch viewport {
        case .single3D(let volumeViewport):
            try await volumeViewport.applyVolumeUpload(referenceDataset: dataset,
                                                       uploadDescriptor: uploadDescriptor,
                                                       slices: slices,
                                                       progress: progress)
        case .clinical(let session):
            try await session.applyVolumeUpload(referenceDataset: dataset,
                                                uploadDescriptor: uploadDescriptor,
                                                slices: slices,
                                                progress: progress)
        case .stack2D(let viewport):
            try await viewport.applyVolumeUpload(referenceDataset: dataset,
                                                 uploadDescriptor: uploadDescriptor,
                                                 slices: slices,
                                                 progress: progress)
            sync2DState(from: viewport)
        }
    }

    private func applyCurrentConfiguration(to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            try await applyCurrentConfiguration(to: volumeViewport)
        case .clinical(let session):
            try await applyCurrentConfiguration(to: session)
        case .stack2D(let viewport):
            await applyCurrentConfiguration(to: viewport)
        }
    }

    private func applyCurrentConfiguration(to viewport: StackViewport) async {
        let state = twoDWindowLevelState
        await viewport.setWindowLevel(window: state.window,
                                      level: state.level)
        viewport.setWindowPresentation(isInverted: state.isInverted,
                                       clut: state.clut)
        viewport.setViewportTransform(twoDTransform)
        sync2DState(from: viewport)
    }

    private func applyCurrentConfiguration(to session: ClinicalViewportSession) async throws {
        try await session.setVolumeViewportMode(renderMethod.clinicalViewportMode)
        try await session.setTransferFunction(transferFunction(for: transferPreset))
        try await applyCropClip(to: session)
        await session.setAdaptiveSampling(adaptiveSamplingEnabled)
        await session.setVolumeRenderQualitySettings(volumeRenderQualitySettings)
        await session.setMPRSlabBlendMode(mprSlabBlendMode)
        await session.setMPRSlabThickness(mprSlabThickness)
        session.setMPRROIKind(mprROIKind, activateTool: false)
        session.setMPRInteractionTool(mprInteractionTool)
        await session.setRTDoseOverlays(rtDoseOverlays)
        session.setRTStructureContourConfiguration(rtStructureContourConfiguration)
        session.setRTStructureContourOverlays(rtStructureContourOverlays)
        session.applyStructuredReportViewerState(structuredReportViewerState)
        session.setActiveMPRAxis(activeMPRAxis)
        session.setMPRCLUTPreset(mprCLUTPreset)
        session.setMPRWindowInverted(isMPRWindowInverted)
        if mprWindowPreset == .other {
            await session.setMPRWindowLevel(window: mprWindow, level: mprLevel)
        } else {
            await session.applyMPRWindowPreset(mprWindowPreset)
        }
        for (axis, presentationState) in mprPresentationStates {
            await session.applyMPRPresentationState(presentationState, to: axis)
        }
        if let hangingProtocolDefinition {
            let resolved = await session.applyHangingProtocol(hangingProtocolDefinition,
                                                              context: hangingProtocolContext)
            hangingProtocolResolvedLayout = resolved
            hangingProtocolSlotAssignments = resolved?.viewports ?? []
            if let resolved {
                selectedMPRScreenLayout = resolved.screenLayout
            }
        }
        syncMPRState(from: session)
    }

    private func applyCurrentConfiguration(to viewport: VolumeViewport3D) async throws {
        try await viewport.applyTransferFunction(volume3DTransferFunction(for: transferPreset))
        try await applyCropClip(to: viewport)
        await viewport.setVolumeRenderQualitySettings(volumeRenderQualitySettings)
        await applyVolume3DWindowPresetWindow(volume3DWindowPreset, to: viewport)
    }

    private func applyVolume3DWindowPresetWindow(_ preset: Volume3DWindowPreset,
                                                to viewport: VolumeViewport3D) async {
        if let windowPreset = preset.windowLevelPreset {
            await viewport.setWindowLevel(window: windowPreset.window,
                                          level: windowPreset.level)
        } else if let dataset {
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
                try await viewport.setTransferFunction(self.volume3DTransferFunction(for: self.transferPreset))
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
            guard self.dataset != nil ||
                    self.volumeViewport3D != nil ||
                    self.clinicalViewportSession != nil else {
                return
            }
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

    private func resetCropClipState() {
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
        clippingErrorMessage = nil
    }

    private func resetVolumeBrushMaskState() {
        volumeBrushState = VolumeBrushState()
        volumeBrushCursor = nil
        volumeBrushMaskedDataset = nil
        volumeBrushMaskHasEdits = false
    }

    private func isNonFatalBrushPickError(_ error: any Error) -> Bool {
        guard let pickError = error as? VolumePickError else {
            return false
        }
        switch pickError {
        case .screenPointOutsideViewport,
             .outsideImagedArea,
             .rayMissedVolume,
             .outsideVolume,
             .noVisibleSample:
            return true
        case .invalidViewport,
             .invalidViewportSize,
             .malformedData,
             .degenerateGeometry:
            return false
        }
    }

    private func applyCropClip(to viewport: ActiveClinicalViewerViewport) async throws {
        switch viewport {
        case .single3D(let volumeViewport):
            try await applyCropClip(to: volumeViewport)
        case .clinical(let session):
            try await applyCropClip(to: session)
        case .stack2D:
            clippingErrorMessage = nil
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
        case .stack2D(let viewport):
            await viewport.setVolumeLayers(layers)
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
        case .stack2D:
            break
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
        case .stack2D(let viewport):
            await viewport.setVolumeLayerVisibility(id: id, isVisible: isVisible)
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
        case .stack2D(let viewport):
            await viewport.setVolumeLayerOpacity(id: id, opacity: opacity)
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
        case .stack2D(let viewport):
            await viewport.setVolumeLayerBlendMode(id: id, blendMode: blendMode)
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
        case .stack2D:
            break
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
        case .stack2D:
            break
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
