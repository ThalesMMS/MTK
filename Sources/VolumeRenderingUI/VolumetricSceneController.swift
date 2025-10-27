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

#if os(iOS)
import Foundation
import SceneKit
import simd
import VolumeRenderingCore
import VolumeRenderingCore
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
public final class VolumetricSceneController: VolumetricSceneControlling {
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
    public var surface: any RenderSurface { sceneSurface }
    public let sceneView: SCNView
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
    public var mpsView: MTKView? {
        mpsDisplay?.view
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
    var adaptiveSamplingEnabled = true
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
            mpsDisplay = MPSDisplayAdapter(device: resolvedDevice, commandQueue: queue)
        } else {
            mpsDisplay = nil
        }
#endif

        let viewOptions: [String: Any] = [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ]
        let resolvedSceneView: SCNView
        if let providedView = sceneView {
            resolvedSceneView = providedView
        } else {
            resolvedSceneView = SCNView(frame: .zero, options: viewOptions)
        }
        self.sceneSurface = SceneKitSurface(sceneView: resolvedSceneView)
        self.sceneView = resolvedSceneView
        #if os(iOS)
        resolvedSceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        resolvedSceneView.autoresizingMask = [.width, .height]
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
#else
import Foundation
import VolumeRenderingCore

@MainActor
public protocol VolumetricSceneControlling: AnyObject {}

@MainActor
public final class VolumetricSceneController: VolumetricSceneControlling {
    public init() {}
}
#endif
