//
//  RenderQualityLevel.swift
//  MTKCore
//
//  Encapsulates render quality levels for volumetric rendering with associated sampling parameters.
//  Migrated from Isis VolumetricSessionState to support MTK domain model.
//  Thales Matheus Mendonça Santos - November 2025
//

import Foundation

/// Defines rendering quality levels for volumetric rendering with corresponding sampling strategies.
/// Each level provides a different balance between visual fidelity and computational performance.
public enum RenderQualityLevel: Int, CaseIterable, Codable, Hashable, Sendable {
    /// Fast preview mode with coarser sampling for interactive feedback
    case preview
    /// Balanced mode for routine interactive work
    case balanced
    /// High quality mode with sharper integration
    case high
    /// Ultra-high fidelity mode for final captures
    case ultra

    /// Sampling step value for ray marching through the volume
    /// Higher values result in faster rendering but coarser sampling
    public var samplingStep: Float {
        switch self {
        case .preview:
            return 192
        case .balanced:
            return 320
        case .high:
            return 512
        case .ultra:
            return 768
        }
    }

    /// User-facing display name for UI presentation
    public var displayName: String {
        switch self {
        case .preview:
            return "Preview"
        case .balanced:
            return "Balanced"
        case .high:
            return "High"
        case .ultra:
            return "Ultra"
        }
    }

    /// Short label for compact UI elements
    public var shortLabel: String {
        switch self {
        case .preview:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .high:
            return "High"
        case .ultra:
            return "Ultra"
        }
    }

    /// Detailed description of the quality level for user guidance
    public var description: String {
        switch self {
        case .preview:
            return "Faster updates with coarser sampling."
        case .balanced:
            return "Balanced detail for interactive work."
        case .high:
            return "Sharper integration with moderate cost."
        case .ultra:
            return "Highest fidelity for still captures."
        }
    }

    /// Ordinal value for comparison and sorting
    public var ordinal: Int {
        rawValue
    }
}
