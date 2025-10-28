//  OrientationOverlayView.swift
//  MTK
//  Displays orientation labels for the active MPR plane.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public struct OrientationOverlayView: View {
    private let labels: (leading: String, trailing: String, top: String, bottom: String)
    private let style: any VolumetricUIStyle

    public init(labels: (leading: String, trailing: String, top: String, bottom: String),
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.labels = labels
        self.style = style
    }

    public var body: some View {
        ZStack {
            VStack {
                Text(labels.top)
                Spacer()
                Text(labels.bottom)
            }
            HStack {
                Text(labels.leading)
                Spacer()
                Text(labels.trailing)
            }
        }
        .font(.footnote.monospaced())
        .foregroundStyle(style.overlayForeground)
        .padding(8)
        .background(style.overlayBackground.cornerRadius(8))
        .accessibilityIdentifier("VolumetricOrientationOverlay")
    }
}
#endif

