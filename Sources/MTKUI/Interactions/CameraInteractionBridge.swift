//  CameraInteractionBridge.swift
//  MTK
//  Bridges VolumetricSceneController to VolumeCameraControlling protocol.
//  Thales Matheus Mendonça Santos — October 2025

#if os(iOS)
import simd
import MTKSceneKit

extension VolumetricSceneController: VolumeCameraControlling {
    public func orbit(by delta: SIMD2<Float>) {
        Task { await rotateCamera(screenDelta: delta) }
    }

    public func pan(by delta: SIMD2<Float>) {
        Task { await panCamera(screenDelta: delta) }
    }

    public func zoom(by factor: Float) {
        Task { await dollyCamera(delta: factor) }
    }
}
#endif

