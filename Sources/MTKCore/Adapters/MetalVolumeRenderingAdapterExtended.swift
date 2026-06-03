//
//  MetalVolumeRenderingAdapterExtended.swift
//  MTK
//
//  Extended MetalVolumeRenderingAdapter controls and snapshots
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
        extendedState.huGate = nil
    }

    public func setHuGate(enabled: Bool, minHU: Int32, maxHU: Int32) async throws {
        if enabled {
            let lower = min(minHU, maxHU)
            let upper = max(minHU, maxHU)
            extendedState.huGate = lower...upper
            extendedState.densityGate = nil
        } else {
            extendedState.huGate = nil
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
        try validateToneCurveChannel(channel)
        extendedState.toneCurvePoints[channel] = sanitizeToneCurveControlPoints(points)
    }

    public func setToneCurvePresetKey(_ key: String, forChannel channel: Int) async throws {
        try validateToneCurveChannel(channel)
        extendedState.toneCurvePresetKeys[channel] = key
    }

    public func setToneCurveGain(_ gain: Float, forChannel channel: Int) async throws {
        try validateToneCurveChannel(channel)
        extendedState.toneCurveGains[channel] = gain.isFinite ? max(gain, 0) : 1
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

    // MARK: - Clip Controls

    public func updateClipBounds(xMin: Float, xMax: Float, yMin: Float, yMax: Float, zMin: Float, zMax: Float) async throws {
        let cropBox = try VolumeCropBox(textureMin: SIMD3<Float>(xMin, yMin, zMin),
                                        textureMax: SIMD3<Float>(xMax, yMax, zMax))
        extendedState.clipBounds = ClipBoundsSnapshot(cropBox: cropBox)
        if extendedState.clipPlanePreset != 0 || abs(extendedState.clipPlaneOffset) > 1e-5 {
            if !clipPlaneApproximationLogged {
                logger.info("Clip-plane/quaternion inputs reach MTK adapter; current Metal volume rendering applies axis-aligned clip bounds and preset clip planes.")
                clipPlaneApproximationLogged = true
            }
        }
    }

    public func resetClipBounds() async throws {
        extendedState.clipBounds = .default
    }

    public func setClipPlanePreset(_ preset: Int) async throws {
        guard (0...3).contains(preset) else {
            throw VolumeClippingError.invalidClipPlanePreset(preset)
        }
        extendedState.clipPlanePreset = preset
    }

    public func setClipPlaneOffset(_ offset: Float) async throws {
        guard offset.isFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }
        extendedState.clipPlaneOffset = offset
    }
    
    // MARK: - Snapshot Methods
    
    public func getToneCurveSnapshot() async throws -> [ChannelControlSnapshot] {
        try await getChannelControlSnapshot()
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
            let dataset = snapshot.dataset
            return VolumeMetadata(
                dimensions: SIMD3<Int32>(
                    Int32(dataset.dimensions.width),
                    Int32(dataset.dimensions.height),
                    Int32(dataset.dimensions.depth)
                ),
                spacing: SIMD3<Float>(Float(dataset.spacing.x),
                                      Float(dataset.spacing.y),
                                      Float(dataset.spacing.z)),
                origin: dataset.imageData.origin,
                orientation: dataset.imageData.direction,
                intensityRange: dataset.intensityRange
            )
        }
        return nil
    }
    
    public func getCurrentRenderingQuality() async throws -> Float {
        extendedState.samplingStep
    }
    
    public func getChannelControlSnapshot() async throws -> [ChannelControlSnapshot] {
        Self.supportedToneChannelRange.map { channel in
            ChannelControlSnapshot(channel: channel,
                                   presetKey: extendedState.toneCurvePresetKeys[channel] ?? "default",
                                   gain: extendedState.toneCurveGains[channel] ?? 1,
                                   controlPoints: extendedState.toneCurvePoints[channel] ?? [])
        }
    }
}
