import Foundation
import MTKCore
import OSLog
import ZIPFoundation

public enum FixtureVolumePresetLoader {
    private struct PresetSpec {
        let resourceName: String
        let dimensions: VolumeDimensions
        let spacing: VolumeSpacing
        let pixelFormat: VolumePixelFormat
        let intensityRange: ClosedRange<Int32>
    }

    private static let resourceLogger = Logger(subsystem: "com.mtk.volumerendering",
                                               category: "FixtureVolumePresets")

    public static func dataset(for preset: VolumeDatasetPreset) throws -> VolumeDataset {
        try dataset(for: preset, bundle: .module)
    }

    public static func dataset(for preset: VolumeDatasetPreset,
                               bundle: Bundle) throws -> VolumeDataset {
        guard let spec = spec(for: preset) else {
            resourceLogger.warning("Preset \(preset.rawValue) does not provide bundled fixture data")
            throw VolumeTextureFactory.PresetLoadingError.noDataAvailable(preset: preset.rawValue)
        }
        return try loadZippedResource(spec: spec, bundle: bundle)
    }

    private static func spec(for preset: VolumeDatasetPreset) -> PresetSpec? {
        switch preset {
        case .head:
            return PresetSpec(
                resourceName: "head",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 511),
                spacing: VolumeSpacing(x: 0.449, y: 0.449, z: 0.501),
                pixelFormat: .int16Signed,
                intensityRange: (-1024)...3071
            )
        case .chest:
            return PresetSpec(
                resourceName: "chest",
                dimensions: VolumeDimensions(width: 512, height: 512, depth: 179),
                spacing: VolumeSpacing(x: 0.586, y: 0.586, z: 2.0),
                pixelFormat: .int16Signed,
                intensityRange: (-1024)...3071
            )
        case .none, .dicom:
            return nil
        }
    }

    private static func loadZippedResource(spec: PresetSpec,
                                           bundle: Bundle) throws -> VolumeDataset {
        guard let url = bundle.url(forResource: spec.resourceName, withExtension: "raw.zip") else {
            resourceLogger.warning("Missing fixture resource: \(spec.resourceName).raw.zip")
            throw VolumeTextureFactory.PresetLoadingError.resourceNotBundled(preset: spec.resourceName)
        }

        return try loadDataset(fromArchiveAt: url, spec: spec)
    }

    private static func loadDataset(fromArchiveAt url: URL,
                                    spec: PresetSpec) throws -> VolumeDataset {
        let presetName = presetName(fromArchiveURL: url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            resourceLogger.error("Unable to read fixture archive at \(url.path): \(String(describing: error))")
            throw VolumeTextureFactory.PresetLoadingError.archiveUnreadable(preset: presetName)
        }

        var data = Data(capacity: spec.dimensions.voxelCount * spec.pixelFormat.bytesPerVoxel)
        do {
            for entry in archive {
                _ = try archive.extract(entry) { buffer in
                    data.append(buffer)
                }
            }
        } catch {
            resourceLogger.error("Failed to extract fixture archive \(url.lastPathComponent): \(String(describing: error))")
            throw VolumeTextureFactory.PresetLoadingError.extractionFailed(preset: presetName, underlying: error)
        }

        if data.isEmpty {
            resourceLogger.warning("Fixture archive \(url.lastPathComponent) extracted but returned empty data")
            throw VolumeTextureFactory.PresetLoadingError.emptyPayload(preset: presetName)
        }

        return VolumeDataset(
            data: data,
            dimensions: spec.dimensions,
            spacing: spec.spacing,
            pixelFormat: spec.pixelFormat,
            intensityRange: spec.intensityRange
        )
    }

    private static func presetName(fromArchiveURL url: URL) -> String {
        let rawName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        return rawName.isEmpty ? url.lastPathComponent : rawName
    }
}
