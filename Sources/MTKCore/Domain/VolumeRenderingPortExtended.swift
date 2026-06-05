//
//  VolumeRenderingPortExtended.swift
//  MTK
//
//  Extended volume rendering controls and snapshots
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

@preconcurrency import Metal

/// Extended volume renderer controls.
///
/// Prefer ``applyRenderState(_:)`` for coordinated renderer configuration changes. The individual
/// setters remain compatibility and lower-level adapter operations for focused control updates.
public protocol VolumeRenderingPortExtended: VolumeRenderingPort {
    /// Applies a validated renderer configuration as one cohesive state transition.
    func applyRenderState(_ state: VolumeRenderState) async throws

    /// Returns the renderer's effective configuration after validation and compatibility calls.
    func getRenderStateSnapshot() async throws -> VolumeRenderState

    /// Compatibility controls for lower-level adapter integrations; prefer ``applyRenderState(_:)``
    /// when a caller is changing more than one renderer setting.
    func setHuWindow(min: Int32, max: Int32) async throws
    func setEarlyTerminationThreshold(_ threshold: Float) async throws
    func setDensityGate(floor: Float, ceil: Float) async throws
    func setHuGate(enabled: Bool, minHU: Int32, maxHU: Int32) async throws
    
    // Channel controls
    //
    // The production renderer supports channels 0...3. The request transfer
    // function is shared across those channels; these controls apply per-channel
    // intensity weights and tone/gain multipliers to the shared transfer output.
    // Preset keys are reported in snapshots as caller-facing labels for the
    // effective control points and gain.
    /// Compatibility controls for lower-level adapter integrations; prefer ``applyRenderState(_:)``
    /// when channel changes need to be coordinated with windowing, quality, or clipping.
    func updateChannelIntensities(_ intensities: [Float]) async throws
    func setToneCurveControlPoints(_ points: [SIMD2<Float>], forChannel channel: Int) async throws
    func setToneCurvePresetKey(_ key: String, forChannel channel: Int) async throws
    func setToneCurveGain(_ gain: Float, forChannel channel: Int) async throws
    
    /// Compatibility controls for lower-level adapter integrations; prefer ``applyRenderState(_:)``
    /// for coherent renderer configuration updates.
    func setAdaptiveEnabled(_ enabled: Bool) async throws
    func setAdaptiveThreshold(_ threshold: Float) async throws
    func setJitterAmount(_ amount: Float) async throws
    func setLighting(_ enabled: Bool) async throws
    func setStep(_ step: Float) async throws
    func setShift(_ shift: Float) async throws
    
    /// Compatibility controls for lower-level adapter integrations; prefer ``applyRenderState(_:)``
    /// when clipping is part of a broader renderer-state change.
    func updateClipBounds(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float) async throws
    func resetClipBounds() async throws
    func setClipPlanePreset(_ preset: Int) async throws
    func setClipPlaneOffset(_ offset: Float) async throws
    
    // Snapshot methods
    func getToneCurveSnapshot() async throws -> [ChannelControlSnapshot]
    func getClipBoundsSnapshot() async throws -> ClipBoundsSnapshot
    func getClipPlaneSnapshot() async throws -> ClipPlaneSnapshot
    func getVolumeMetadata() async throws -> VolumeMetadata?
    func getCurrentRenderingQuality() async throws -> Float
    func getChannelControlSnapshot() async throws -> [ChannelControlSnapshot]
}
