import Foundation
import CoreGraphics

/// High-level configuration for a volumetric viewport UI.
///
/// Downstream apps can use this type to keep viewport controls (gestures/overlays/defaults)
/// cohesive and pass them around as a single value.
public struct VolumeViewportConfiguration: Sendable, Equatable {
    public var overlays: VolumeViewportOverlayConfiguration
    public var gestures: VolumeGestureConfiguration
    public var windowLevel: VolumeViewportWindowLevelConfiguration
    public var crosshair: VolumeViewportCrosshairConfiguration

    public init(overlays: VolumeViewportOverlayConfiguration = .default,
                gestures: VolumeGestureConfiguration = .default,
                windowLevel: VolumeViewportWindowLevelConfiguration = .default,
                crosshair: VolumeViewportCrosshairConfiguration = .default) {
        self.overlays = overlays
        self.gestures = gestures
        self.windowLevel = windowLevel
        self.crosshair = crosshair
    }

    public static let `default` = VolumeViewportConfiguration()
}

public struct VolumeViewportOverlayConfiguration: Sendable, Equatable {
    public var showsCrosshair: Bool
    public var showsOrientationLabels: Bool
    public var showsGestureOverlay: Bool
    public var orientationLabels: MPRLabels

    public init(showsCrosshair: Bool = true,
                showsOrientationLabels: Bool = true,
                showsGestureOverlay: Bool = false,
                orientationLabels: MPRLabels = MPRLabels(leading: "L", trailing: "R", top: "A", bottom: "P")) {
        self.showsCrosshair = showsCrosshair
        self.showsOrientationLabels = showsOrientationLabels
        self.showsGestureOverlay = showsGestureOverlay
        self.orientationLabels = orientationLabels
    }

    public static let `default` = VolumeViewportOverlayConfiguration()
}

public struct VolumeViewportWindowLevelConfiguration: Sendable, Equatable {
    public var defaultWindow: Double
    public var defaultLevel: Double

    public init(defaultWindow: Double = 400,
                defaultLevel: Double = 40) {
        self.defaultWindow = defaultWindow
        self.defaultLevel = defaultLevel
    }

    public static let `default` = VolumeViewportWindowLevelConfiguration()
}

public struct VolumeViewportCrosshairConfiguration: Sendable, Equatable {
    public var lineWidth: CGFloat

    public init(lineWidth: CGFloat = 1) {
        self.lineWidth = lineWidth
    }

    public static let `default` = VolumeViewportCrosshairConfiguration()
}
