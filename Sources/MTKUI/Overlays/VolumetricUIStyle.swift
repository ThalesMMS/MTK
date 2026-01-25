//  VolumetricUIStyle.swift
//  MTK
//  Lightweight styling contract for overlay components.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public protocol VolumetricUIStyle {
    var crosshairColor: Color { get }
    var scalebarColor: Color { get }
    var overlayBackground: Color { get }
    var overlayForeground: Color { get }
    var lineWidth: CGFloat { get }
}

public struct DefaultVolumetricUIStyle: VolumetricUIStyle {
    public init() {}

    public var crosshairColor: Color { .accentColor }
    public var scalebarColor: Color { .secondary }
    public var overlayBackground: Color { Color.black.opacity(0.55) }
    public var overlayForeground: Color { .primary }
    public var lineWidth: CGFloat { 1.0 }
}
#endif

