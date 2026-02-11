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

#if os(iOS) || os(macOS)
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

    public let statePublisher = VolumetricStatePublisher()
    let cameraController: VolumetricCameraController
    let volumeGeometry: VolumetricVolumeGeometry
    let mprController: VolumetricMPRController

    public var cameraState: VolumetricCameraState {
        statePublisher.cameraState
    }

    public var sliceState: VolumetricSliceState {
        statePublisher.sliceState
    }

    public var windowLevelState: VolumetricWindowLevelState {
        statePublisher.windowLevelState
    }

    public var adaptiveSamplingEnabled: Bool {
        statePublisher.adaptiveSamplingEnabled
    }

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

#endif
