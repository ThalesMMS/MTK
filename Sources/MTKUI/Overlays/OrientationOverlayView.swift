//  OrientationOverlayView.swift
//  MTK
//  Displays orientation labels for the active MPR plane.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import MTKCore
import SwiftUI

/// A SwiftUI overlay view that displays anatomical orientation labels for medical imaging.
///
/// `OrientationOverlayView` renders four directional labels (top, bottom, leading, trailing)
/// positioned at the edges of the view, providing spatial orientation context for volumetric
/// datasets and Multi-Planar Reconstruction (MPR) visualizations.
///
/// ## Overview
///
/// In medical imaging, orientation labels follow standardized anatomical conventions:
/// - **Axial/Transverse plane** (Z-axis): Anterior (A), Posterior (P), Left (L), Right (R)
/// - **Coronal plane** (Y-axis): Superior (S), Inferior (I), Left (L), Right (R)
/// - **Sagittal plane** (X-axis): Superior (S), Inferior (I), Anterior (A), Posterior (P)
///
/// The view uses a `ZStack` with overlapping `VStack` and `HStack` layouts to position labels
/// at the four cardinal edges. Labels are rendered in a monospaced footnote font for clarity
/// and consistency across different slice orientations.
///
/// ## Usage
///
/// ### Axial plane orientation
///
/// ```swift
/// VolumeViewportContainer(controller: viewportController) {
///     OrientationOverlayView(
///         labels: (
///             leading: "R",   // Right
///             trailing: "L",  // Left
///             top: "A",       // Anterior
///             bottom: "P"     // Posterior
///         )
///     )
/// }
/// ```
///
/// ### Coronal plane orientation
///
/// ```swift
/// OrientationOverlayView(
///     labels: (
///         leading: "R",   // Right
///         trailing: "L",  // Left
///         top: "S",       // Superior
///         bottom: "I"     // Inferior
///     )
/// )
/// ```
///
/// ### Sagittal plane orientation
///
/// ```swift
/// OrientationOverlayView(
///     labels: (
///         leading: "A",   // Anterior
///         trailing: "P",  // Posterior
///         top: "S",       // Superior
///         bottom: "I"     // Inferior
///     )
/// )
/// ```
///
/// ### Dynamic orientation based on MPR axis
///
/// ```swift
/// enum MPRAxis {
///     case axial, coronal, sagittal
///
///     var orientationLabels: (leading: String, trailing: String, top: String, bottom: String) {
///         switch self {
///         case .axial:
///             return ("R", "L", "A", "P")
///         case .coronal:
///             return ("R", "L", "S", "I")
///         case .sagittal:
///             return ("A", "P", "S", "I")
///         }
///     }
/// }
///
/// @State private var currentAxis: MPRAxis = .axial
///
/// var body: some View {
///     VolumeViewportContainer(controller: viewportController) {
///         OrientationOverlayView(labels: currentAxis.orientationLabels)
///     }
///     .onChange(of: mprSliceAxis) { newAxis in
///         currentAxis = newAxis
///     }
/// }
/// ```
///
/// ### Custom styling for high-contrast displays
///
/// ```swift
/// struct HighContrastStyle: VolumetricUIStyle {
///     var overlayBackground: Color { .black.opacity(0.9) }
///     var overlayForeground: Color { .white }
///     // ... other required properties
/// }
///
/// OrientationOverlayView(
///     labels: ("R", "L", "A", "P"),
///     style: HighContrastStyle()
/// )
/// ```
///
/// ## Topics
///
/// ### Creating an Orientation Overlay
/// - ``init(labels:style:)``
///
/// ### Instance Properties
/// - ``body``
///
/// - Note: The overlay is assigned the accessibility identifier `"VolumetricOrientationOverlay"`
///   for UI testing purposes.
/// - Important: Label positioning assumes standard LTR (left-to-right) layout. In RTL locales,
///   SwiftUI may mirror the layout automatically, which could invert leading/trailing labels
///   unless mirroring is explicitly disabled.
public struct OrientationOverlayView: View {
    /// The four directional labels for anatomical orientation.
    ///
    /// A tuple containing labels for the four cardinal edges:
    /// - `leading`: Left edge in LTR layout (typically "R" for right in patient space)
    /// - `trailing`: Right edge in LTR layout (typically "L" for left in patient space)
    /// - `top`: Top edge (typically "A" for anterior or "S" for superior)
    /// - `bottom`: Bottom edge (typically "P" for posterior or "I" for inferior)
    ///
    /// Use single-letter anatomical abbreviations following radiological conventions:
    /// A (Anterior), P (Posterior), L (Left), R (Right), S (Superior), I (Inferior).
    private let labels: (leading: String, trailing: String, top: String, bottom: String)

    /// The styling configuration for label appearance.
    ///
    /// Controls background, foreground, and other visual properties via the
    /// ``VolumetricUIStyle`` protocol.
    private let style: any VolumetricUIStyle

    /// Creates an orientation overlay with four anatomical direction labels.
    ///
    /// - Parameters:
    ///   - labels: A tuple of four directional labels positioned at the view edges.
    ///     Use single-letter anatomical abbreviations (A, P, L, R, S, I) following
    ///     radiological conventions for the active MPR plane.
    ///   - style: The visual style configuration. Defaults to ``DefaultVolumetricUIStyle``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Axial plane (transverse slice)
    /// OrientationOverlayView(
    ///     labels: (
    ///         leading: "R",   // Patient's right
    ///         trailing: "L",  // Patient's left
    ///         top: "A",       // Anterior (front)
    ///         bottom: "P"     // Posterior (back)
    ///     )
    /// )
    ///
    /// // Coronal plane
    /// OrientationOverlayView(
    ///     labels: (
    ///         leading: "R",   // Patient's right
    ///         trailing: "L",  // Patient's left
    ///         top: "S",       // Superior (head)
    ///         bottom: "I"     // Inferior (feet)
    ///     )
    /// )
    ///
    /// // Sagittal plane
    /// OrientationOverlayView(
    ///     labels: (
    ///         leading: "A",   // Anterior (front)
    ///         trailing: "P",  // Posterior (back)
    ///         top: "S",       // Superior (head)
    ///         bottom: "I"     // Inferior (feet)
    ///     )
    /// )
    /// ```
    public init(labels: (leading: String, trailing: String, top: String, bottom: String),
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.labels = labels
        self.style = style
    }

    /// Creates an orientation overlay from a derived MPR display transform.
    ///
    /// - Parameters:
    ///   - transform: The display transform that already resolved screen-edge labels.
    ///   - style: The visual style configuration. Defaults to ``DefaultVolumetricUIStyle``.
    public init(transform: MPRDisplayTransform,
                style: any VolumetricUIStyle = DefaultVolumetricUIStyle()) {
        self.init(labels: transform.labels, style: style)
    }

    /// The SwiftUI view hierarchy rendering the orientation labels.
    ///
    /// Uses a `ZStack` to overlay perpendicular `VStack` (top/bottom labels) and `HStack`
    /// (leading/trailing labels) layouts. Labels are rendered in monospaced footnote font
    /// for consistent spacing and readability.
    ///
    /// - Important: The container is assigned the accessibility identifier
    ///   `"VolumetricOrientationOverlay"` for UI testing.
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
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityIdentifier("VolumetricOrientationOverlay")
    }
}
#endif
