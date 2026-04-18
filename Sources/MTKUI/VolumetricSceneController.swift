//
//  VolumetricSceneController.swift
//  MetalVolumetrics
//
//  Scene controller that orchestrates volumetric rendering.
//  Coordinates Metal materials, dataset application, and exposes an async API to
//  the presentation layer for both volume and MPR displays.
//
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation

#if os(iOS) || os(macOS)
import SceneKit
import simd
import Combine
@_spi(Internal) import MTKCore
import MTKSceneKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif

/// SceneKit-surface controller for Metal-backed volumetric rendering coordination.
///
/// `VolumetricSceneController` orchestrates Metal-backed volume rendering and Multi-Planar Reconstruction (MPR)
/// visualization through a SceneKit presentation surface. It manages SceneKit scene graphs, SceneKit materials
/// backed by Metal shaders, camera controllers, and rendering state for medical imaging applications.
///
/// ## Overview
///
/// The controller provides:
/// - Direct Volume Rendering (DVR) with transfer function control
/// - Maximum/Minimum/Average Intensity Projection (MIP/MinIP/AIP)
/// - Multi-Planar Reconstruction (MPR) with slab rendering
/// - Interactive camera control with gesture support
/// - Real-time window/level adjustment for medical imaging
///
/// ## Usage
///
/// ```swift
/// // Create controller with Metal device
/// let controller = try VolumetricSceneController()
///
/// // Apply DICOM volume dataset
/// await controller.applyDataset(volumeDataset)
///
/// // Configure transfer function and window/level
/// try await controller.setPreset(.softTissue)
/// await controller.setHuWindow(
///     VolumeCubeMaterial.makeHuWindowMapping(
///         minHU: -500, maxHU: 1200,
///         datasetRange: dataset.intensityRange,
///         transferDomain: nil
///     )
/// )
///
/// // Switch rendering methods
/// await controller.setVolumeMethod(.dvr)  // Direct volume rendering
/// await controller.setVolumeMethod(.mip)  // Maximum intensity projection
///
/// // Configure MPR display
/// await controller.setDisplayConfiguration(.mpr(
///     axis: .z,
///     index: 128,
///     blend: .single,
///     slab: nil
/// ))
/// ```
///
/// ## Camera Control
///
/// Camera manipulation is exposed through async methods:
/// - ``rotateCamera(screenDelta:)`` — Orbit camera around volume
/// - ``panCamera(screenDelta:)`` — Pan camera in screen space
/// - ``dollyCamera(delta:)`` — Zoom in/out
/// - ``resetCamera()`` — Restore default view
///
/// Camera state is published via ``statePublisher`` for SwiftUI observation.
///
/// ## Thread Safety
///
/// All public API methods are marked `@MainActor` and must be called from the main thread.
/// The controller uses async/await for coordination with Metal command queues.
///
/// - Important: Always create and interact with the controller on the main actor/thread.
@MainActor
public final class VolumetricSceneController: VolumetricSceneControlling, ObservableObject {

    /// Errors that can occur during controller initialization or operation.
    public enum Error: Swift.Error {
        /// Metal device could not be created or is unavailable on this system.
        case metalUnavailable

        /// Requested transfer function could not be loaded or applied.
        case transferFunctionUnavailable
    }

    /// Anatomical axis for MPR slicing and volume orientation.
    ///
    /// Maps to standard medical imaging orientations:
    /// - `x`: Sagittal plane (left-right)
    /// - `y`: Coronal plane (anterior-posterior)
    /// - `z`: Axial/transverse plane (superior-inferior)
    public enum Axis: Int {
        /// X-axis (sagittal plane, left-right direction).
        case x = 0

        /// Y-axis (coronal plane, anterior-posterior direction).
        case y = 1

        /// Z-axis (axial plane, superior-inferior direction).
        case z = 2
    }

    /// Configuration for thick-slab MPR rendering.
    ///
    /// Slab rendering averages or blends multiple slices to reduce noise and improve visualization.
    /// Both `thickness` and `steps` are automatically normalized to odd voxel counts for symmetric sampling.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let slabConfig = SlabConfiguration(thickness: 10, steps: 5)
    /// // Normalized to: thickness=11, steps=5 (both odd)
    /// ```
    public struct SlabConfiguration: Equatable {
        /// Slab thickness in voxels (automatically normalized to odd count).
        public var thickness: Int

        /// Number of sampling steps within slab (automatically normalized to odd count).
        public var steps: Int

        /// Creates a slab configuration with automatic normalization to odd voxel counts.
        /// - Parameters:
        ///   - thickness: Desired slab thickness in voxels (will be normalized to nearest odd value).
        ///   - steps: Desired sampling steps (will be normalized to nearest odd value, minimum 1).
        public init(thickness: Int, steps: Int) {
            let normalizedThickness = Self.snapToOddVoxelCount(thickness)
            let normalizedSteps = Self.snapToOddVoxelCount(max(1, steps))
            self.thickness = normalizedThickness
            self.steps = normalizedSteps
        }

        /// Normalizes a value to the nearest odd integer.
        ///
        /// Odd voxel counts ensure symmetric sampling around the central slice plane.
        /// - Parameter value: Value to normalize (must be positive).
        /// - Returns: Nearest odd integer, or 0 if input is non-positive.
        public static func snapToOddVoxelCount(_ value: Int) -> Int {
            guard value > 0 else { return 0 }
            var clamped = value
            if clamped % 2 == 0 {
                if clamped == Int.max {
                    clamped = max(1, clamped - 1)
                } else {
                    clamped += 1
                }
            }
            return max(1, clamped)
        }
    }

    /// Display configuration controlling rendering mode (volume vs. MPR).
    ///
    /// Use ``setDisplayConfiguration(_:)`` to switch between volume rendering and MPR modes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Volume rendering with Direct Volume Rendering
    /// await controller.setDisplayConfiguration(.volume(method: .dvr))
    ///
    /// // MPR axial slice with slab averaging
    /// let slab = SlabConfiguration(thickness: 10, steps: 5)
    /// await controller.setDisplayConfiguration(.mpr(
    ///     axis: .z,
    ///     index: 128,
    ///     blend: .average,
    ///     slab: slab
    /// ))
    /// ```
    public enum DisplayConfiguration: Equatable {
        /// Volume rendering mode with specified method (DVR, MIP, MinIP, or AIP).
        case volume(method: VolumeCubeMaterial.Method)

        /// Multi-planar reconstruction mode.
        /// - Parameters:
        ///   - axis: Anatomical axis for slicing (x, y, or z).
        ///   - index: Zero-based slice index along the axis.
        ///   - blend: Blend mode for slab rendering (single slice or averaging).
        ///   - slab: Optional slab configuration for thick-slice rendering.
        case mpr(axis: Axis, index: Int, blend: MPRPlaneMaterial.BlendMode, slab: SlabConfiguration?)
    }

    /// Known performance hotspots with optimization suggestions.
    ///
    /// These hotspots identify areas where additional Metal-based preprocessing or analysis could
    /// reduce CPU work or improve profiling visibility during development.
    public static let manualHotspots: [VolumetricHotspot] = [
        VolumetricHotspot(
            identifier: "volume_ray_march",
            description: "Fragment shader `direct_volume_rendering` performs per-fragment ray marching with manual empty-space skipping",
            suggestion: "Prototype a dedicated Metal compute pass to evaluate accumulation and early-out heuristics outside the fragment stage."
        ),
        VolumetricHotspot(
            identifier: "mpr_resample",
            description: "MPR material relies on CPU-generated slab textures prior to binding to SceneKit",
            suggestion: "Leverage a dedicated Metal resampling workflow to rebuild slabs directly on the GPU."
        ),
        VolumetricHotspot(
            identifier: "histogram_wwl",
            description: "Window/level suggestions derived from CPU statistics before calling into the shader pipeline",
            suggestion: "Use a Metal histogram workflow to derive HU statistics alongside transfer-function preparation."
        )
    ]

    // MARK: - Rendering Surfaces

    /// SceneKit-based rendering surface (always available).
    public let sceneSurface: SceneKitSurface

    /// Presentation surface for volumetric content.
    public var surface: any RenderSurface { sceneSurface }

    /// SceneKit view hosting the 3D scene graph.
    ///
    /// This view is the primary rendering output for SceneKit-based rendering mode.
    /// Embed this view in your SwiftUI hierarchy using ``VolumetricDisplayContainer``.
    public let sceneView: SCNView

    // MARK: - Scene Graph

    /// SceneKit scene containing volume and MPR geometry.
    public let scene: SCNScene

    /// Root node of the SceneKit scene hierarchy.
    public let rootNode: SCNNode

    /// Metal device used for GPU rendering and compute operations.
    public let device: any MTLDevice

    /// Metal command queue for submitting rendering work.
    public let commandQueue: any MTLCommandQueue

    // MARK: - Volume Rendering

    /// SceneKit node containing the volume cube geometry.
    ///
    /// Hidden when MPR mode is active, visible during volume rendering.
    public let volumeNode: SCNNode

    /// Metal material driving volume rendering shaders.
    ///
    /// Encapsulates transfer functions, window/level mappings, and volume texture state.
    public let volumeMaterial: VolumeCubeMaterial

    // MARK: - MPR Rendering

    /// SceneKit node containing the MPR plane geometry.
    ///
    /// Hidden when volume mode is active, visible during MPR rendering.
    public let mprNode: SCNNode

    /// Metal material driving MPR slice shaders.
    ///
    /// Manages slice plane orientation, slab blending, and HU windowing for planar views.
    public let mprMaterial: MPRPlaneMaterial

    // MARK: - State Management

    /// Publisher for camera, slice, and window/level state changes.
    ///
    /// Subscribe to state updates for SwiftUI integration:
    /// ```swift
    /// controller.statePublisher.$cameraState
    ///     .sink { newCameraState in
    ///         // Update UI based on camera position
    ///     }
    /// ```
    public let statePublisher = VolumetricStatePublisher()

    /// Controller managing camera position, orientation, and interaction.
    let cameraController: VolumetricCameraController

    /// Helper managing volume cube geometry and world transforms.
    let volumeGeometry: VolumetricVolumeGeometry

    /// Controller coordinating MPR plane positioning and slab rendering.
    let mprController: VolumetricMPRController

    // MARK: - Published State

    /// Current camera position, target, and projection type.
    ///
    /// Reflects real-time camera state published by ``statePublisher``.
    public var cameraState: VolumetricCameraState {
        statePublisher.cameraState
    }

    /// Current MPR slice axis and normalized position (0...1).
    ///
    /// Updated when calling ``setMprPlane(axis:normalized:)`` or via gesture interactions.
    public var sliceState: VolumetricSliceState {
        statePublisher.sliceState
    }

    /// Current HU window and level for medical imaging display.
    ///
    /// Window is the range width, level is the center value.
    /// Updated via ``setHuWindow(_:)`` or interactive window/level controls.
    public var windowLevelState: VolumetricWindowLevelState {
        statePublisher.windowLevelState
    }

    /// Whether adaptive sampling is currently enabled.
    ///
    /// Adaptive sampling reduces ray marching steps during camera interaction for improved responsiveness.
    public var adaptiveSamplingEnabled: Bool {
        statePublisher.adaptiveSamplingEnabled
    }

    // MARK: - Internal State

    let logger = Logger(category: "Volumetric.SceneController")

    var dataset: VolumeDataset?

    /// Indicates whether a dataset has been successfully applied.
    ///
    /// Set to `true` after ``applyDataset(_:)`` completes without error.
    public var datasetApplied = false
    var geometry: DICOMGeometry?
    var currentDisplay: DisplayConfiguration?
    var transferFunction: TransferFunction?
    var currentMprAxis: Axis?
    var mprNormalizedPosition: Float = 0.5
    var mprPlaneIndex: Int = 0
    var mprEuler: SIMD3<Float> = .zero
    var baseSamplingStep: Float
    var isAdaptiveSamplingActive = false
    var fallbackCameraTransform: simd_float4x4?
    var defaultTransferShift: Float = 0
    var fallbackWorldUp = SIMD3<Float>(0, 1, 0)
    var fallbackCameraTarget = SIMD3<Float>(0, 0, 0)
    var cameraTarget = SIMD3<Float>(0, 0, 0)
    var cameraOffset = SIMD3<Float>(0, 0, 1)
    var cameraUpVector = SIMD3<Float>(0, 1, 0)
    var cameraDistanceLimits: ClosedRange<Float> = 0.2...2048
    var volumeWorldCenter = SIMD3<Float>(0, 0, 0)
    var volumeBoundingRadius: Float = 1
    var patientLongitudinalAxis = SIMD3<Float>(0, 0, 1)
    let maximumPanDistanceMultiplier: Float = 1.5
#if canImport(UIKit)
    var adaptiveRecognizers: Set<ObjectIdentifier> = []
#endif
    let adaptiveInteractionFactor: Float = 0.5
    let defaultCameraDistanceFactor: Float = 2.5
    var initialCameraTransform: simd_float4x4?
    var defaultCameraTarget: SCNVector3 = SCNVector3(x: 0, y: 0, z: 0)
    var sharedVolumeTexture: (any MTLTexture)?

    /// Normalized intensity domain (0...1) for the active transfer function.
    ///
    /// Returns `nil` if no transfer function is loaded. This domain is used for HU window mapping calculations.
    /// Transfer functions are typically loaded via ``setPreset(_:)`` or ``setTransferFunction(_:)``.
    public var transferFunctionDomain: ClosedRange<Float>? {
        volumeMaterial.transferFunctionDomain
    }

    // MARK: - Initialization

    /// Creates a volumetric scene controller with Metal rendering capabilities.
    ///
    /// Initializes SceneKit scene graph, Metal materials, camera controllers, and rendering pipelines.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Use system default Metal device
    /// let controller = try VolumetricSceneController()
    ///
    /// // Provide custom device and view
    /// let customDevice = MTLCreateSystemDefaultDevice()
    /// let customView = SCNView(frame: bounds)
    /// let controller = try VolumetricSceneController(
    ///     device: customDevice,
    ///     sceneView: customView
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - device: Metal device for GPU operations (defaults to system default device).
    ///   - sceneView: SceneKit view for rendering (defaults to new SCNView instance).
    /// - Throws: ``Error/metalUnavailable`` if Metal device cannot be created or command queue initialization fails.
    public init(device: (any MTLDevice)? = nil, sceneView: SCNView? = nil) throws {
        self.baseSamplingStep = 512
        let resolvedDevice: any MTLDevice
        if let providedDevice = device {
            resolvedDevice = providedDevice
        } else if let systemDevice = MTLCreateSystemDefaultDevice() {
            resolvedDevice = systemDevice
        } else {
            throw Error.metalUnavailable
        }
        self.device = resolvedDevice
        guard let queue = resolvedDevice.makeCommandQueue() else {
            throw Error.metalUnavailable
        }
        self.commandQueue = queue

        let viewOptions: [String: Any] = [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ]
        let resolvedSceneView: SCNView
        if let providedView = sceneView {
            resolvedSceneView = providedView
        } else {
            let defaultFrame = CGRect(x: 0, y: 0, width: 320, height: 480)
            resolvedSceneView = SCNView(frame: defaultFrame, options: viewOptions)
        }
        self.sceneSurface = SceneKitSurface(sceneView: resolvedSceneView)
        self.sceneView = resolvedSceneView
#if os(iOS)
        resolvedSceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
#else
        resolvedSceneView.autoresizingMask = [.width, .height]
        // Enable default camera controls on macOS as a fallback interaction mode.
        resolvedSceneView.allowsCameraControl = true
#endif
        resolvedSceneView.isPlaying = true
        resolvedSceneView.preferredFramesPerSecond = 60
        resolvedSceneView.backgroundColor = .black
        resolvedSceneView.rendersContinuously = true
        resolvedSceneView.loops = true
        resolvedSceneView.isJitteringEnabled = true
        resolvedSceneView.allowsCameraControl = false
        resolvedSceneView.debugOptions = []

        scene = SCNScene()
        resolvedSceneView.scene = scene
        rootNode = scene.rootNode

        volumeMaterial = VolumeCubeMaterial(device: resolvedDevice)
        let cube = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        cube.materials = [volumeMaterial]
        volumeNode = SCNNode(geometry: cube)
        volumeNode.isHidden = true
        rootNode.addChildNode(volumeNode)
        baseSamplingStep = volumeMaterial.samplingStep

        mprMaterial = MPRPlaneMaterial(device: resolvedDevice)
        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [mprMaterial]
        mprNode = SCNNode(geometry: plane)
        mprNode.isHidden = true
        rootNode.addChildNode(mprNode)
        mprNode.simdTransform = volumeNode.simdTransform

        // Initialize controllers
        cameraController = VolumetricCameraController(
            sceneView: resolvedSceneView,
            rootNode: rootNode,
            statePublisher: statePublisher
        )
        volumeGeometry = VolumetricVolumeGeometry(
            volumeNode: volumeNode,
            volumeMaterial: volumeMaterial
        )
        mprController = VolumetricMPRController(
            sceneView: resolvedSceneView,
            volumeNode: volumeNode,
            mprNode: mprNode,
            mprMaterial: mprMaterial,
            cameraController: cameraController,
            volumeGeometry: volumeGeometry
        )

        updateVolumeBounds()

        let cameraNode = ensureCameraNode()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)
        cameraNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
        let transform = cameraNode.simdTransform
        fallbackCameraTransform = transform
        initialCameraTransform = transform
        let initialTarget = SIMD3<Float>(0, 0, 0)
        updateInteractiveCameraState(target: initialTarget,
                                      up: fallbackWorldUp,
                                      cameraNode: cameraNode,
                                      radius: 1)
        fallbackCameraTarget = initialTarget
        defaultCameraTarget = SCNVector3(x: SCNFloat(volumeWorldCenter.x),
                                         y: SCNFloat(volumeWorldCenter.y),
                                         z: SCNFloat(volumeWorldCenter.z))
        self.sceneView.defaultCameraController.pointOfView = cameraNode
        updateCameraControllerTargets()
        prepareCameraControllerForExternalGestures()
#if canImport(UIKit)
        attachAdaptiveHandlersIfNeeded()
        Task { [weak self] in
            await MainActor.run {
                self?.attachAdaptiveHandlersIfNeeded()
            }
        }
#endif
    }
}

// MARK: - Testing-only accessors for debug properties

/// Testing-only debug accessors for internal state inspection.
///
/// These methods are marked `@_spi(Testing)` and are only available when importing with `@testable` or explicit SPI import.
/// Use these for unit testing and debugging renderer state, not for production code.
extension VolumetricSceneController {

    /// Returns the active volume texture from the volume material.
    ///
    /// - SPI: Testing
    /// - Returns: Current 3D volume texture, or `nil` if no dataset is loaded.
    @_spi(Testing)
    public func debugVolumeTexture() -> (any MTLTexture)? {
        volumeMaterial.currentVolumeTexture()
    }
}

#endif
