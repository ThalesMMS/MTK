//
//  VolumetricSceneController.swift
//  MetalVolumetrics
//
//  SceneKit controller that orchestrates volumetric rendering and MPS prototypes.
//  Coordinates Metal materials, dataset application, and exposes an async API to
//  the presentation layer. This mirrors the legacy controller that previously
//  lived inside the application target but without the deprecated runtime
//  dependencies.
//
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation

public struct VolumetricCameraState: Equatable {
    public var position: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>

    public init(position: SIMD3<Float> = .zero,
                target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) {
        self.position = position
        self.target = target
        self.up = up
    }
}

public struct VolumetricSliceState: Equatable {
    public var axis: VolumetricSceneController.Axis
    public var normalizedPosition: Float

    public init(axis: VolumetricSceneController.Axis = .z,
                normalizedPosition: Float = 0.5) {
        self.axis = axis
        self.normalizedPosition = normalizedPosition
    }
}

public struct VolumetricWindowLevelState: Equatable {
    public var window: Double
    public var level: Double

    public init(window: Double = .zero, level: Double = .zero) {
        self.window = window
        self.level = level
    }
}

public enum VolumetricRenderingBackend: Int, CaseIterable, Equatable, Sendable {
    case sceneKit
    case metalPerformanceShaders

    public var displayName: String {
        switch self {
        case .sceneKit:
            return "SceneKit"
        case .metalPerformanceShaders:
            return "Metal Performance Shaders"
        }
    }
}

public enum VolumetricRenderMode {
    case active
    case paused
}

#if os(iOS) || os(macOS)
import Foundation
import SceneKit
import simd
import Combine
import MTKCore
import MTKSceneKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

#if os(iOS) || os(macOS)
private extension VolumetricSceneController {
    func publishCameraState(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        cameraState = VolumetricCameraState(position: position, target: target, up: up)
    }

    func publishSliceState(axis: Axis, normalized: Float) {
        let clamped = clampFloat(normalized, lower: 0, upper: 1)
        sliceState = VolumetricSliceState(axis: axis, normalizedPosition: clamped)
    }

    func publishWindowLevelState(_ mapping: VolumeCubeMaterial.HuWindowMapping) {
        let width = Double(mapping.maxHU - mapping.minHU)
        let level = Double(mapping.minHU) + width / 2
        windowLevelState = VolumetricWindowLevelState(window: width, level: level)
    }
}
#endif

extension VolumetricSceneController {
    /// Narrow helper so interaction extensions can toggle adaptive sampling without
    /// exposing the published property setter.
    @inline(__always)
    func setAdaptiveSamplingFlag(_ enabled: Bool) {
        adaptiveSamplingEnabled = enabled
    }

    /// Records the latest camera pose for observers without relaxing encapsulation.
    @inline(__always)
    func recordCameraState(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        publishCameraState(position: position, target: target, up: up)
    }

    /// Records a new slice state while clamping through the existing publisher logic.
    @inline(__always)
    func recordSliceState(axis: Axis, normalized: Float) {
        publishSliceState(axis: axis, normalized: normalized)
    }

    /// Records a new window/level state while preserving the derived width/level calculus.
    @inline(__always)
    func recordWindowLevelState(_ mapping: VolumeCubeMaterial.HuWindowMapping) {
        publishWindowLevelState(mapping)
    }
}

public struct VolumetricHotspot: Equatable {
    public let identifier: String
    public let description: String
    public let suggestion: String

    public init(identifier: String, description: String, suggestion: String) {
        self.identifier = identifier
        self.description = description
        self.suggestion = suggestion
    }
}
@MainActor
public protocol VolumetricSceneControlling: AnyObject {
    var surface: any RenderSurface { get }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    var mpsView: MTKView? { get }
#endif
    var transferFunctionDomain: ClosedRange<Float>? { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setDisplayConfiguration(_ configuration: VolumetricSceneController.DisplayConfiguration) async
    func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    func setTransferFunction(_ transferFunction: TransferFunction?) async throws
    func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async
    func setPreset(_ preset: VolumeCubeMaterial.Preset) async
    func setShift(_ shift: Float) async
    func setHuGate(enabled: Bool) async
    func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async
    func setRenderMode(_ mode: VolumetricRenderMode) async
    func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend
    func updateTransferFunctionShift(_ shift: Float) async
    func setAdaptiveSampling(_ enabled: Bool) async
    func beginAdaptiveSamplingInteraction() async
    func endAdaptiveSamplingInteraction() async
    func setRenderMethod(_ method: VolumeCubeMaterial.Method) async
    func setLighting(enabled: Bool) async
    func setSamplingStep(_ step: Float) async
    func setProjectionsUseTransferFunction(_ enabled: Bool) async
    func setProjectionDensityGate(floor: Float, ceil: Float) async
    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async
    func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async
    func setMprSlab(thickness: Int, steps: Int) async
    func setMprHuWindow(min: Int32, max: Int32) async
    func setMprPlane(axis: VolumetricSceneController.Axis, normalized: Float) async
    func translate(axis: VolumetricSceneController.Axis, deltaNormalized: Float) async
    func rotate(axis: VolumetricSceneController.Axis, radians: Float) async
    func resetView() async
    func resetCamera() async

    func rotateCamera(screenDelta: SIMD2<Float>) async
    func tiltCamera(roll: Float, pitch: Float) async
    func panCamera(screenDelta: SIMD2<Float>) async
    func dollyCamera(delta: Float) async
}

@MainActor
public final class VolumetricSceneController: VolumetricSceneControlling, ObservableObject {
    public enum Error: Swift.Error {
        case metalUnavailable
        case transferFunctionUnavailable
    }

    public enum Axis: Int {
        case x = 0
        case y = 1
        case z = 2
    }

    public struct SlabConfiguration: Equatable {
        public var thickness: Int
        public var steps: Int

        public init(thickness: Int, steps: Int) {
            let normalizedThickness = Self.snapToOddVoxelCount(thickness)
            let normalizedSteps = Self.snapToOddVoxelCount(max(1, steps))
            self.thickness = normalizedThickness
            self.steps = normalizedSteps
        }

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

    public enum DisplayConfiguration: Equatable {
        case volume(method: VolumeCubeMaterial.Method)
        case mpr(axis: Axis, index: Int, blend: MPRPlaneMaterial.BlendMode, slab: SlabConfiguration?)
    }

    public static let manualHotspots: [VolumetricHotspot] = [
        VolumetricHotspot(
            identifier: "volume_ray_march",
            description: "Fragment shader `direct_volume_rendering` performs per-fragment ray marching with manual empty-space skipping",
            suggestion: "Prototype an MPS ray casting pass to offload accumulation and early-out heuristics to GPU-managed kernels."
        ),
        VolumetricHotspot(
            identifier: "mpr_resample",
            description: "MPR material relies on CPU-generated slab textures prior to binding to SceneKit",
            suggestion: "Leverage `MPSImageResample` or `MPSMatrixBilinearScale` to rebuild slabs directly on the GPU."
        ),
        VolumetricHotspot(
            identifier: "histogram_wwl",
            description: "Window/level suggestions derived from CPU statistics before calling into the shader pipeline",
            suggestion: "Use `MPSImageHistogram` to derive HU statistics alongside transfer-function preparation."
        )
    ]

    public let sceneSurface: SceneKitSurface
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    let mpsSurface: (any RenderSurface)?
#endif
    var activeSurface: any RenderSurface
    public var surface: any RenderSurface { activeSurface }
    public let sceneView: SCNView
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    public var mpsView: MTKView? {
        mpsDisplay?.mtkView
    }
#endif

    public let scene: SCNScene
    public let rootNode: SCNNode
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue

    public let volumeNode: SCNNode
    public let volumeMaterial: VolumeCubeMaterial

    public let mprNode: SCNNode
    public let mprMaterial: MPRPlaneMaterial

    @Published public private(set) var cameraState = VolumetricCameraState()
    @Published public private(set) var sliceState = VolumetricSliceState()
    @Published public private(set) var windowLevelState = VolumetricWindowLevelState()
    @Published public private(set) var adaptiveSamplingEnabled: Bool = true

    let logger = Logger(category: "Volumetric.SceneController")

    var dataset: VolumeDataset?
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
    var renderingBackend: VolumetricRenderingBackend = .sceneKit
    var sharedVolumeTexture: (any MTLTexture)?
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    let mpsDisplay: MPSDisplayAdapter?
#endif
#if canImport(MetalPerformanceShaders)
    var mpsRenderer: MPSVolumeRenderer?
    var lastMpsHistogram: MPSVolumeRenderer.HistogramResult?
    var mpsFilteredTexture: (any MTLTexture)?
    var lastRayCastingSamples: [MPSVolumeRenderer.RayCastingSample] = []
    var lastRayCastingWorldEntries: [Float] = []
    let mpsGaussianSigma: Float = 1.25
#endif

    public var transferFunctionDomain: ClosedRange<Float>? {
        volumeMaterial.transferFunctionDomain
    }

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
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
        if MPSSupportsMTLDevice(resolvedDevice) {
            let display = MPSDisplayAdapter(device: resolvedDevice, commandQueue: queue)
            mpsDisplay = display
            mpsSurface = display
        } else {
            mpsDisplay = nil
            mpsSurface = nil
        }
#endif

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

        activeSurface = sceneSurface

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
extension VolumetricSceneController {
    @_spi(Testing)
    public func debugVolumeTexture() -> (any MTLTexture)? {
        volumeMaterial.currentVolumeTexture()
    }

#if canImport(MetalPerformanceShaders)
    @_spi(Testing)
    public func debugMpsFilteredTexture() -> (any MTLTexture)? {
        mpsFilteredTexture
    }

    @_spi(Testing)
    public func debugLastRayCastingSamples() -> [MPSVolumeRenderer.RayCastingSample] {
        lastRayCastingSamples
    }

    @_spi(Testing)
    public func debugLastRayCastingWorldEntries() -> [Float] {
        lastRayCastingWorldEntries
    }

    @_spi(Testing)
    public func debugMpsDisplayBrightness() -> Float? {
        mpsDisplay?.debugResolvedBrightness()
    }

    @_spi(Testing)
    public func debugMpsTransferFunction() -> TransferFunction? {
        mpsDisplay?.debugTransferFunction()
    }

    @_spi(Testing)
    public func debugMpsResolvedBrightness() -> Float? {
        mpsDisplay?.debugResolvedBrightness()
    }

    @_spi(Testing)
    public func debugMpsClearColor() -> (red: Float, green: Float, blue: Float) {
        guard let clearColor = mpsDisplay?.debugClearColor() else {
            return (red: 0, green: 0, blue: 0)
        }
        return (red: Float(clearColor.red), green: Float(clearColor.green), blue: Float(clearColor.blue))
    }

    @_spi(Testing)
    public func debugLastMpsHistogram() -> MPSVolumeRenderer.HistogramResult? {
        lastMpsHistogram
    }
#endif
}

#else
import Foundation
import CoreGraphics
import simd
import Combine
import MTKCore
import MTKSceneKit
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif

@MainActor
public protocol VolumetricSceneControlling: AnyObject {
    var surface: any RenderSurface { get }
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    var mpsView: MTKView? { get }
#endif
    var transferFunctionDomain: ClosedRange<Float>? { get }

    func applyDataset(_ dataset: VolumeDataset) async
    func setDisplayConfiguration(_ configuration: VolumetricSceneController.DisplayConfiguration) async
    func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    func setTransferFunction(_ transferFunction: TransferFunction?) async throws
    func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async
    func setPreset(_ preset: VolumeCubeMaterial.Preset) async
    func setShift(_ shift: Float) async
    func setHuGate(enabled: Bool) async
    func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async
    func setRenderMode(_ mode: VolumetricRenderMode) async
    func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend
    func updateTransferFunctionShift(_ shift: Float) async
    func setAdaptiveSampling(_ enabled: Bool) async
    func beginAdaptiveSamplingInteraction() async
    func endAdaptiveSamplingInteraction() async
    func setRenderMethod(_ method: VolumeCubeMaterial.Method) async
    func setLighting(enabled: Bool) async
    func setSamplingStep(_ step: Float) async
    func setProjectionsUseTransferFunction(_ enabled: Bool) async
    func setProjectionDensityGate(floor: Float, ceil: Float) async
    func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async
    func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async
    func setMprSlab(thickness: Int, steps: Int) async
    func setMprHuWindow(min: Int32, max: Int32) async
    func setMprPlane(axis: VolumetricSceneController.Axis, normalized: Float) async
    func translate(axis: VolumetricSceneController.Axis, deltaNormalized: Float) async
    func rotate(axis: VolumetricSceneController.Axis, radians: Float) async
    func resetView() async
    func resetCamera() async

    func rotateCamera(screenDelta: SIMD2<Float>) async
    func tiltCamera(roll: Float, pitch: Float) async
    func panCamera(screenDelta: SIMD2<Float>) async
    func dollyCamera(delta: Float) async
}

@MainActor
public final class VolumetricSceneController: VolumetricSceneControlling, ObservableObject {
    private final class StubSurface: RenderSurface {
#if os(macOS)
        let view = PlatformView(frame: .zero)
#else
        let view = PlatformView()
#endif

        func display(_ image: CGImage) { _ = image }
        func setContentScale(_ scale: CGFloat) { _ = scale }
    }

    public let surface: any RenderSurface
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    public var mpsView: MTKView? { nil }
#endif
    public var transferFunctionDomain: ClosedRange<Float>?
    private var storedMetadata: (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)?

    @Published public private(set) var cameraState = VolumetricCameraState(position: SIMD3<Float>(0, 0, 2),
                                                                           target: .zero,
                                                                           up: SIMD3<Float>(0, 1, 0))
    @Published public private(set) var sliceState = VolumetricSliceState()
    @Published public private(set) var windowLevelState = VolumetricWindowLevelState()
    @Published public private(set) var adaptiveSamplingEnabled: Bool = true

    private var stubCameraPosition = SIMD3<Float>(0, 0, 2)
    private var stubCameraTarget = SIMD3<Float>(0, 0, 0)
    private var stubCameraUp = SIMD3<Float>(0, 1, 0)
    public enum Axis: Int {
        case x = 0
        case y = 1
        case z = 2
    }

    public struct SlabConfiguration: Equatable {
        public var thickness: Int
        public var steps: Int

        public init(thickness: Int, steps: Int) {
            self.thickness = thickness
            self.steps = steps
        }
    }

    public enum DisplayConfiguration: Equatable {
        case volume(method: VolumeCubeMaterial.Method)
        case mpr(axis: Axis, index: Int, blend: MPRPlaneMaterial.BlendMode, slab: SlabConfiguration?)
    }

    public init() {
        surface = StubSurface()
    }

    public func applyDataset(_ dataset: VolumeDataset) async {
        _ = dataset
        storedMetadata = nil
    }

    public func setDisplayConfiguration(_ configuration: DisplayConfiguration) async {
        _ = configuration
    }

    public func metadata() -> (dimension: SIMD3<Int32>, resolution: SIMD3<Float>)? {
        storedMetadata
    }

    public func setTransferFunction(_ transferFunction: TransferFunction?) async throws {
        _ = transferFunction
    }

    public func setVolumeMethod(_ method: VolumeCubeMaterial.Method) async { _ = method }

    public func setPreset(_ preset: VolumeCubeMaterial.Preset) async { _ = preset }

    public func setShift(_ shift: Float) async { _ = shift }

    public func setHuGate(enabled: Bool) async { _ = enabled }

    public func setHuWindow(_ window: VolumeCubeMaterial.HuWindowMapping) async {
        transferFunctionDomain = Float(window.minHU)...Float(window.maxHU)
        let width = Double(window.maxHU - window.minHU)
        let level = Double(window.minHU) + width / 2
        windowLevelState = VolumetricWindowLevelState(window: width, level: level)
    }

    public func setRenderMode(_ mode: VolumetricRenderMode) async { _ = mode }

    public func setRenderingBackend(_ backend: VolumetricRenderingBackend) async -> VolumetricRenderingBackend {
        backend
    }

    public func updateTransferFunctionShift(_ shift: Float) async { _ = shift }

    public func setAdaptiveSampling(_ enabled: Bool) async {
        adaptiveSamplingEnabled = enabled
    }

    public func beginAdaptiveSamplingInteraction() async {}

    public func endAdaptiveSamplingInteraction() async {}

    public func setRenderMethod(_ method: VolumeCubeMaterial.Method) async { _ = method }

    public func setLighting(enabled: Bool) async { _ = enabled }

    public func setSamplingStep(_ step: Float) async { _ = step }

    public func setProjectionsUseTransferFunction(_ enabled: Bool) async { _ = enabled }

    public func setProjectionDensityGate(floor: Float, ceil: Float) async {
        _ = (floor, ceil)
    }

    public func setProjectionHuGate(enabled: Bool, min: Int32, max: Int32) async {
        _ = (enabled, min, max)
    }

    public func setMprBlend(_ mode: MPRPlaneMaterial.BlendMode) async { _ = mode }

    public func setMprSlab(thickness: Int, steps: Int) async {
        _ = (thickness, steps)
    }

    public func setMprHuWindow(min: Int32, max: Int32) async {
        _ = (min, max)
    }

    public func setMprPlane(axis: Axis, normalized: Float) async {
        let clamped = max(0, min(1, normalized))
        sliceState = VolumetricSliceState(axis: axis, normalizedPosition: clamped)
    }

    public func translate(axis: Axis, deltaNormalized: Float) async {
        await setMprPlane(axis: axis, normalized: sliceState.normalizedPosition + deltaNormalized)
    }

    public func rotate(axis: Axis, radians: Float) async {
        _ = (axis, radians)
    }

    public func resetView() async {}

    public func resetCamera() async {
        stubCameraPosition = SIMD3<Float>(0, 0, 2)
        stubCameraTarget = .zero
        stubCameraUp = SIMD3<Float>(0, 1, 0)
        cameraState = VolumetricCameraState(position: stubCameraPosition,
                                            target: stubCameraTarget,
                                            up: stubCameraUp)
    }

    public func rotateCamera(screenDelta: SIMD2<Float>) async {
        stubCameraTarget += SIMD3<Float>(screenDelta.x * 0.01, screenDelta.y * 0.01, 0)
        cameraState = VolumetricCameraState(position: stubCameraPosition,
                                            target: stubCameraTarget,
                                            up: stubCameraUp)
    }

    public func tiltCamera(roll: Float, pitch: Float) async {
        stubCameraUp = SIMD3<Float>(0, 1, 0) + SIMD3<Float>(roll * 0.01, pitch * 0.01, 0)
        cameraState = VolumetricCameraState(position: stubCameraPosition,
                                            target: stubCameraTarget,
                                            up: stubCameraUp)
    }

    public func panCamera(screenDelta: SIMD2<Float>) async {
        let delta = SIMD3<Float>(screenDelta.x * 0.01, screenDelta.y * 0.01, 0)
        stubCameraPosition += delta
        stubCameraTarget += delta
        cameraState = VolumetricCameraState(position: stubCameraPosition,
                                            target: stubCameraTarget,
                                            up: stubCameraUp)
    }

    public func dollyCamera(delta: Float) async {
        stubCameraPosition.z += delta * 0.1
        cameraState = VolumetricCameraState(position: stubCameraPosition,
                                            target: stubCameraTarget,
                                            up: stubCameraUp)
    }
}
#endif
