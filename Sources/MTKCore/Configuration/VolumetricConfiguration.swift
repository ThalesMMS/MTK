//
//  VolumetricConfiguration.swift
//  MTKCore
//
//  Centralized configuration for volumetric rendering applications.
//  Originally from MTK-Demo AppConfig — Migrated to MTKCore for reusability.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// Centralized configuration for volumetric rendering
public struct VolumetricConfiguration {
    /// Debug mode flag (derived from build configuration)
    public static var IS_DEBUG_MODE: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Default GPU histogram bin count for volume rendering
    public static let HISTOGRAM_BIN_COUNT: Int = 512

    /// Enable extended density visualization (diagnostics only)
    public static var ENABLE_DENSITY_DEBUG: Bool = false

    /// Toggle compute backend usage for compatible devices. Default is false to
    /// avoid activating the experimental compute path unless explicitly opted in.
    public static var computeEnabled: Bool = false

    /// Configure for demo/development mode
    public static func configureForDemo() {
        computeEnabled = true
        ENABLE_DENSITY_DEBUG = false
    }

    /// Configure for production mode
    public static func configureForProduction() {
        computeEnabled = true
        ENABLE_DENSITY_DEBUG = false
    }
}
