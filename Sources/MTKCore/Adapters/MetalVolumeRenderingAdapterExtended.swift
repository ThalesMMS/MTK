//
//  MetalVolumeRenderingAdapterExtended.swift
//  MTK
//
//  Extended MetalVolumeRenderingAdapter with missing APIs
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd

extension MetalVolumeRenderingAdapter: VolumeRenderingPortExtended {
    
    // MARK: - Window/Intensity Controls
    
    public func setHuWindow(min: Int32, max: Int32) async throws {
        let sanitized = min...max
        extendedState.huWindow = sanitized
        try await send(.setWindow(min: min, max: max))
    }
    
    public func setEarlyTerminationThreshold(_ threshold: Float) async throws {
        extendedState.earlyTerminationThreshold = max(0, min(threshold, 1))
    }

    public func setDensityGate(floor: Float, ceil: Float) async throws {
        let lower = min(floor, ceil)
        let upper = max(floor, ceil)
        extendedState.densityGate = lower...upper
    }

    public func setHuGate(enabled: Bool, minHU: Int32, maxHU: Int32) async throws {
        if enabled {
            extendedState.densityGate = Float(minHU)...Float(maxHU)
        } else {
            extendedState.densityGate = nil
        }
    }

    // MARK: - Channel Controls

    public func updateChannelIntensities(_ intensities: [Float]) async throws {
        var values = Array(intensities)
        if values.count < 4 {
            values += Array(repeating: 0, count: 4 - values.count)
        }
        extendedState.channelIntensities = SIMD4<Float>(values[0], values[1], values[2], values[3])
    }

    public func setToneCurveControlPoints(_ points: [SIMD2<Float>], forChannel channel: Int) async throws {
        extendedState.toneCurvePoints[channel] = points
    }

    public func setToneCurvePresetKey(_ key: String, forChannel channel: Int) async throws {
        extendedState.toneCurvePresetKeys[channel] = key
    }

    public func setToneCurveGain(_ gain: Float, forChannel channel: Int) async throws {
        extendedState.toneCurveGains[channel] = gain
    }

    // MARK: - Rendering Controls

    public func setAdaptiveEnabled(_ enabled: Bool) async throws {
        extendedState.adaptiveEnabled = enabled
    }

    public func setAdaptiveThreshold(_ threshold: Float) async throws {
        extendedState.adaptiveThreshold = threshold
    }

    public func setJitterAmount(_ amount: Float) async throws {
        extendedState.jitterAmount = amount
    }
    
    public func setLighting(_ enabled: Bool) async throws {
        extendedState.lightingEnabled = enabled
        try await send(.setLighting(enabled))
    }
    
    public func setStep(_ step: Float) async throws {
        extendedState.samplingStep = step
        try await send(.setSamplingStep(step))
    }
    
    public func setShift(_ shift: Float) async throws {
        extendedState.shift = shift
    }

    public func setRenderMethod(_ method: Int) async throws {
        // Intentionally no-op for now; stored for future GPU renderer
    }

    // MARK: - MPR Controls

    public func setMPRBlend(_ blend: Float) async throws {
        // No CPU effect yet; store metadata if needed
    }

    // MARK: - Clip Controls

    public func updateClipBounds(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float) async throws {
        let sanitized = ClipBoundsSnapshot(xMin: min(xMin, xMax),
                                           xMax: max(xMin, xMax),
                                           yMin: min(yMin, yMax),
                                           yMax: max(yMin, yMax),
                                           zMin: min(zMin, zMax),
                                           zMax: max(zMin, zMax))
        extendedState.clipBounds = sanitized
        if extendedState.clipPlanePreset != 0 || abs(extendedState.clipPlaneOffset) > 1e-5 {
            if !clipPlaneApproximationLogged {
                logger.info("Clip-plane/quaternion inputs reach MTK adapter but CPU fallback only respects axis-aligned bounds.")
                clipPlaneApproximationLogged = true
            }
        }
    }

    public func resetClipBounds() async throws {
        extendedState.clipBounds = .default
    }

    public func setClipPlanePreset(_ preset: Int) async throws {
        extendedState.clipPlanePreset = preset
    }

    public func setClipPlaneOffset(_ offset: Float) async throws {
        extendedState.clipPlaneOffset = offset
    }

    public func alignClipBoxToView() async throws {
        logger.warning("alignClipBoxToView not supported in CPU adapter yet.")
    }

    public func alignClipPlaneToView() async throws {
        logger.warning("alignClipPlaneToView not supported in CPU adapter yet.")
    }
    
    // MARK: - Snapshot Methods
    
    public func getHistogram() async throws -> [Int] {
        if debugLastSnapshot != nil {
            return Array(repeating: 0, count: 256)
        }
        return Array(repeating: 0, count: 256)
    }
    
    public func getToneCurveSnapshot() async throws -> [ChannelControlSnapshot] {
        let gain = extendedState.toneCurveGains[0] ?? 1
        let points = extendedState.toneCurvePoints[0] ?? []
        let presetKey = extendedState.toneCurvePresetKeys[0] ?? "default"
        return [ChannelControlSnapshot(presetKey: presetKey, gain: gain, controlPoints: points)]
    }
    
    public func getClipBoundsSnapshot() async throws -> ClipBoundsSnapshot {
        extendedState.clipBounds
    }
    
    public func getClipPlaneSnapshot() async throws -> ClipPlaneSnapshot {
        return ClipPlaneSnapshot(preset: extendedState.clipPlanePreset,
                                 offset: extendedState.clipPlaneOffset)
    }
    
    public func getVolumeMetadata() async throws -> VolumeMetadata? {
        if let snapshot = debugLastSnapshot {
            return VolumeMetadata(
                dimensions: SIMD3<Int32>(
                    Int32(snapshot.dataset.dimensions.width),
                    Int32(snapshot.dataset.dimensions.height),
                    Int32(snapshot.dataset.dimensions.depth)
                ),
                spacing: SIMD3<Float>(1, 1, 1),
                origin: SIMD3<Float>(0, 0, 0),
                orientation: simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1)),
                intensityRange: snapshot.dataset.intensityRange
            )
        }
        return nil
    }
    
    public func getCurrentRenderingQuality() async throws -> Float {
        extendedState.samplingStep
    }
    
    public func getChannelControlSnapshot() async throws -> [ChannelControlSnapshot] {
        let gain = extendedState.toneCurveGains[0] ?? 1
        let preset = extendedState.toneCurvePresetKeys[0] ?? "default"
        return [ChannelControlSnapshot(presetKey: preset, gain: gain, controlPoints: extendedState.toneCurvePoints[0] ?? [])]
    }
}
