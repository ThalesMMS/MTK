//  WindowLevelControlView.swift
//  MTK
//  Basic window/level slider pair for volumetric sessions.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public struct WindowLevelControlView: View {
    @Binding private var level: Double
    @Binding private var window: Double
    private let style: any VolumetricUIStyle
    private let onCommit: () -> Void

    public init(level: Binding<Double>, window: Binding<Double>, style: any VolumetricUIStyle = DefaultVolumetricUIStyle(), onCommit: @escaping () -> Void = {}) {
        _level = level
        _window = window
        self.style = style
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Level: \(Int(level))")
            Slider(value: $level, in: -2048...2048, step: 1) { } onEditingChanged: { editing in
                if !editing { onCommit() }
            }
            Text("Window: \(Int(window))")
            Slider(value: $window, in: 1...4096, step: 1) { } onEditingChanged: { editing in
                if !editing { onCommit() }
            }
        }
        .padding(8)
        .background(style.overlayBackground.cornerRadius(8))
        .foregroundStyle(style.overlayForeground)
        .accessibilityIdentifier("VolumetricWindowLevelControls")
    }
}
#endif

