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

    /// Unique identifier (raw string value).
    public var id: String { rawValue }
}
