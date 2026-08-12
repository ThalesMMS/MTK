//
//  VolumeRenderChannelState.swift
//  MTKCore
//
//  Public channel state for cohesive volume renderer configuration.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import simd

public struct VolumeRenderChannelState: Sendable, Equatable {
    public var channel: Int
    public var intensity: Float
    public var presetKey: String
    public var gain: Float
    public var controlPoints: [SIMD2<Float>]

    public init(channel: Int,
                intensity: Float = 0,
                presetKey: String = "default",
                gain: Float = 1,
                controlPoints: [SIMD2<Float>] = []) {
        self.channel = channel
        self.intensity = intensity
        self.presetKey = presetKey
        self.gain = gain
        self.controlPoints = controlPoints
    }
}
