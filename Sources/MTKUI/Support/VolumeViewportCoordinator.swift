//
//  VolumeViewportCoordinator.swift
//  MTKUI
//
//  Coordinator for volume viewport controller instances.
//  Manages the MTK-native controller pool for volume rendering and tri-planar MPR.
//  Thales Matheus Mendonça Santos — November 2025
//

import Combine
import Foundation
import Metal
import MTKCore

public enum VolumeViewportCoordinatorError: Error, LocalizedError {
    case metalUnavailable
    case unsupportedPlatform
    case controllerCreationFailed

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "VolumeViewportController requires a Metal device, but no system Metal device is available."
        case .unsupportedPlatform:
            return "VolumeViewportController is only available on iOS and macOS."
        case .controllerCreationFailed:
            return "Failed to create VolumeViewportController with the available Metal device."
        }
    }
}

/// Singleton coordinator managing volume viewport controller lifecycle and state synchronization.
///
/// `VolumeViewportCoordinator` provides centralized management of ``VolumeViewportController`` instances
/// for SwiftUI-based volumetric rendering applications. It handles controller pooling, dataset propagation,
/// and synchronized state updates across multiple rendering surfaces (volume + tri-planar MPR views).
///
/// ## Overview
///
/// The coordinator maintains separate controller instances for:
/// - **Volume rendering**: Primary 3D visualization with DVR/MIP/MinIP/AIP methods
/// - **MPR planes**: Three orthogonal slice views (axial, sagittal, coronal)
///
/// Controller instances are created lazily. A tri-planar-only consumer that requests
/// `controller(for: .z)`, `controller(for: .y)`, and `controller(for: .x)` creates only
/// those three MPR controllers. The volume controller is created only when ``controller``
/// is accessed, which keeps MPR-only workflows from provisioning a 3D render surface.
///
/// All controllers share synchronized dataset, transfer function, and HU window state, ensuring
/// consistent visualization across different views.
///
/// ## Usage
///
/// ### Basic Setup
///
/// ```swift
/// import MTKUI
///
/// struct VolumeViewer: View {
///     @StateObject private var coordinator = VolumeViewportCoordinator.shared
///
///     var body: some View {
///         if let controller = coordinator.controller {
///             VolumeViewportContainer(controller: controller) {
///                 OrientationOverlayView()
///                 CrosshairOverlayView()
///             }
///             .task {
///                 // Load and apply dataset
///                 let dataset = try await loadDicomVolume()
///                 coordinator.apply(dataset: dataset)
///
///                 // Configure window/level
///                 coordinator.applyHuWindow(min: -500, max: 1200)
///
///                 // Set transfer function preset
///                 await controller.setPreset(.softTissue)
///             }
///         } else {
///             Text("Metal unavailable")
///         }
///     }
/// }
/// ```
///
/// ### Tri-Planar MPR
///
/// ```swift
/// struct TriplanarMPRView: View {
///     @StateObject private var coordinator = VolumeViewportCoordinator.shared
///
///     var body: some View {
///         Group {
///             if let axialController = try? coordinator.controller(for: .z),
///                let coronalController = try? coordinator.controller(for: .y),
///                let sagittalController = try? coordinator.controller(for: .x) {
///                 TriplanarMPRComposer(
///                     axialController: axialController,
///                     coronalController: coronalController,
///                     sagittalController: sagittalController
///                 )
///             }
///         }
///         .task {
///             guard let axialController = try? coordinator.controller(for: .z),
///                   let coronalController = try? coordinator.controller(for: .y),
///                   let sagittalController = try? coordinator.controller(for: .x) else { return }
///
///             await axialController.applyDataset(volumeDataset)
///             await coronalController.applyDataset(volumeDataset)
///             await sagittalController.applyDataset(volumeDataset)
///
///             // Configure individual MPR planes
///             coordinator.configureMPRDisplay(
///                 axis: .z,
///                 blend: .mean,
///                 slab: VolumeViewportController.SlabConfiguration(
///                     thickness: 11,
///                     steps: 5
///                 ),
///                 normalizedPosition: 0.5
///             )
///         }
///     }
/// }
/// ```
///
/// - Note: The primary ``controller`` property creates the 3D volume-rendering controller.
///   Request it only when the UI includes a 3D pane, such as a ``MPRGridComposer`` layout.
///
/// ## State Synchronization
///
/// The coordinator automatically synchronizes:
/// - **Dataset**: Volume voxel data and geometry metadata
/// - **Transfer functions**: Color/opacity mapping for tissue visualization
/// - **HU window/level**: Medical imaging windowing parameters
/// - **MPR positions**: Slice plane positions along each axis
///
/// State updates propagate to all active controllers asynchronously. Use ``rendererState`` publisher
/// for observing consolidated rendering state in SwiftUI views.
///
/// ## Thread Safety
///
/// All public methods are marked `@MainActor` and must be called from the main thread.
/// The coordinator uses Combine publishers for reactive state updates in SwiftUI.
///
/// ## Performance Considerations
///
/// - Controllers are created lazily on first access and reused across view updates
/// - Dataset and transfer function state is cached to avoid redundant GPU uploads
/// - State propagation uses `Task` for async/await coordination without blocking the main thread
///
/// - Important: Always use the shared singleton instance (``shared``) for consistent state management across your app.
@MainActor
public final class VolumeViewportCoordinator: ObservableObject {

    /// Shared singleton coordinator instance.
    ///
    /// Use this instance across your app to ensure consistent volumetric rendering state.
    /// Multiple coordinators would create isolated controller pools with independent state.
    public static let shared = VolumeViewportCoordinator()

    /// Indicates whether Metal GPU rendering is available on this device.
    ///
    /// Set to `false` on systems without Metal support (e.g., some simulators or older hardware).
    /// When `false`, controllers enter an unsupported-capability state without GPU rendering.
    @Published public private(set) var isMetalAvailable: Bool

    private enum SurfaceKey: Hashable {
        case volume
        case mpr(VolumeViewportController.Axis)
    }

    private struct MprConfiguration {
        var blend: VolumetricMPRBlendMode
        var slab: VolumeViewportController.SlabConfiguration?
        var normalizedPosition: Float
    }

    private var controllers: [SurfaceKey: VolumeViewportController] = [:]
    private var controllerCancellables: [SurfaceKey: Set<AnyCancellable>] = [:]
    private var sharedMPRVolumeTextureCache = MPRVolumeTextureCache()
    private var pendingDataset: VolumeDataset?
    private var pendingTransferFunction: TransferFunction?
    private var pendingHuWindow: VolumetricHUWindowMapping?
    private var volumeConfiguration: VolumeViewportController.VolumeDisplayConfiguration = .method(.dvr)
    private var mprConfigurations: [VolumeViewportController.Axis: MprConfiguration] = [
        .x: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
        .y: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
        .z: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
    ]
    private let device: (any MTLDevice)?

    /// Testing-only surface identifiers for lazily instantiated controllers.
    ///
    /// - SPI: Testing
    /// - Returns: Active controller surface identifiers such as `"volume"`, `"mpr.x"`,
    ///   `"mpr.y"`, and `"mpr.z"`.
    @_spi(Testing)
    public var debugControllerSurfaceIdentifiers: [String] {
        controllers.keys.map { surface in
            switch surface {
            case .volume:
                return "volume"
            case let .mpr(axis):
                switch axis {
                case .x:
                    return "mpr.x"
                case .y:
                    return "mpr.y"
                case .z:
                    return "mpr.z"
                }
            }
        }
        .sorted()
    }

    /// Consolidated rendering state published for SwiftUI observation.
    ///
    /// Contains snapshots of:
    /// - Dataset metadata (dimensions, spacing, orientation)
    /// - Active HU window mapping
    /// - Transfer function reference
    /// - Normalized MPR positions for all three axes
    /// - Tone curve and clipping state
    ///
    /// Subscribe to this publisher in SwiftUI to reactively update UI based on rendering state:
    /// ```swift
    /// @StateObject var coordinator = VolumeViewportCoordinator.shared
    ///
    /// var body: some View {
    ///     Text("Dataset: \(coordinator.rendererState.dataset?.dimensions ?? .zero)")
    ///         .onChange(of: coordinator.rendererState.huWindow) { window in
    ///             // Update window/level UI controls
    ///         }
    /// }
    /// ```
    @Published public private(set) var rendererState = VolumetricRendererState(
        normalizedMprPositions: [
            VolumeViewportController.Axis.x: 0.5,
            VolumeViewportController.Axis.y: 0.5,
            VolumeViewportController.Axis.z: 0.5
        ]
    )

    private init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.device = metalDevice
            self.isMetalAvailable = true
        } else {
            self.device = nil
            self.isMetalAvailable = false
        }
    }

    /// Primary controller for volume rendering visualization.
    ///
    /// Returns the controller configured for 3D volume rendering (DVR/MIP/MinIP/AIP modes).
    /// Use this controller with ``VolumeViewportContainer`` for the main volumetric view.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let controller = coordinator.controller {
    ///     VolumeViewportContainer(controller: controller) {
    ///         OrientationOverlayView()
    ///     }
    /// }
    /// ```
    public var controller: VolumeViewportController? {
        try? controller(for: .volume)
    }

    /// Renders the current 3D volume viewport into a GPU-native frame for explicit export.
    ///
    /// This does not participate in the interactive display loop and does not
    /// create a `CGImage`; callers should pass the returned texture frame to
    /// `TextureSnapshotExporter` only when the user requests snapshot/export.
    public func renderVolumeSnapshotFrame() async throws -> VolumeRenderFrame {
        let controller = try controller(for: .volume)
        return try await controller.renderVolumeSnapshotFrame()
    }

    /// Returns the controller for a specific MPR axis (axial, sagittal, or coronal).
    ///
    /// Controllers are created lazily on first access and reused across subsequent calls.
    /// Each axis maintains independent camera state but shares dataset and transfer function with other controllers.
    ///
    /// - Parameter axis: The anatomical axis for MPR slicing (`.x` = sagittal, `.y` = coronal, `.z` = axial).
    /// - Returns: Controller configured for MPR rendering along the specified axis.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let axialController = try coordinator.controller(for: .z)
    /// let sagittalController = try coordinator.controller(for: .x)
    /// let coronalController = try coordinator.controller(for: .y)
    /// ```
    public func controller(for axis: VolumeViewportController.Axis) throws -> VolumeViewportController {
        try controller(for: .mpr(axis))
    }

    /// Resets coordinator state and clears all cached controllers.
    ///
    /// Use this method for:
    /// - Unit testing cleanup between tests
    /// - Clearing application state when closing a volume
    /// - Forcing controller recreation after major configuration changes
    ///
    /// All pending dataset, transfer function, and HU window state is discarded.
    /// Controllers are deallocated and will be recreated on next access.
    ///
    /// - Important: This is a destructive operation. Active rendering views may become invalid.
    ///   Ensure views are deallocated or will re-request controllers after reset.
    public func reset() {
        controllers.removeAll()
        controllerCancellables.removeAll()
        sharedMPRVolumeTextureCache.invalidate()
        pendingDataset = nil
        pendingTransferFunction = nil
        pendingHuWindow = nil
        volumeConfiguration = .method(.dvr)
        mprConfigurations = [
            .x: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
            .y: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5),
            .z: MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
        ]
        updateRendererState { state in
            state.dataset = nil
            state.huWindow = nil
            state.transferFunction = nil
            state.normalizedMprPositions = [
                .x: 0.5,
                .y: 0.5,
                .z: 0.5
            ]
        }
    }

    /// Applies a volume dataset to all managed controllers.
    ///
    /// Propagates the dataset to all currently instantiated controllers (volume + MPR planes)
    /// and caches it for future controller creation. Updates ``rendererState`` with dataset metadata.
    ///
    /// Controllers apply the dataset asynchronously using their GPU command queues.
    /// This method returns immediately; dataset upload happens in the background.
    ///
    /// - Parameter dataset: Volume dataset containing voxel data, dimensions, spacing, and orientation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let dataset = VolumeDataset(
    ///     data: voxelData,
    ///     dimensions: VolumeDimensions(width: 512, height: 512, depth: 300),
    ///     spacing: VolumeSpacing(x: 0.001, y: 0.001, z: 0.0015),
    ///     pixelFormat: .int16Signed,
    ///     intensityRange: (-1024)...3071
    /// )
    /// coordinator.apply(dataset: dataset)
    /// ```
    ///
    /// - Note: If Metal is unavailable (``isMetalAvailable`` is `false`), this method surfaces
    ///   no-op behavior for the unsupported-capability state; callers should gate on
    ///   ``isMetalAvailable`` before applying datasets.
    public func apply(dataset: VolumeDataset) {
        guard isMetalAvailable else { return }
        pendingDataset = dataset
        sharedMPRVolumeTextureCache.invalidate()
        updateRendererState { state in
            state.dataset = VolumetricRendererState.DatasetSummary(
                dimensions: dataset.dimensions,
                spacing: dataset.spacing,
                intensityRange: dataset.intensityRange,
                orientation: dataset.orientation
            )
        }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Applies a transfer function to all managed controllers.
    ///
    /// Transfer functions define color and opacity mappings from voxel intensity to RGBA values.
    /// This method synchronizes the transfer function across volume and MPR controllers, ensuring
    /// consistent visualization.
    ///
    /// - Parameter transferFunction: Transfer function to apply, or `nil` to clear current mapping.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Apply preset transfer function via controller
    /// if let controller = coordinator.controller {
    ///     await controller.setPreset(.softTissue)
    /// }
    ///
    /// // Or load custom transfer function
    /// let customTF = try TransferFunction(fileURL: tfURL)
    /// coordinator.apply(transferFunction: customTF)
    ///
    /// // Clear transfer function (uses the default grayscale mapping)
    /// coordinator.apply(transferFunction: nil)
    /// ```
    ///
    /// - Note: Transfer function state is cached and applied to controllers created after this call.
    public func apply(transferFunction: TransferFunction?) {
        guard isMetalAvailable else { return }
        pendingTransferFunction = transferFunction
        updateRendererState { $0.transferFunction = transferFunction }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Applies HU (Hounsfield Unit) window/level to all managed controllers.
    ///
    /// Window/level controls are fundamental to medical image visualization, mapping a subset
    /// of the intensity range to display brightness. This method synchronizes windowing across
    /// all rendering surfaces.
    ///
    /// - Parameters:
    ///   - min: Minimum HU value (lower bound of visible intensity range).
    ///   - max: Maximum HU value (upper bound of visible intensity range).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Soft tissue window (common CT preset)
    /// coordinator.applyHuWindow(min: -500, max: 1200)
    ///
    /// // Bone window
    /// coordinator.applyHuWindow(min: -200, max: 2000)
    ///
    /// // Lung window
    /// coordinator.applyHuWindow(min: -1500, max: -400)
    /// ```
    ///
    /// The window/level mapping is automatically converted to normalized transfer function coordinates
    /// using the dataset's intensity range. Updates ``rendererState/huWindow``.
    ///
    /// - Note: HU windowing only affects visualization; the underlying voxel data is unchanged.
    public func applyHuWindow(min: Int32, max: Int32) {
        guard isMetalAvailable else { return }
        let mapping = makeHuMapping(min: min, max: max)
        pendingHuWindow = mapping
        updateRendererState { $0.huWindow = mapping }
        controllers.forEach { surface, controller in
            Task { await propagateState(to: controller, surface: surface) }
        }
    }

    /// Configures the primary volume controller's display mode.
    ///
    /// Sets rendering method for the volume controller (accessed via ``controller``).
    /// Configuration is cached and applied when the volume controller is created or recreated.
    ///
    /// - Parameter configuration: Display configuration for the primary 3D volume viewport.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Direct Volume Rendering (DVR)
    /// coordinator.configureVolumeDisplay(.method(.dvr))
    ///
    /// // Maximum Intensity Projection (MIP)
    /// coordinator.configureVolumeDisplay(.method(.mip))
    ///
    /// // Average Intensity Projection (AIP)
    /// coordinator.configureVolumeDisplay(.method(.avg))
    /// ```
    ///
    /// - Note: Typically you use this method to switch between volume rendering methods (DVR/MIP/MinIP/AIP).
    ///   For MPR visualization, use ``controller(for:)`` to access dedicated MPR controllers.
    public func configureVolumeDisplay(_ configuration: VolumeViewportController.VolumeDisplayConfiguration) {
        guard isMetalAvailable else { return }
        volumeConfiguration = configuration
        if let controller = controllers[.volume] {
            Task { await propagateState(to: controller, surface: .volume) }
        }
    }

    /// Configures MPR display settings for a specific anatomical axis.
    ///
    /// Sets blend mode, slab thickness, and initial slice position for an MPR controller.
    /// Configuration is cached and applied when the MPR controller is accessed.
    ///
    /// - Parameters:
    ///   - axis: Anatomical axis for MPR slicing (`.x` = sagittal, `.y` = coronal, `.z` = axial).
    ///   - blend: Blend mode for multi-slice rendering (default: `.single` for sharp slices).
    ///   - slab: Optional thick-slab configuration for noise reduction (default: `nil` for single slice).
    ///   - normalizedPosition: Initial slice position along axis, range 0...1 (default: 0.5 for center).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Single-slice axial MPR at center
    /// coordinator.configureMPRDisplay(
    ///     axis: .z,
    ///     blend: .single,
    ///     slab: nil,
    ///     normalizedPosition: 0.5
    /// )
    ///
    /// // Thick-slab coronal MPR with averaging (noise reduction)
    /// coordinator.configureMPRDisplay(
    ///     axis: .y,
    ///     blend: .mean,
    ///     slab: VolumeViewportController.SlabConfiguration(
    ///         thickness: 11,  // 11 voxel thickness
    ///         steps: 5        // 5 sampling steps
    ///     ),
    ///     normalizedPosition: 0.3
    /// )
    /// ```
    ///
    /// Normalized position is automatically clamped to [0, 1]. Updates ``rendererState/normalizedMprPositions``.
    public func configureMPRDisplay(axis: VolumeViewportController.Axis,
                                    blend: VolumetricMPRBlendMode = .single,
                                    slab: VolumeViewportController.SlabConfiguration? = nil,
                                    normalizedPosition: Float = 0.5) {
        guard isMetalAvailable else { return }
        let clamped = VolumetricMath.clampFloat(normalizedPosition, lower: 0, upper: 1)
        mprConfigurations[axis] = MprConfiguration(blend: blend,
                                                   slab: slab,
                                                   normalizedPosition: clamped)
        updateRendererState { $0.normalizedMprPositions[axis] = clamped }
        if let controller = controllers[.mpr(axis)] {
            Task { await propagateState(to: controller, surface: .mpr(axis)) }
        }
    }

    /// Updates MPR slice position along a specific axis.
    ///
    /// Immediately updates the slice plane position for the MPR controller on the specified axis.
    /// This method provides real-time slice scrolling without reconfiguring blend mode or slab settings.
    ///
    /// - Parameters:
    ///   - axis: Anatomical axis to update (`.x` = sagittal, `.y` = coronal, `.z` = axial).
    ///   - normalizedPosition: Slice position along axis, range 0...1 (0 = start, 1 = end).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Scroll axial slice to 75% through volume
    /// coordinator.setMprPlane(axis: .z, normalizedPosition: 0.75)
    ///
    /// // Jump to first sagittal slice
    /// coordinator.setMprPlane(axis: .x, normalizedPosition: 0.0)
    ///
    /// // Interactive scrolling with gesture
    /// @GestureState var sliceOffset: Float = 0
    ///
    /// var body: some View {
    ///     MPRPanelView(controller: coordinator.controller(for: .z))
    ///         .gesture(
    ///             DragGesture()
    ///                 .updating($sliceOffset) { value, state, _ in
    ///                     let delta = Float(value.translation.height) / 500
    ///                     let newPosition = clamp(0.5 + delta, 0, 1)
    ///                     coordinator.setMprPlane(axis: .z, normalizedPosition: newPosition)
    ///                 }
    ///         )
    /// }
    /// ```
    ///
    /// Normalized position is automatically clamped to [0, 1].
    /// The method updates the cached configuration and notifies the active controller if instantiated.
    public func setMprPlane(axis: VolumeViewportController.Axis, normalizedPosition: Float) {
        guard isMetalAvailable else { return }
        let clamped = VolumetricMath.clampFloat(normalizedPosition, lower: 0, upper: 1)
        if var config = mprConfigurations[axis] {
            config.normalizedPosition = clamped
            mprConfigurations[axis] = config
            updateRendererState { $0.normalizedMprPositions[axis] = clamped }
            if let controller = controllers[.mpr(axis)] {
                Task {
                    await controller.setMprPlane(axis: axis, normalized: clamped)
                }
            }
        }
    }

    private func controller(for surface: SurfaceKey) throws -> VolumeViewportController {
        guard isMetalAvailable else {
            throw VolumeViewportCoordinatorError.metalUnavailable
        }

        if let existing = controllers[surface] {
            return existing
        }

        let newController: VolumeViewportController
#if os(iOS) || os(macOS)
        guard let device else {
            throw VolumeViewportCoordinatorError.metalUnavailable
        }
        do {
            newController = try VolumeViewportController(
                device: device,
                mprVolumeTextureCache: sharedMPRVolumeTextureCache
            )
        } catch {
            throw VolumeViewportCoordinatorError.controllerCreationFailed
        }
#else
        throw VolumeViewportCoordinatorError.unsupportedPlatform
#endif

        controllers[surface] = newController
        attachObservers(to: newController, surface: surface)

        Task { await propagateState(to: newController, surface: surface) }

        return newController
    }

    private func makeHuMapping(min: Int32, max: Int32) -> VolumetricHUWindowMapping {
        if let dataset = pendingDataset {
            return VolumetricHUWindowMapping.makeHuWindowMapping(minHU: min,
                                                                 maxHU: max,
                                                                 datasetRange: dataset.intensityRange,
                                                                 transferDomain: nil)
        }
        return VolumetricHUWindowMapping(minHU: min, maxHU: max, tfMin: 0, tfMax: 1)
    }

    private func propagateState(to controller: VolumeViewportController,
                                surface: SurfaceKey) async {
        if let dataset = pendingDataset {
            await controller.applyDataset(dataset)
        }
        if let transfer = pendingTransferFunction {
            try? await controller.setTransferFunction(transfer)
        }
        if let window = pendingHuWindow {
            await controller.setHuWindow(window)
            await controller.setMprHuWindow(min: window.minHU, max: window.maxHU)
        }

        switch surface {
        case .volume:
            await controller.setDisplayConfiguration(volumeConfiguration.displayConfiguration)
        case let .mpr(axis):
            let config = mprConfigurations[axis] ?? MprConfiguration(blend: .single, slab: nil, normalizedPosition: 0.5)
            let index = makeMprIndex(axis: axis, normalized: config.normalizedPosition)
            await controller.setDisplayConfiguration(.mpr(axis: axis,
                                                          index: index,
                                                          blend: config.blend,
                                                          slab: config.slab))
            await controller.setMprPlane(axis: axis, normalized: config.normalizedPosition)
        }
    }

    private func makeMprIndex(axis: VolumeViewportController.Axis, normalized: Float) -> Int {
        guard let dataset = pendingDataset else { return 0 }
        let dimensions = dataset.dimensions
        let voxelCount: Int
        switch axis {
        case .x:
            voxelCount = max(Int(dimensions.width) - 1, 0)
        case .y:
            voxelCount = max(Int(dimensions.height) - 1, 0)
        case .z:
            voxelCount = max(Int(dimensions.depth) - 1, 0)
        }
        return Int(round(normalized * Float(voxelCount)))
    }

    private func attachObservers(to controller: VolumeViewportController,
                                 surface: SurfaceKey) {
        var cancellables = Set<AnyCancellable>()

        if case .volume = surface {
            controller.statePublisher.$windowLevelState
                .sink { [weak self] state in
                    guard let self else { return }
                    let minHU = Int32((state.level - state.window / 2).rounded())
                    let maxHU = Int32((state.level + state.window / 2).rounded())
                    let datasetRange = self.pendingDataset?.intensityRange ??
                        self.rendererState.dataset?.intensityRange ??
                        (-1024...3071)
                    let mapping = VolumetricHUWindowMapping.makeHuWindowMapping(
                        minHU: minHU,
                        maxHU: maxHU,
                        datasetRange: datasetRange,
                        transferDomain: nil
                    )
                    self.pendingHuWindow = mapping
                    updateRendererState { renderer in
                        renderer.huWindow = mapping
                    }
                }
                .store(in: &cancellables)
        }

        if case let .mpr(axis) = surface {
            controller.statePublisher.$sliceState
                .sink { [weak self] slice in
                    guard let self else { return }
                    updateRendererState { state in
                        state.normalizedMprPositions[axis] = slice.normalizedPosition
                    }
                }
                .store(in: &cancellables)
        }

        controllerCancellables[surface] = cancellables
    }

    private func updateRendererState(_ update: (inout VolumetricRendererState) -> Void) {
        var snapshot = rendererState
        update(&snapshot)
        rendererState = snapshot
    }

    /// Returns a snapshot of current renderer state.
    ///
    /// Provides immutable copy of rendering state including dataset metadata, HU window,
    /// transfer function, MPR positions, tone curves, and clipping configuration.
    ///
    /// - Returns: Current renderer state snapshot.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let snapshot = coordinator.rendererStateSnapshot()
    /// print("Dataset dimensions: \(snapshot.dataset?.dimensions ?? .zero)")
    /// print("HU window: \(snapshot.huWindow?.minHU ?? 0)...\(snapshot.huWindow?.maxHU ?? 0)")
    /// print("Axial position: \(snapshot.normalizedMprPositions[.z] ?? 0.5)")
    /// ```
    ///
    /// - Note: This is a value-type snapshot. Subsequent state changes won't affect the returned copy.
    ///   Use the ``rendererState`` publisher for reactive observation.
    public func rendererStateSnapshot() -> VolumetricRendererState {
        rendererState
    }

    /// Updates tone curve configuration for advanced transfer function editing.
    ///
    /// Tone curves provide fine-grained control over color/opacity mapping beyond preset transfer functions.
    /// Multiple curves can target different tissue types or intensity ranges.
    ///
    /// - Parameter snapshots: Array of tone curve configurations to apply.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let boneCurve = VolumetricRendererState.ToneCurveSnapshot(
    ///     identifier: "bone",
    ///     controlPoints: [(0.6, 0.0), (0.8, 0.5), (1.0, 1.0)],
    ///     colorRamp: .grayscale
    /// )
    /// coordinator.updateToneCurves([boneCurve])
    /// ```
    ///
    /// - Note: Tone curves are applied on top of the base transfer function.
    ///   Clear curves by passing empty array: `coordinator.updateToneCurves([])`.
    public func updateToneCurves(_ snapshots: [VolumetricRendererState.ToneCurveSnapshot]) {
        updateRendererState { $0.toneCurves = snapshots }
    }

    /// Updates clipping configuration for volume and plane clipping.
    ///
    /// Clipping controls visibility of voxels based on spatial bounds or arbitrary plane equations.
    /// Use for cropping volumes, creating cutaway views, or focusing on regions of interest.
    ///
    /// - Parameters:
    ///   - bounds: Optional axis-aligned bounding box clip (nil to disable bounds clipping).
    ///   - plane: Optional arbitrary plane clip (nil to disable plane clipping).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Clip to central 50% of volume in all dimensions
    /// let bounds = ClipBoundsSnapshot(
    ///     minX: 0.25, maxX: 0.75,
    ///     minY: 0.25, maxY: 0.75,
    ///     minZ: 0.25, maxZ: 0.75
    /// )
    /// coordinator.updateClipState(bounds: bounds, plane: nil)
    ///
    /// // Clear all clipping
    /// coordinator.updateClipState(bounds: nil, plane: nil)
    ///
    /// // Plane-based clip (e.g., axial plane at Z=0.5)
    /// let plane = ClipPlaneSnapshot(
    ///     normal: SIMD3<Float>(0, 0, 1),
    ///     distance: 0.5
    /// )
    /// coordinator.updateClipState(bounds: nil, plane: plane)
    /// ```
    ///
    /// - Note: Both bounds and plane clipping can be active simultaneously (intersection of constraints).
    public func updateClipState(bounds: ClipBoundsSnapshot?, plane: ClipPlaneSnapshot?) {
        updateRendererState {
            $0.clipBounds = bounds
            $0.clipPlane = plane
        }
    }

}
