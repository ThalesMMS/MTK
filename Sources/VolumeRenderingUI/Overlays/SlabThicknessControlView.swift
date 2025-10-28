//  SlabThicknessControlView.swift
//  MTK
//  Simple slider for slab thickness adjustments in MPR mode.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

public struct SlabThicknessControlView: View {
    @Binding private var thickness: Double
    private let range: ClosedRange<Double>
    private let style: any VolumetricUIStyle
    private let onCommit: (Double) -> Void

    public init(thickness: Binding<Double>,
                range: ClosedRange<Double> = 1...128,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle(),
                onCommit: @escaping (Double) -> Void = { _ in }) {
        _thickness = thickness
        self.range = range
        self.style = style
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Slab Thickness: \(Int(thickness))")
            Slider(value: $thickness, in: range, step: 1) { } onEditingChanged: { editing in
                if !editing { onCommit(thickness) }
            }
        }
        .padding(8)
        .background(style.overlayBackground.cornerRadius(8))
        .foregroundStyle(style.overlayForeground)
        .accessibilityIdentifier("VolumetricSlabControls")
    }
}
#endif

