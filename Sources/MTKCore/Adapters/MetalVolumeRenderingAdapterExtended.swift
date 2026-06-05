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
    // MARK: - Cohesive Render State

    public func applyRenderState(_ state: VolumeRenderState) async throws {
        let resolved = try validatedRenderState(state)

        extendedState.huWindow = resolved.huWindow
        extendedState.earlyTerminationThreshold = resolved.earlyTerminationThreshold
        extendedState.densityGate = resolved.densityGate
        extendedState.huGate = resolved.huGate
        extendedState.channelIntensities = SIMD4<Float>(
            resolved.channels[0].intensity,
            resolved.channels[1].intensity,
            resolved.channels[2].intensity,
            resolved.channels[3].intensity
        )
        extendedState.toneCurvePoints = Dictionary(uniqueKeysWithValues: resolved.channels.map {
            ($0.channel, $0.controlPoints)
        })
        extendedState.toneCurvePresetKeys = Dictionary(uniqueKeysWithValues: resolved.channels.map {
            ($0.channel, $0.presetKey)
        })
        extendedState.toneCurveGains = Dictionary(uniqueKeysWithValues: resolved.channels.map {
            ($0.channel, $0.gain)
        })
        extendedState.adaptiveEnabled = resolved.adaptiveEnabled
        extendedState.adaptiveThreshold = resolved.adaptiveThreshold
        extendedState.jitterAmount = resolved.jitterAmount
        extendedState.lightingEnabled = resolved.lightingEnabled
        extendedState.samplingStep = resolved.samplingStep
        extendedState.shift = resolved.shift
        extendedState.clipBounds = resolved.clipBounds
        extendedState.clipPlanePreset = resolved.clipPlane.preset
        extendedState.clipPlaneOffset = resolved.clipPlane.offset

        if let window = resolved.huWindow {
            try await send(.setWindow(min: window.lowerBound, max: window.upperBound))
        }
        try await send(.setLighting(resolved.lightingEnabled))
        try await send(.setSamplingStep(resolved.samplingStep))
        logClipPlaneApproximationIfNeeded()
    }

    public func getRenderStateSnapshot() async throws -> VolumeRenderState {
        currentRenderStateSnapshot()
    }
    
    // MARK: - Window/Intensity Controls
    
    public func setHuWindow(min: Int32, max: Int32) async throws {
        let sanitized = Swift.min(min, max)...Swift.max(min, max)
        extendedState.huWindow = sanitized
        try await send(.setWindow(min: sanitized.lowerBound, max: sanitized.upperBound))
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
        logClipPlaneApproximationIfNeeded()
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

    private func validatedRenderState(_ state: VolumeRenderState) throws -> VolumeRenderState {
        var channels = VolumeRenderState.defaultChannels
        for channel in state.channels {
            try validateToneCurveChannel(channel.channel)
            channels[channel.channel] = VolumeRenderChannelState(
                channel: channel.channel,
                intensity: channel.intensity.isFinite ? max(channel.intensity, 0) : 0,
                presetKey: channel.presetKey,
                gain: channel.gain.isFinite ? max(channel.gain, 0) : 1,
                controlPoints: sanitizeToneCurveControlPoints(channel.controlPoints)
            )
        }

        let huWindow = state.huWindow.map {
            Swift.min($0.lowerBound, $0.upperBound)...Swift.max($0.lowerBound, $0.upperBound)
        }
        let huGate = state.huGate.map {
            Swift.min($0.lowerBound, $0.upperBound)...Swift.max($0.lowerBound, $0.upperBound)
        }
        let densityGate = huGate == nil ? state.densityGate.map {
            Swift.min($0.lowerBound, $0.upperBound)...Swift.max($0.lowerBound, $0.upperBound)
        } : nil

        _ = try state.clipBounds.volumeCropBox()
        guard (0...3).contains(state.clipPlane.preset) else {
            throw VolumeClippingError.invalidClipPlanePreset(state.clipPlane.preset)
        }
        guard state.clipPlane.offset.isFinite else {
            throw VolumeClippingError.nonFiniteClipPlane
        }

        return VolumeRenderState(
            huWindow: huWindow,
            earlyTerminationThreshold: VolumetricMath.clampFloat(state.earlyTerminationThreshold,
                                                                 lower: 0,
                                                                 upper: 1),
            densityGate: densityGate,
            huGate: huGate,
            channels: channels,
            adaptiveEnabled: state.adaptiveEnabled,
            adaptiveThreshold: state.adaptiveThreshold.isFinite ? max(state.adaptiveThreshold, 0) : 0,
            jitterAmount: state.jitterAmount.isFinite
                ? VolumetricMath.clampFloat(state.jitterAmount, lower: 0, upper: 1)
                : 0,
            lightingEnabled: state.lightingEnabled,
            samplingStep: state.samplingStep.isFinite && state.samplingStep > 0
                ? state.samplingStep
                : VolumeRenderState.default.samplingStep,
            shift: state.shift.isFinite ? state.shift : 0,
            clipBounds: state.clipBounds,
            clipPlane: state.clipPlane
        )
    }

    private func currentRenderStateSnapshot() -> VolumeRenderState {
        let channels = Self.supportedToneChannelRange.map { channel in
            VolumeRenderChannelState(
                channel: channel,
                intensity: extendedState.channelIntensities[channel],
                presetKey: extendedState.toneCurvePresetKeys[channel] ?? "default",
                gain: extendedState.toneCurveGains[channel] ?? 1,
                controlPoints: extendedState.toneCurvePoints[channel] ?? []
            )
        }
        return VolumeRenderState(
            huWindow: extendedState.huWindow,
            earlyTerminationThreshold: extendedState.earlyTerminationThreshold,
            densityGate: extendedState.densityGate,
            huGate: extendedState.huGate,
            channels: channels,
            adaptiveEnabled: extendedState.adaptiveEnabled,
            adaptiveThreshold: extendedState.adaptiveThreshold,
            jitterAmount: extendedState.jitterAmount,
            lightingEnabled: extendedState.lightingEnabled,
            samplingStep: extendedState.samplingStep,
            shift: extendedState.shift,
            clipBounds: extendedState.clipBounds,
            clipPlane: ClipPlaneSnapshot(preset: extendedState.clipPlanePreset,
                                         offset: extendedState.clipPlaneOffset)
        )
    }

    private func logClipPlaneApproximationIfNeeded() {
        if extendedState.clipPlanePreset != 0 || abs(extendedState.clipPlaneOffset) > 1e-5 {
            if !clipPlaneApproximationLogged {
                logger.info("Clip-plane/quaternion inputs reach MTK adapter; current Metal volume rendering applies axis-aligned clip bounds and preset clip planes.")
                clipPlaneApproximationLogged = true
            }
        }
    }
}
