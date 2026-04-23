//  WindowLevelControlView.swift
//  MTK
//  Basic window/level slider pair for volumetric sessions.
//  Thales Matheus Mendonça Santos — October 2025

#if canImport(SwiftUI)
import SwiftUI

/// A SwiftUI overlay view providing interactive window/level adjustment controls for medical imaging.
///
/// `WindowLevelControlView` presents two sliders for adjusting the window width and level center
/// of the display intensity mapping, a fundamental operation in radiology for optimizing tissue
/// contrast visualization in CT and MR imaging.
///
/// ## Overview
///
/// The window/level technique maps a subset of the dataset's intensity range to the full display
/// range, enhancing contrast for specific tissue types:
/// - **Level** (center): The Hounsfield Unit (HU) value mapped to middle gray (50% intensity)
/// - **Window** (width): The range of HU values mapped from black to white
///
/// This view provides real-time slider adjustment with optional commit callbacks for triggering
/// transfer function updates or rendering invalidation. Slider ranges are preset for typical
/// CT imaging (-2048 to +2048 HU for level, 1 to 4096 HU for window).
///
/// ## Usage
///
/// ### Basic window/level controls
///
/// ```swift
/// @State private var level: Double = 40  // Soft tissue center
/// @State private var window: Double = 400  // Soft tissue width
///
/// var body: some View {
///     VolumeViewportContainer(controller: viewportController) {
///         WindowLevelControlView(
///             level: $level,
///             window: $window,
///             onCommit: applyWindowLevel
///         )
///     }
/// }
///
/// func applyWindowLevel() {
///     let mapping = VolumetricHUWindowMapping.makeHuWindowMapping(
///         minHU: level - window / 2,
///         maxHU: level + window / 2,
///         datasetRange: dataset.intensityRange,
///         transferDomain: nil
///     )
///     Task {
///         await viewportController.setHuWindow(mapping)
///     }
/// }
/// ```
///
/// ### Custom styling with preset selection
///
/// ```swift
/// struct CustomStyle: VolumetricUIStyle {
///     var overlayBackground: Color { Color.black.opacity(0.7) }
///     var overlayForeground: Color { .white }
///     // ... other required properties
/// }
///
/// WindowLevelControlView(
///     level: $level,
///     window: $window,
///     style: CustomStyle()
/// ) {
///     print("User finished adjusting window/level")
///     applyToRenderer()
/// }
/// ```
///
/// ### Integration with window/level presets
///
/// ```swift
/// enum WindowLevelPreset: String, CaseIterable {
///     case softTissue = "Soft Tissue"
///     case lung = "Lung"
///     case bone = "Bone"
///
///     var values: (level: Double, window: Double) {
///         switch self {
///         case .softTissue: return (40, 400)
///         case .lung: return (-600, 1500)
///         case .bone: return (400, 1800)
///         }
///     }
/// }
///
/// @State private var level: Double = 40
/// @State private var window: Double = 400
/// @State private var selectedPreset: WindowLevelPreset = .softTissue
///
/// var body: some View {
///     VolumeViewportContainer(controller: viewportController) {
///         VStack {
///             Picker("Preset", selection: $selectedPreset) {
///                 ForEach(WindowLevelPreset.allCases, id: \.self) { preset in
///                     Text(preset.rawValue).tag(preset)
///                 }
///             }
///             .onChange(of: selectedPreset) { newPreset in
///                 let values = newPreset.values
///                 level = values.level
///                 window = values.window
///                 applyWindowLevel()
///             }
///
///             WindowLevelControlView(
///                 level: $level,
///                 window: $window,
///                 onCommit: applyWindowLevel
///             )
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating Window/Level Controls
/// - ``init(level:window:style:onCommit:)``
///
/// ### Instance Properties
/// - ``body``
///
/// - Note: The control container is assigned the accessibility identifier
///   `"VolumetricWindowLevelControls"` for UI testing.
/// - Important: The `onCommit` closure is invoked only when the user finishes dragging a slider
///   (on `onEditingChanged: false`), not on every value change. Use SwiftUI's `.onChange(of:)`
///   modifier on the bindings for continuous updates during dragging.
public struct WindowLevelControlView: View {
    /// Two-way binding to the level (center) value in Hounsfield Units.
    ///
    /// Represents the intensity value mapped to middle gray in the display range.
    /// Valid range: -2048 to +2048 HU (typical CT range).
    @Binding private var level: Double

    /// Two-way binding to the window (width) value in Hounsfield Units.
    ///
    /// Represents the range of intensities mapped from black to white in the display.
    /// Valid range: 1 to 4096 HU (clamped to positive values).
    @Binding private var window: Double

    /// The styling configuration for control appearance.
    ///
    /// Controls background, foreground, and other visual properties via the
    /// ``VolumetricUIStyle`` protocol.
    private let style: any VolumetricUIStyle

    /// Callback invoked when the user finishes adjusting a slider.
    ///
    /// Triggered on `onEditingChanged: false` events, allowing deferred updates to avoid
    /// excessive rendering invalidation during continuous slider dragging.
    private let onCommit: () -> Void

    /// Creates window/level adjustment controls with two-way bindings and optional commit callback.
    ///
    /// - Parameters:
    ///   - level: Two-way binding to the level (center) value. Valid range: -2048 to +2048 HU.
    ///   - window: Two-way binding to the window (width) value. Valid range: 1 to 4096 HU.
    ///   - style: The visual style configuration. Defaults to ``DefaultVolumetricUIStyle``.
    ///   - onCommit: Closure invoked when the user finishes dragging a slider. Defaults to no-op.
    ///     Use this to apply window/level changes to the renderer or transfer function.
    ///
    /// ## Example
    ///
    /// ```swift
    /// WindowLevelControlView(
    ///     level: $centerHU,
    ///     window: $widthHU,
    ///     onCommit: {
    ///         Task {
    ///             await controller.setHuWindow(
    ///                 VolumetricHUWindowMapping.makeHuWindowMapping(
    ///                     minHU: centerHU - widthHU / 2,
    ///                     maxHU: centerHU + widthHU / 2,
    ///                     datasetRange: dataset.intensityRange,
    ///                     transferDomain: nil
    ///                 )
    ///             )
    ///         }
    ///     }
    /// )
    /// ```
    public init(level: Binding<Double>, window: Binding<Double>, style: any VolumetricUIStyle = DefaultVolumetricUIStyle(), onCommit: @escaping () -> Void = {}) {
        _level = level
        _window = window
        self.style = style
        self.onCommit = onCommit
    }

    /// The SwiftUI view hierarchy rendering the window/level sliders.
    ///
    /// Displays two labeled sliders in a vertical stack:
    /// - **Level slider**: Range -2048 to +2048 HU, step 1
    /// - **Window slider**: Range 1 to 4096 HU, step 1
    ///
    /// Each slider shows the current integer value in a label above. The `onCommit` closure
    /// is invoked when the user releases the slider thumb (on `onEditingChanged: false`).
    ///
    /// - Important: The container is assigned the accessibility identifier
    ///   `"VolumetricWindowLevelControls"` for UI testing.
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
