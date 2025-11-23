//
//  VolumetricSceneController+Delegates.swift
//  MetalVolumetrics
//
//  Lightweight forwarding helpers split from the core controller.
//
#if os(iOS) || os(macOS)
import Foundation
import SceneKit
import simd
import MTKCore
import MTKSceneKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
#if canImport(Domain)
import Domain
#endif

@MainActor public extension VolumetricSceneController {
    func synchronizeInteractiveCameraState(target: SIMD3<Float>,
                                           up: SIMD3<Float>,
                                           cameraNode: SCNNode,
                                           radius: Float) {
        updateInteractiveCameraState(target: target,
                                     up: up,
                                     cameraNode: cameraNode,
                                     radius: radius)
    }

    func prepareCameraControllerForGestures(worldUp: SIMD3<Float>? = nil) {
        prepareCameraControllerForExternalGestures(worldUp: worldUp)
    }
}
#endif
