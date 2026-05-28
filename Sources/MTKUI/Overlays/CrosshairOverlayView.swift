//  CrosshairOverlayView.swift
//  MTK
//  Minimal SwiftUI crosshair overlay aligned to the dataset center.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

/// A SwiftUI overlay view that renders crosshair guides for volumetric visualization.
///
/// `CrosshairOverlayView` displays perpendicular horizontal and vertical lines that intersect
/// at the center of the view (with optional offset). This provides visual reference for dataset
/// alignment, MPR slice navigation, or cursor tracking in medical imaging applications.
///
/// ## Overview
///
/// The crosshair is rendered using SwiftUI's `Path` API, creating two full-width/height lines
/// that span the entire view bounds. The intersection point defaults to the geometric center
/// but can be offset via the `position` parameter for dynamic cursor tracking or alignment.
///
/// Visual styling is controlled by a ``VolumetricUIStyle`` protocol implementation, allowing
/// customization of crosshair color and line width. The default style uses the accent color
/// with 1pt line width.
///
/// ## Usage
///
/// ### Basic centered crosshair
///
/// ```swift
/// VolumeViewportContainer(controller: viewportController) {
///     CrosshairOverlayView()
/// }
/// ```
///
/// ### Crosshair with custom style
///
/// ```swift
/// struct CustomStyle: VolumetricUIStyle {
///     var crosshairColor: Color { .green }
///     var lineWidth: CGFloat { 2.0 }
///     // ... other required properties
/// }
///
/// CrosshairOverlayView(style: CustomStyle())
/// ```
///
/// ### Offset crosshair for cursor tracking
///
/// ```swift
/// @State private var cursorOffset: CGPoint = .zero
///
/// var body: some View {
///     VolumeViewportContainer(controller: viewportController) {
///         CrosshairOverlayView(position: cursorOffset)
///     }
///     .gesture(
///         DragGesture()
///             .onChanged { value in
///                 // Track cursor relative to view center
///                 cursorOffset = CGPoint(
///                     x: value.location.x - viewSize.width / 2,
///                     y: value.location.y - viewSize.height / 2
///                 )
///             }
///     )
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Crosshair Overlay
/// - ``init(style:position:)``
///
/// ### Instance Properties
/// - ``body``
///
/// - Note: The crosshair uses the accessibility identifier `"VolumetricCrosshair"` by default for
///   UI testing purposes.
public struct CrosshairOverlayView: View {
    /// The styling configuration for crosshair appearance.
    ///
    /// Controls the color and line width of the rendered crosshair lines via the
    /// ``VolumetricUIStyle`` protocol.
    private let style: any VolumetricUIStyle

    /// Offset from the geometric center for crosshair intersection.
    ///
    /// Expressed in points relative to the view's center in the displayed screen space.
    /// Positive x moves right, positive y moves down. Controllers must pre-apply any MPR
    /// display transform so the crosshair stays aligned with the presented texture.
    private let position: CGPoint

    /// Visual angle to rotate/tilt the crosshair lines.
    private let angle: Angle

    /// Accessibility identifier assigned to the rendered crosshair.
    private let accessibilityIdentifier: String

    /// Creates a crosshair overlay with optional styling, position offset, and rotation angle.
    ///
    /// - Parameters:
    ///   - style: The visual style configuration. Defaults to ``DefaultVolumetricUIStyle``.
    ///   - position: Offset from the view center for crosshair intersection. Defaults to `.zero`
    ///     for a centered crosshair. Use non-zero offsets for cursor tracking or alignment guides.
    ///   - angle: Visual angle to rotate/tilt the crosshair lines around their intersection center. Defaults to `.zero`.
    ///   - accessibilityIdentifier: Identifier exposed for UI automation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Centered crosshair with default style
    /// CrosshairOverlayView()
    ///
    /// // Offset crosshair with custom styling and rotation
    /// CrosshairOverlayView(
    ///     style: CustomStyle(),
    ///     position: CGPoint(x: 10, y: -5),
    ///     angle: Angle(degrees: 15)
    /// )
    /// ```
    public init(style: any VolumetricUIStyle = DefaultVolumetricUIStyle(),
                position: CGPoint = .zero,
                angle: Angle = .zero,
                accessibilityIdentifier: String = "VolumetricCrosshair") {
        self.style = style
        self.position = position
        self.angle = angle
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// The SwiftUI view hierarchy rendering the crosshair lines.
    ///
    /// Uses `GeometryReader` to obtain the view's size, then draws two perpendicular lines
    /// (horizontal and vertical) that span the entire view bounds and intersect at the
    /// calculated center point (geometric center plus `position` offset).
    ///
    /// - Important: The rendered path is assigned the configured accessibility identifier.
    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2 + position.x, y: size.height / 2 + position.y)
            let anchorX = size.width > 0 ? center.x / size.width : 0.5
            let anchorY = size.height > 0 ? center.y / size.height : 0.5
            Path { path in
                path.move(to: CGPoint(x: center.x, y: 0))
                path.addLine(to: CGPoint(x: center.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: center.y))
                path.addLine(to: CGPoint(x: size.width, y: center.y))
            }
            .stroke(style.crosshairColor, style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
            .rotationEffect(angle, anchor: UnitPoint(x: anchorX, y: anchorY))
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
#endif
