//
//  VolumeRenderState.swift
//  MTK
//
//  Cohesive public volume renderer configuration state.
//

public struct VolumeRenderState: Sendable, Equatable {
    public static let defaultChannels = [
        VolumeRenderChannelState(channel: 0, intensity: 1),
        VolumeRenderChannelState(channel: 1, intensity: 0),
        VolumeRenderChannelState(channel: 2, intensity: 0),
        VolumeRenderChannelState(channel: 3, intensity: 0)
    ]

    public static let `default` = VolumeRenderState()

    public var huWindow: ClosedRange<Int32>?
    public var earlyTerminationThreshold: Float
    public var densityGate: ClosedRange<Float>?
    public var huGate: ClosedRange<Int32>?
    public var channels: [VolumeRenderChannelState]
    public var adaptiveEnabled: Bool
    public var adaptiveThreshold: Float
    public var jitterAmount: Float
    public var lightingEnabled: Bool
    public var samplingStep: Float
    public var shift: Float
    public var clipBounds: ClipBoundsSnapshot
    public var clipPlane: ClipPlaneSnapshot

    public init(huWindow: ClosedRange<Int32>? = nil,
                earlyTerminationThreshold: Float = 0.95,
                densityGate: ClosedRange<Float>? = nil,
                huGate: ClosedRange<Int32>? = nil,
                channels: [VolumeRenderChannelState]? = nil,
                adaptiveEnabled: Bool = false,
                adaptiveThreshold: Float = 0,
                jitterAmount: Float = 0,
                lightingEnabled: Bool = true,
                samplingStep: Float = 1.0 / 512.0,
                shift: Float = 0,
                clipBounds: ClipBoundsSnapshot = .default,
                clipPlane: ClipPlaneSnapshot = .default) {
        self.huWindow = huWindow
        self.earlyTerminationThreshold = earlyTerminationThreshold
        self.densityGate = densityGate
        self.huGate = huGate
        self.channels = channels ?? Self.defaultChannels
        self.adaptiveEnabled = adaptiveEnabled
        self.adaptiveThreshold = adaptiveThreshold
        self.jitterAmount = jitterAmount
        self.lightingEnabled = lightingEnabled
        self.samplingStep = samplingStep
        self.shift = shift
        self.clipBounds = clipBounds
        self.clipPlane = clipPlane
    }
}
