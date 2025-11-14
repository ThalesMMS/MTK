//
//  VolumeRenderingPortExtended.swift
//  MTK
//
//  Extended volume rendering port with missing APIs
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

public protocol VolumeRenderingPortExtended: VolumeRenderingPort {
    // Window/Intensity controls
    func setHuWindow(min: Int32, max: Int32) async throws
    func setEarlyTerminationThreshold(_ threshold: Float) async throws
    func setDensityGate(floor: Float, ceil: Float) async throws
    func setHuGate(enabled: Bool, minHU: Int32, maxHU: Int32) async throws
    
    // Channel controls
    func updateChannelIntensities(_ intensities: [Float]) async throws
    func setToneCurveControlPoints(_ points: [SIMD2<Float>], forChannel channel: Int) async throws
    func setToneCurvePresetKey(_ key: String, forChannel channel: Int) async throws
    func setToneCurveGain(_ gain: Float, forChannel channel: Int) async throws
    
    // Rendering controls
    func setAdaptiveEnabled(_ enabled: Bool) async throws
    func setAdaptiveThreshold(_ threshold: Float) async throws
    func setJitterAmount(_ amount: Float) async throws
    func setLighting(_ enabled: Bool) async throws
    func setStep(_ step: Float) async throws
    func setShift(_ shift: Float) async throws
    func setRenderMethod(_ method: Int) async throws
    
    // MPR controls
    func setMPRBlend(_ blend: Float) async throws
    
    // Clip controls
    func updateClipBounds(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float) async throws
    func resetClipBounds() async throws
    func setClipPlanePreset(_ preset: Int) async throws
    func setClipPlaneOffset(_ offset: Float) async throws
    func alignClipBoxToView() async throws
    func alignClipPlaneToView() async throws
    
    // Snapshot methods
    func getHistogram() async throws -> [Int]
    func getToneCurveSnapshot() async throws -> [ChannelControlSnapshot]
    func getClipBoundsSnapshot() async throws -> ClipBoundsSnapshot
    func getClipPlaneSnapshot() async throws -> ClipPlaneSnapshot
    func getVolumeMetadata() async throws -> VolumeMetadata?
    func getCurrentRenderingQuality() async throws -> Float
    func getChannelControlSnapshot() async throws -> [ChannelControlSnapshot]
}
