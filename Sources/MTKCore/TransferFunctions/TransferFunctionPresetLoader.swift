//
//  TransferFunctionPresetLoader.swift
//  MTK
//
//  Loads transfer function presets from bundled .tf files.
//  Maps VolumeRenderingBuiltinPreset enum cases to resource files
//  and caches loaded instances to avoid redundant file I/O.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import OSLog

public enum TransferFunctionPresetLoader {
    /// Cache of loaded transfer functions keyed by preset enum
    private static var cache: [VolumeRenderingBuiltinPreset: TransferFunction] = [:]
    private static let lock = NSLock()

    /// Loads a transfer function for the given builtin preset from bundle resources
    /// - Parameters:
    ///   - preset: The builtin preset to load
    ///   - logger: Logger instance for error reporting
    /// - Returns: The loaded transfer function, or nil if loading fails
    public static func load(
        _ preset: VolumeRenderingBuiltinPreset,
        logger: Logger = Logger(subsystem: "com.mtk.volumerendering",
                                category: "TransferFunctionPresetLoader")
    ) -> TransferFunction? {
        // Check cache first
        lock.lock()
        if let cached = cache[preset] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Map preset enum to filename
        let filename = filenameForPreset(preset)

        // Locate resource in bundle
        guard let url = VolumeRenderingResources.bundle.url(
            forResource: filename,
            withExtension: "tf"
        ) else {
            logger.error("Failed to locate transfer function resource: \(filename).tf")
            return nil
        }

        // Load from file
        guard let transferFunction = TransferFunction.load(from: url, logger: logger) else {
            return nil
        }

        // Cache and return
        lock.lock()
        cache[preset] = transferFunction
        lock.unlock()

        return transferFunction
    }

    /// Maps preset enum cases to their corresponding .tf filenames
    private static func filenameForPreset(_ preset: VolumeRenderingBuiltinPreset) -> String {
        switch preset {
        case .ctEntire:
            return "ct_entire"
        case .ctArteries:
            return "ct_arteries"
        case .ctLung:
            return "ct_lung"
        case .ctBone:
            return "ct_bone"
        case .ctCardiac:
            return "ct_cardiac"
        case .ctLiverVasculature:
            return "ct_liver_vasculature"
        case .mrT2Brain:
            return "mr_t2_brain"
        case .ctChestContrast:
            return "ct_chest_contrast"
        case .ctSoftTissue:
            return "ct_soft_tissue"
        case .ctPulmonaryArteries:
            return "ct_pulmonary_arteries"
        case .ctFat:
            return "ct_fat"
        case .mrAngio:
            return "mr_angio"
        }
    }

    /// Clears the preset cache (useful for testing)
    public static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
