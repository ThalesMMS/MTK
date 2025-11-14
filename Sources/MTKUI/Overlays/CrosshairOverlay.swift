//  CrosshairOverlay.swift
//  MTK
//  Convenience wrapper around CrosshairOverlayView for opt-in overlays.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public struct CrosshairOverlay: View {
    private let style: any VolumetricUIStyle
    private let offset: CGPoint

    public init(style: any VolumetricUIStyle = DefaultVolumetricUIStyle(),
                offset: CGPoint = .zero) {
        self.style = style
        self.offset = offset
    }

    public var body: some View {
        CrosshairOverlayView(style: style, position: offset)
    }
}
#endif
