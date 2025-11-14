//
//  ToneCurveExtensions.swift
//  MTK
//
//  Extensions for tone curve management
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation
import simd
import MTKCore

public struct ToneCurveConfiguration: Sendable, Equatable {
    public let controlPoints: [SIMD2<Float>]
    public let gain: Float
    public let channel: Int
    
    public init(controlPoints: [SIMD2<Float>], gain: Float, channel: Int) {
        self.controlPoints = controlPoints
        self.gain = gain
        self.channel = channel
    }
    
    public static let `default` = ToneCurveConfiguration(
        controlPoints: [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 1)
        ],
        gain: 1.0,
        channel: 0
    )
}

public extension VolumeRenderingPortExtended {
    
    func applyToneCurveConfiguration(_ config: ToneCurveConfiguration) async throws {
        try await setToneCurveControlPoints(config.controlPoints, forChannel: config.channel)
        try await setToneCurveGain(config.gain, forChannel: config.channel)
    }
    
    func getCurrentToneCurveConfiguration(forChannel channel: Int) async throws -> ToneCurveConfiguration {
        let snapshot = try await getToneCurveSnapshot()
        guard channel < snapshot.count else {
            return .default
        }
        
        let channelSnapshot = snapshot[channel]
        return ToneCurveConfiguration(
            controlPoints: channelSnapshot.controlPoints,
            gain: channelSnapshot.gain,
            channel: channel
        )
    }
}
