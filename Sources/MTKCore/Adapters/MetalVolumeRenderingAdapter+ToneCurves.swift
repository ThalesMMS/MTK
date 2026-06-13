//
//  MetalVolumeRenderingAdapter+ToneCurves.swift
//  MTK
//
//  Tone curve buffer preparation for the Metal volume rendering adapter.
//
//  Thales Matheus Mendonça Santos — June 2026

import Metal
import simd

extension MetalVolumeRenderingAdapter {
    static let supportedToneChannelRange = 0..<4

    func validateToneCurveChannel(_ channel: Int) throws {
        guard Self.supportedToneChannelRange.contains(channel) else {
            throw AdapterError.invalidToneCurveChannel(channel)
        }
    }

    func sanitizeToneCurveControlPoints(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard !points.isEmpty else { return [] }
        let usesByteRange = points.contains { $0.x > 1 }
        return points.map { point in
            let x = usesByteRange ? point.x / 255 : point.x
            return SIMD2<Float>(
                VolumetricMath.clampFloat(x, lower: 0, upper: 1),
                VolumetricMath.clampFloat(point.y, lower: 0, upper: 1)
            )
        }
        .sorted { $0.x < $1.x }
    }

    func makeToneBuffers(state: MetalState) throws -> VolumeRaycastToneBuffers {
        try VolumeRaycastToneBuffers(
            channel1: makeToneBuffer(forChannel: 0, state: state),
            channel2: makeToneBuffer(forChannel: 1, state: state),
            channel3: makeToneBuffer(forChannel: 2, state: state),
            channel4: makeToneBuffer(forChannel: 3, state: state)
        )
    }

    func makeToneBuffer(forChannel channel: Int,
                        state: MetalState) throws -> (any MTLBuffer)? {
        let points = extendedState.toneCurvePoints[channel] ?? []
        let gain = extendedState.toneCurveGains[channel] ?? 1
        guard !points.isEmpty || abs(gain - 1) > 1e-6 else {
            state.toneBufferCache[channel] = nil
            return nil
        }

        if let cached = state.toneBufferCache[channel],
           cached.points == points,
           cached.gain == gain {
            return cached.buffer
        }

        let samples = sampledToneValues(points: points, gain: gain)
        let byteCount = samples.count * MemoryLayout<Float>.stride
        let buffer: (any MTLBuffer)?
        if let cached = state.toneBufferCache[channel],
           cached.buffer.length >= byteCount {
            samples.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    cached.buffer.contents().copyMemory(from: baseAddress, byteCount: byteCount)
                }
            }
            buffer = cached.buffer
        } else {
            buffer = samples.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
                guard let baseAddress = pointer.baseAddress else { return nil }
                return state.device.makeBuffer(bytes: baseAddress,
                                               length: byteCount,
                                               options: [.storageModeShared])
            }
        }
        guard let buffer else {
            throw RenderingError.toneBufferUnavailable
        }
        buffer.label = "VolumeCompute.ToneCurve.Ch\(channel + 1)"
        state.toneBufferCache[channel] = MetalState.ToneBufferCacheEntry(
            points: points,
            gain: gain,
            buffer: buffer
        )
        return buffer
    }

    func sampledToneValues(points: [SIMD2<Float>],
                           gain: Float) -> [Float] {
        let safeGain = gain.isFinite ? max(gain, 0) : 1
        guard !points.isEmpty else {
            return Array(repeating: VolumetricMath.clampFloat(safeGain, lower: 0, upper: 1),
                         count: AdvancedToneCurveModel.sampleCount)
        }
        guard points.count > 1 else {
            let value = VolumetricMath.clampFloat(points[0].y * safeGain, lower: 0, upper: 1)
            return Array(repeating: value, count: AdvancedToneCurveModel.sampleCount)
        }

        let modelPoints = points.map {
            AdvancedToneCurvePoint(
                x: VolumetricMath.clampFloat($0.x, lower: 0, upper: 1) * AdvancedToneCurveModel.xRange.upperBound,
                y: VolumetricMath.clampFloat($0.y, lower: 0, upper: 1)
            )
        }
        let model = AdvancedToneCurveModel(points: modelPoints)
        let values = model.sampledValues()
        return values.map {
            VolumetricMath.clampFloat($0 * safeGain, lower: 0, upper: 1)
        }
    }
}
