import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum Volume3DCropToolMenu {
    public static var menu: ViewerToolMenu {
        ViewerToolMenu(title: "Crop", items: [
            ViewerToolMenuItem(id: "volume3d-crop-reset",
                               title: "Reset",
                               systemImage: "arrow.counterclockwise",
                               action: .reset3DCropClip),
            ViewerToolMenuItem(id: "volume3d-crop-select",
                               title: "Select Crop tool",
                               systemImage: "crop",
                               action: .selectTool(.crop))
        ])
    }
}

public struct Volume3DCropOverlayState: Equatable, Sendable {
    public var yMin: Double
    public var yMax: Double

    public init(yMin: Double, yMax: Double) {
        let clampedMin = min(max(yMin, 0), 1)
        let clampedMax = min(max(yMax, 0), 1)
        self.yMin = min(clampedMin, clampedMax)
        self.yMax = max(clampedMin, clampedMax)
    }
}

#if canImport(SwiftUI)
public struct Volume3DCropOverlayLayout: Equatable {
    public var topInsetFraction: CGFloat
    public var bottomInsetFraction: CGFloat

    public init(topInsetFraction: CGFloat = 0.14,
                bottomInsetFraction: CGFloat = 0.86) {
        self.topInsetFraction = min(max(topInsetFraction, 0), 1)
        self.bottomInsetFraction = min(max(bottomInsetFraction, self.topInsetFraction), 1)
    }

    public func yPosition(forBound value: Double, height: CGFloat) -> CGFloat {
        let top = height * topInsetFraction
        let bottom = height * bottomInsetFraction
        let clamped = CGFloat(min(max(value, 0), 1))
        return top + (1 - clamped) * (bottom - top)
    }

    public func boundValue(forY y: CGFloat, height: CGFloat) -> Double {
        let top = height * topInsetFraction
        let bottom = height * bottomInsetFraction
        guard bottom > top else { return 0.5 }
        let clampedY = min(max(y, top), bottom)
        let verticalProgress = (clampedY - top) / (bottom - top)
        return Double(1 - verticalProgress)
    }
}

public struct Volume3DCropOverlay: View {
    private let state: Volume3DCropOverlayState
    private let layout: Volume3DCropOverlayLayout
    private let onCropBoundChange: (ClinicalViewerCropAxis, Bool, Double) -> Void

    public init(state: Volume3DCropOverlayState,
                layout: Volume3DCropOverlayLayout = Volume3DCropOverlayLayout(),
                onCropBoundChange: @escaping (ClinicalViewerCropAxis, Bool, Double) -> Void) {
        self.state = state
        self.layout = layout
        self.onCropBoundChange = onCropBoundChange
    }

    public var body: some View {
        GeometryReader { proxy in
            let topY = layout.yPosition(forBound: state.yMax, height: proxy.size.height)
            let bottomY = layout.yPosition(forBound: state.yMin, height: proxy.size.height)

            ZStack {
                cropLine(y: topY, width: proxy.size.width)
                cropLine(y: bottomY, width: proxy.size.width)

                handle(y: topY,
                       width: proxy.size.width,
                       accessibilityIdentifier: "Volume3DCropOverlay.topHandle",
                       isMin: false,
                       height: proxy.size.height)
                handle(y: bottomY,
                       width: proxy.size.width,
                       accessibilityIdentifier: "Volume3DCropOverlay.bottomHandle",
                       isMin: true,
                       height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityIdentifier("Volume3DCropOverlay")
    }

    private func cropLine(y: CGFloat, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 16, y: y))
            path.addLine(to: CGPoint(x: max(16, width - 16), y: y))
        }
        .stroke(Color.white.opacity(0.92), lineWidth: 3)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    private func handle(y: CGFloat,
                        width: CGFloat,
                        accessibilityIdentifier: String,
                        isMin: Bool,
                        height: CGFloat) -> some View {
        Circle()
            .fill(Color.red.opacity(0.78))
            .frame(width: 34, height: 34)
            .overlay {
                Circle()
                    .strokeBorder(Color.red.opacity(0.95), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
            .contentShape(Circle())
            .frame(width: 56, height: 56)
            .position(x: width / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let rawBound = layout.boundValue(forY: value.location.y, height: height)
                        let clampedBound = isMin ? min(rawBound, state.yMax) : max(rawBound, state.yMin)
                        onCropBoundChange(.y, isMin, clampedBound)
                    }
            )
            .accessibilityLabel(isMin ? "Inferior crop handle" : "Superior crop handle")
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#endif
