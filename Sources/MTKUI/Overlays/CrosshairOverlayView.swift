//  CrosshairOverlayView.swift
//  MTK
//  Minimal SwiftUI crosshair overlay aligned to the dataset center.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public struct CrosshairOverlayView: View {
    private let style: any VolumetricUIStyle
    private let position: CGPoint

    public init(style: any VolumetricUIStyle = DefaultVolumetricUIStyle(), position: CGPoint = .zero) {
        self.style = style
        self.position = position
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2 + position.x, y: size.height / 2 + position.y)
            Path { path in
                path.move(to: CGPoint(x: center.x, y: 0))
                path.addLine(to: CGPoint(x: center.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: center.y))
                path.addLine(to: CGPoint(x: size.width, y: center.y))
            }
            .stroke(style.crosshairColor, style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
        }
        .accessibilityIdentifier("VolumetricCrosshair")
    }
}
#endif

