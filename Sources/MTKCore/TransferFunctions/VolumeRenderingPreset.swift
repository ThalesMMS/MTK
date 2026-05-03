//
//  VolumeRenderingPreset.swift
//  MTK
//
//  Built-in transfer function presets for medical volume rendering.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// Built-in transfer function presets for medical volume rendering.
///
/// `VolumeRenderingBuiltinPreset` defines all available transfer function presets
/// optimized for various medical imaging modalities (CT, MR) and anatomical regions.
///
/// Each preset includes carefully tuned color and alpha curves to emphasize relevant
/// anatomical structures and suppress background noise.
///
/// ## Preset Categories
///
/// ### CT Presets
/// - General visualization: ``ctEntire``, ``ctSoftTissue``
/// - Vascular imaging: ``ctArteries``, ``ctCardiac``, ``ctLiverVasculature``, ``ctPulmonaryArteries``
/// - Skeletal imaging: ``ctBone``
/// - Pulmonary imaging: ``ctLung``, ``ctChestContrast``
/// - Specialized: ``ctFat``
///
/// ### MR Presets
/// - Neurological imaging: ``mrT2Brain``
/// - Vascular imaging: ``mrAngio``
///
/// ## Usage
/// ```swift
/// let preset: VolumeRenderingBuiltinPreset = .ctBone
/// if let tf = VolumeTransferFunctionLibrary.transferFunction(for: preset) {
///     // Apply transfer function to renderer
/// }
/// ```
///
/// - SeeAlso: `VolumeTransferFunctionLibrary`, `TransferFunction`
public enum VolumeRenderingBuiltinPreset: String, CaseIterable, Sendable, Identifiable {
    // MARK: - Original MTK Presets

    /// General CT visualization preset showing entire volume dynamic range.
    ///
    /// Suitable for initial volume inspection and general diagnostic review.
    case ctEntire

    /// CT angiography preset emphasizing arterial structures.
    ///
    /// Optimized for contrast-enhanced arterial imaging with suppressed soft tissue.
    case ctArteries

    /// CT lung parenchyma preset.
    ///
    /// Emphasizes pulmonary vessels and airways while preserving air-tissue contrast.
    case ctLung

    // MARK: - Comprehensive Medical Presets (Phase 7)

    /// CT bone imaging preset.
    ///
    /// Emphasizes high-density skeletal structures with suppressed soft tissue.
    case ctBone

    /// CT cardiac imaging preset.
    ///
    /// Optimized for cardiac chambers, coronary vessels, and myocardium visualization.
    case ctCardiac

    /// CT hepatic vasculature preset.
    ///
    /// Emphasizes portal and hepatic vessels in contrast-enhanced liver imaging.
    case ctLiverVasculature

    /// MR T2-weighted brain imaging preset.
    ///
    /// Optimized for T2-weighted brain MRI, emphasizing CSF and edema.
    case mrT2Brain

    /// CT chest contrast-enhanced preset.
    ///
    /// Balanced visualization of mediastinal structures, pulmonary vessels, and parenchyma.
    case ctChestContrast

    /// CT soft tissue preset.
    ///
    /// Emphasizes soft tissue contrast for organs, muscles, and subcutaneous structures.
    case ctSoftTissue

    /// CT pulmonary artery preset.
    ///
    /// Optimized for pulmonary embolism detection and pulmonary artery visualization.
    case ctPulmonaryArteries

    /// CT fat visualization preset.
    ///
    /// Emphasizes adipose tissue for body composition analysis.
    case ctFat

    /// MR angiography preset.
    ///
    /// Optimized for time-of-flight (TOF) and contrast-enhanced MR angiography.
    case mrAngio

    public enum Modality: String, Sendable {
        case ct
        case mr
    }

    public enum Category: String, Sendable {
        case general
        case vascular
        case skeletal
        case pulmonary
        case softTissue
        case fat
        case neurological
        case cardiac
        case hepatic
    }

    /// Unique identifier (raw string value).
    public var id: String { rawValue }

    /// The bundled transfer function preset filename (without extension).
    ///
    /// This delegates to `TransferFunctionPresetLoader.filenameForPreset(_:)`, which is the
    /// single source of truth for the preset → resource mapping.
    public var filename: String {
        TransferFunctionPresetLoader.filenameForPreset(self)
    }

    /// Imaging modality that this preset is intended for.
    public var modality: Modality {
        switch self {
        case .ctArteries, .ctEntire, .ctLung, .ctBone, .ctCardiac, .ctLiverVasculature, .ctChestContrast, .ctSoftTissue, .ctPulmonaryArteries, .ctFat:
            return .ct
        case .mrT2Brain, .mrAngio:
            return .mr
        }
    }

    /// High-level category for UI grouping/filtering.
    public var category: Category {
        switch self {
        case .ctEntire:
            return .general
        case .ctSoftTissue:
            return .softTissue
        case .ctArteries, .ctPulmonaryArteries, .mrAngio:
            return .vascular
        case .ctLiverVasculature:
            return .hepatic
        case .ctBone:
            return .skeletal
        case .ctLung, .ctChestContrast:
            return .pulmonary
        case .ctFat:
            return .fat
        case .mrT2Brain:
            return .neurological
        case .ctCardiac:
            return .cardiac
        }
    }

    /// A human-readable, localized display name for this built-in preset.
    ///
    /// Intended for use in UI pickers/menus.
    public var displayName: String {
        switch self {
        case .ctArteries:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctArteries.displayName",
                value: "CT Arteries",
                comment: "Display name for the CT arteries volume rendering preset"
            )
        case .ctEntire:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctEntire.displayName",
                value: "CT Entire",
                comment: "Display name for the CT entire volume rendering preset"
            )
        case .ctLung:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctLung.displayName",
                value: "CT Lung",
                comment: "Display name for the CT lung volume rendering preset"
            )
        case .ctBone:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctBone.displayName",
                value: "CT Bone",
                comment: "Display name for the CT bone volume rendering preset"
            )
        case .ctCardiac:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctCardiac.displayName",
                value: "CT Cardiac",
                comment: "Display name for the CT cardiac volume rendering preset"
            )
        case .ctLiverVasculature:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctLiverVasculature.displayName",
                value: "CT Liver Vasculature",
                comment: "Display name for the CT liver vasculature volume rendering preset"
            )
        case .mrT2Brain:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.mrT2Brain.displayName",
                value: "MR T2 Brain",
                comment: "Display name for the MR T2 brain volume rendering preset"
            )
        case .ctChestContrast:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctChestContrast.displayName",
                value: "CT Chest Contrast",
                comment: "Display name for the CT chest contrast volume rendering preset"
            )
        case .ctSoftTissue:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctSoftTissue.displayName",
                value: "CT Soft Tissue",
                comment: "Display name for the CT soft tissue volume rendering preset"
            )
        case .ctPulmonaryArteries:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctPulmonaryArteries.displayName",
                value: "CT Pulmonary Arteries",
                comment: "Display name for the CT pulmonary arteries volume rendering preset"
            )
        case .ctFat:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.ctFat.displayName",
                value: "CT Fat",
                comment: "Display name for the CT fat volume rendering preset"
            )
        case .mrAngio:
            return NSLocalizedString(
                "VolumeRenderingBuiltinPreset.mrAngio.displayName",
                value: "MR Angio",
                comment: "Display name for the MR angiography volume rendering preset"
            )
        }
    }
}
