//
//  VolumetricSceneController+Snapshots.swift
//  MetalVolumetrics
//
//  Snapshot helpers and debug utilities extracted from the main controller.
//
#if os(iOS) || os(macOS)
import Foundation
import SceneKit
import simd
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShaders) && canImport(MetalKit)
import MetalKit
#endif
import MTKCore
@_spi(Testing) import MTKSceneKit

public struct VolumeMaterialSnapshot {
    var methodID: Int32
    var renderingQuality: Int32
    var huGateEnabled: Bool
    var huMin: Int32
    var huMax: Int32
    var transferFunctionID: ObjectIdentifier?
    var lightingEnabled: Bool
}

public struct MPRMaterialSnapshot {
    var blendModeID: Int32
    var voxelMin: Int32
    var voxelMax: Int32
    var usesTransferFunction: Bool
    var transferFunctionID: ObjectIdentifier?
}

enum VolumetricSceneSnapshotError: Error {
    case missingVolumeUniforms
    case missingMprUniforms
}

#if DEBUG
@_spi(Testing) extension VolumetricSceneController {
    func debugMprVolumeTexture() -> (any MTLTexture)? {
        mprMaterial.debugVolumeTexture()
    }

    func debugMprFallbackTexture() -> (any MTLTexture) {
        mprMaterial.debugFallbackTexture()
    }
}
#endif

public extension VolumetricSceneController {
    func debugVolumeMaterialSnapshot() throws -> VolumeMaterialSnapshot {
        guard let data = volumeMaterial.value(forKey: "uniforms") as? NSData else {
            throw VolumetricSceneSnapshotError.missingVolumeUniforms
        }
        var uniforms = VolumeCubeMaterial.Uniforms()
        data.getBytes(&uniforms, length: data.length)

        let transferID = volumeMaterial.currentTransferFunctionTexture().map { ObjectIdentifier($0 as AnyObject) }

        return VolumeMaterialSnapshot(
            methodID: uniforms.method,
            renderingQuality: uniforms.renderingQuality,
            huGateEnabled: uniforms.useHuGate != 0,
            huMin: uniforms.gateHuMin,
            huMax: uniforms.gateHuMax,
            transferFunctionID: transferID,
            lightingEnabled: uniforms.isLightingOn != 0
        )
    }

    func debugMprMaterialSnapshot() throws -> MPRMaterialSnapshot {
        guard let data = mprMaterial.value(forKey: "U") as? NSData else {
            throw VolumetricSceneSnapshotError.missingMprUniforms
        }
        var uniforms = MPRPlaneMaterial.Uniforms()
        data.getBytes(&uniforms, length: data.length)

        let transferProperty = mprMaterial.value(forKey: "transferColor") as? SCNMaterialProperty
        let transferTexture = transferProperty?.contents as Any?
        let transferID: ObjectIdentifier?
        if let texture = transferTexture as? any MTLTexture {
            transferID = ObjectIdentifier(texture as AnyObject)
        } else {
            transferID = nil
        }
        let usesTransferFunction = transferID != nil

        return MPRMaterialSnapshot(
            blendModeID: uniforms.blendMode,
            voxelMin: uniforms.voxelMinValue,
            voxelMax: uniforms.voxelMaxValue,
            usesTransferFunction: usesTransferFunction,
            transferFunctionID: transferID
        )
    }
}
#endif
