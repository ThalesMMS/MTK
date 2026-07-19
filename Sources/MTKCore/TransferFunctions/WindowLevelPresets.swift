//
//  WindowLevelPresets.swift
//  MTKCore
//
//  Standard window/level presets for medical imaging modalities.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// A window/level preset for medical imaging
public struct WindowLevelPreset: Identifiable, Equatable {
    /// Medical imaging modality
    public enum Modality: String, Sendable {
        case ct
        case pt

        public var displayName: String {
            rawValue.uppercased()
        }
    }

    /// Source of the preset.
    public enum Source: String, CaseIterable, Sendable {
        case isis
        case ohif
        case weasis

        public var displayName: String {
            switch self {
            case .isis: return "Isis"
            case .ohif: return "OHIF"
            case .weasis: return "Weasis"
            }
        }
    }

    public let id: String
    public let name: String
    public let modality: Modality
    public let window: Double
    public let level: Double
    public let source: Source

    /// Initialize a window/level preset
    public init(id: String, name: String, modality: Modality, window: Double, level: Double, source: Source) {
        self.id = id
        self.name = name
        self.modality = modality
        self.window = window
        self.level = level
        self.source = source
    }

    /// Minimum HU value for this preset
    public var minValue: Float {
        WindowLevelMath.bounds(forWidth: Float(window), level: Float(level)).min
    }

    /// Maximum HU value for this preset
    public var maxValue: Float {
        WindowLevelMath.bounds(forWidth: Float(window), level: Float(level)).max
    }

    /// Integer HU range suitable for Metal presentation window uniforms.
    public var windowRange: ClosedRange<Int32> {
        Int32(minValue.rounded(.down))...Int32(maxValue.rounded(.up))
    }

    /// Full display name including source
    public var fullDisplayName: String {
        "\(name) (\(source.displayName))"
    }

    /// Summary string showing window and level values
    public var windowLevelSummary: String {
        "W \(format(window)) / L \(format(level))"
    }

    /**
     Check if this preset matches the given min/max values within a specified tolerance.

     - Parameters:
       - min: The minimum value to compare (in Hounsfield Units, HU).
       - max: The maximum value to compare (in Hounsfield Units, HU).
       - tolerance: The allowed difference (in Hounsfield Units, HU) for both min and max values. Default is 1.0 HU.
     - Returns: `true` if both min and max values are within the specified tolerance of this preset's minValue and maxValue.
    */
    public func matches(min: Float, max: Float, tolerance: Float = 1.0) -> Bool {
        abs(minValue - min) <= tolerance && abs(maxValue - max) <= tolerance
    }

    private func format(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded - value) < 0.05 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", value)
    }
}

/// Library of standard window/level presets
public enum WindowLevelPresetLibrary {
    /// Canonical CT soft tissue window (W400/L40).
    public static let softTissue = WindowLevelPreset(
        id: "isis.ct-soft-tissue",
        name: "Soft Tissue",
        modality: .ct,
        window: 400,
        level: 40,
        source: .isis
    )

    /// Canonical CT abdomen window (W350/L40).
    public static let abdomen = WindowLevelPreset(
        id: "isis.ct-abdomen",
        name: "Abdomen",
        modality: .ct,
        window: 350,
        level: 40,
        source: .isis
    )

    /// Canonical CT lung window (W1400/L-500).
    public static let lung = WindowLevelPreset(
        id: "isis.ct-lung",
        name: "Lung",
        modality: .ct,
        window: 1400,
        level: -500,
        source: .isis
    )

    /// Canonical CT bone window (W1500/L300).
    public static let bone = WindowLevelPreset(
        id: "isis.ct-bone",
        name: "Bone",
        modality: .ct,
        window: 1500,
        level: 300,
        source: .isis
    )

    /// Canonical CT brain window (W100/L50).
    public static let brain = WindowLevelPreset(
        id: "isis.ct-brain",
        name: "Brain",
        modality: .ct,
        window: 100,
        level: 50,
        source: .isis
    )

    /// Canonical CT endoscopy window (W700/L-300).
    public static let endoscopy = WindowLevelPreset(
        id: "isis.ct-endoscopy",
        name: "Endoscopy",
        modality: .ct,
        window: 700,
        level: -300,
        source: .isis
    )

    /// Canonical CT presets plus uniquely named presets from external viewers.
    public static let ct: [WindowLevelPreset] = [
        softTissue,
        abdomen,
        lung,
        bone,
        brain,
        endoscopy,
        WindowLevelPreset(id: "ohif.ct-liver", name: "Liver", modality: .ct, window: 150, level: 90, source: .ohif),
        WindowLevelPreset(id: "weasis.ct-mediastinum", name: "Mediastinum", modality: .ct, window: 400, level: 80, source: .weasis),
        WindowLevelPreset(id: "weasis.ct-mip", name: "MIP", modality: .ct, window: 380, level: 120, source: .weasis)
    ]

    /// PET presets from OHIF
    public static let pt: [WindowLevelPreset] = [
        WindowLevelPreset(id: "ohif.pt-default", name: "Default", modality: .pt, window: 5, level: 2.5, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-3", name: "SUV 3", modality: .pt, window: 0, level: 3, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-5", name: "SUV 5", modality: .pt, window: 0, level: 5, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-7", name: "SUV 7", modality: .pt, window: 0, level: 7, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-8", name: "SUV 8", modality: .pt, window: 0, level: 8, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-10", name: "SUV 10", modality: .pt, window: 0, level: 10, source: .ohif),
        WindowLevelPreset(id: "ohif.pt-suv-15", name: "SUV 15", modality: .pt, window: 0, level: 15, source: .ohif)
    ]

    /// Get all presets for a specific modality
    public static func presets(for modality: WindowLevelPreset.Modality) -> [WindowLevelPreset] {
        switch modality {
        case .ct: return ct
        case .pt: return pt
        }
    }

    /// Find a preset by ID
    public static func preset(withId id: String) -> WindowLevelPreset? {
        (ct + pt).first { $0.id == id }
    }
}

/// Utilities for window/level calculations
public enum WindowLevelMath {
    /// Calculate min/max bounds from window width and level
    /// - Parameters:
    ///   - width: Window width
    ///   - level: Window level (center)
    /// - Returns: Tuple of (min, max) values
    public static func bounds(forWidth width: Float, level: Float) -> (min: Float, max: Float) {
        let clampedWidth = max(width, 1)
        let halfSpan = (clampedWidth - 1) * 0.5
        let minValue = level - 0.5 - halfSpan
        let maxValue = level - 0.5 + halfSpan
        return (minValue, maxValue)
    }

    /// Calculate window width and level from min/max bounds
    /// - Parameters:
    ///   - min: Minimum value
    ///   - max: Maximum value
    /// - Returns: Tuple of (width, level)
    public static func widthLevel(forMin min: Float, max maxValue: Float) -> (width: Float, level: Float) {
        let span = maxValue - min
        let width = Swift.max(span + 1, 1)
        let level = min + width * 0.5
        return (width, level)
    }
}
