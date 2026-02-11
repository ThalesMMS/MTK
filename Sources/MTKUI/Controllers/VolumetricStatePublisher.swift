//
//  VolumetricStatePublisher.swift
//  MetalVolumetrics
//
//  State publisher managing @Published properties for volumetric scene interaction.
//  Coordinates camera pose, slice position, window/level adjustments, and adaptive
//  sampling flags. Provides public recording methods to update state while preserving
//  validation and clamping logic.
//
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation

#if os(iOS) || os(macOS)
import Combine
import MTKCore
import MTKSceneKit

@MainActor
public final class VolumetricStatePublisher: ObservableObject {
    @Published public private(set) var cameraState = VolumetricCameraState()
    @Published public private(set) var sliceState = VolumetricSliceState()
    @Published public private(set) var windowLevelState = VolumetricWindowLevelState()
    @Published public private(set) var adaptiveSamplingEnabled: Bool = true

    public init() {}

    // MARK: - Private Publishing Helpers

    /// Internal helper to publish camera state changes.
    /// Converts raw position, target, and up vectors into a VolumetricCameraState instance.
    private func publishCameraState(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        cameraState = VolumetricCameraState(position: position, target: target, up: up)
    }

    /// Internal helper to publish slice state changes.
    /// Clamps normalized position to [0, 1] range before publishing.
    private func publishSliceState(axis: VolumetricSceneController.Axis, normalized: Float) {
        let clamped = VolumetricMath.clampFloat(normalized, lower: 0, upper: 1)
        sliceState = VolumetricSliceState(axis: axis, normalizedPosition: clamped)
    }

    /// Internal helper to publish window/level state changes.
    /// Derives window width and level from HU mapping min/max values.
    private func publishWindowLevelState(_ mapping: VolumeCubeMaterial.HuWindowMapping) {
        let width = Double(mapping.maxHU - mapping.minHU)
        let level = Double(mapping.minHU) + width / 2
        windowLevelState = VolumetricWindowLevelState(window: width, level: level)
    }

    // MARK: - Public Recording Methods

    /// Narrow helper so interaction extensions can toggle adaptive sampling without
    /// exposing the published property setter.
    @inline(__always)
    public func setAdaptiveSamplingFlag(_ enabled: Bool) {
        adaptiveSamplingEnabled = enabled
    }

    /// Records the latest camera pose for observers without relaxing encapsulation.
    @inline(__always)
    public func recordCameraState(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        publishCameraState(position: position, target: target, up: up)
    }

    /// Records a new slice state while clamping through the existing publisher logic.
    @inline(__always)
    public func recordSliceState(axis: VolumetricSceneController.Axis, normalized: Float) {
        publishSliceState(axis: axis, normalized: normalized)
    }

    /// Records a new window/level state while preserving the derived width/level calculus.
    @inline(__always)
    public func recordWindowLevelState(_ mapping: VolumeCubeMaterial.HuWindowMapping) {
        publishWindowLevelState(mapping)
    }
}

#endif
