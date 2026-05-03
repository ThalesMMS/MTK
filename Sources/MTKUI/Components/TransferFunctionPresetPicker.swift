import SwiftUI
import MTKCore

/// A lightweight SwiftUI picker for selecting a built-in transfer-function preset.
///
/// This view is intentionally UI-only: it does not know about any controller/coordinator.
/// Downstream apps bind it to their own state and apply the selected preset to a
/// ``VolumeViewportController`` (or any ``VolumeViewportControlling``) elsewhere.
///
/// `selection` binds to ``VolumeRenderingBuiltinPreset`` (a MTKCore enum describing the built-in
/// presets shipped by the host app).
public struct TransferFunctionPresetPicker: View {
    @Binding private var selection: VolumeRenderingBuiltinPreset
    private let label: LocalizedStringKey

    public init(
        label: LocalizedStringKey = "Preset",
        selection: Binding<VolumeRenderingBuiltinPreset>
    ) {
        self.label = label
        self._selection = selection
    }

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(VolumeRenderingBuiltinPreset.allCases, id: \.self) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
    }
}
