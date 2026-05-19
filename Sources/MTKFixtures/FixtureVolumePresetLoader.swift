import Foundation
import MTKCore
import OSLog

public enum FixtureVolumePresetLoader {
    private static let resourceLogger = Logger(subsystem: "com.mtk.volumerendering",
                                               category: "FixtureVolumePresets")

    public static func dataset(for preset: VolumeDatasetPreset) throws -> VolumeDataset {
        try dataset(for: preset, bundle: .module)
    }

    public static func dataset(for preset: VolumeDatasetPreset,
                               bundle: Bundle) throws -> VolumeDataset {
        _ = bundle
        resourceLogger.warning("Preset \(preset.rawValue) does not provide bundled fixture data")
        throw VolumeTextureFactory.PresetLoadingError.noDataAvailable(preset: preset.rawValue)
    }
}
