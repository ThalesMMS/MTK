import Foundation
import SwiftUI
import MTKCore

public struct MPRImageAnnotationSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    public var displayText: String {
        "\(width)x\(height)"
    }
}

public struct MPRImageAnnotationsOverlayState: Equatable, Sendable {
    public var panelNumber: Int
    public var axis: MTKCore.Axis
    public var imageSize: MPRImageAnnotationSize?
    public var windowLevel: WindowLevelShift
    public var slabThickness: Double
    public var zoom: Float
    public var angleDegrees: Double

    public init(panelNumber: Int,
                axis: MTKCore.Axis,
                imageSize: MPRImageAnnotationSize? = nil,
                windowLevel: WindowLevelShift,
                slabThickness: Double,
                zoom: Float,
                angleDegrees: Double) {
        self.panelNumber = max(panelNumber, 1)
        self.axis = axis
        self.imageSize = imageSize
        self.windowLevel = WindowLevelShift(window: windowLevel.window.isFinite ? windowLevel.window : 0,
                                            level: windowLevel.level.isFinite ? windowLevel.level : 0)
        self.slabThickness = slabThickness.isFinite ? max(slabThickness, 0) : 0
        self.zoom = zoom.isFinite ? max(zoom, 0) : 0
        self.angleDegrees = angleDegrees.isFinite ? angleDegrees : 0
    }

    public var topLines: [String] {
        var lines = ["Panel \(panelNumber)"]
        if let imageSize {
            lines.append("Image size: \(imageSize.displayText)")
        }
        lines.append("WW: \(formatted(windowLevel.window)) WL: \(formatted(windowLevel.level))")
        lines.append("Orientation: \(axisDisplayName)")
        return lines
    }

    public var bottomLines: [String] {
        [
            "Thickness: \(formatted(slabThickness)) mm",
            "Zoom: \(formatted(Double(zoom * 100)))%",
            "Angle: \(formatted(angleDegrees)) deg"
        ]
    }

    public var displayLines: [String] {
        topLines + bottomLines
    }

    public var axisIdentifier: String {
        switch axis {
        case .axial:
            return "axial"
        case .coronal:
            return "coronal"
        case .sagittal:
            return "sagittal"
        }
    }

    private var axisDisplayName: String {
        switch axis {
        case .axial:
            return "Axial"
        case .coronal:
            return "Coronal"
        case .sagittal:
            return "Sagittal"
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

public struct MPRImageAnnotationsOverlay: View {
    private let state: MPRImageAnnotationsOverlayState
    private let style: any VolumetricUIStyle

    public init(state: MPRImageAnnotationsOverlayState,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.state = state
        self.style = style
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            annotationBlock(lines: state.topLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            annotationBlock(lines: state.bottomLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MPRImageAnnotationsOverlay.\(state.axisIdentifier)")
    }

    private func annotationBlock(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(style.overlayForeground)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(style.overlayBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
