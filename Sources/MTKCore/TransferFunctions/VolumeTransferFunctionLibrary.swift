//
//  VolumeTransferFunctionLibrary.swift
//  MTK
//
//  Public API for accessing built-in transfer function presets.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// Public API for accessing built-in transfer function presets.
///
/// `VolumeTransferFunctionLibrary` provides a convenient interface for loading
/// predefined transfer functions optimized for various medical imaging modalities
/// and anatomical regions.
///
/// ## Available Presets
/// - **CT Presets**: ctEntire, ctArteries, ctLung, ctBone, ctCardiac, ctLiverVasculature, ctChestContrast, ctSoftTissue, ctPulmonaryArteries, ctFat
/// - **MR Presets**: mrT2Brain, mrAngio
///
/// ## Usage
/// ```swift
/// if let tf = VolumeTransferFunctionLibrary.transferFunction(for: .ctBone) {
///     let texture = tf.makeTexture(device: metalDevice)
///     // Apply texture to volume renderer
/// }
/// ```
///
/// - SeeAlso: `VolumeRenderingBuiltinPreset`, `TransferFunction`
public enum VolumeTransferFunctionLibrary {
    /// Retrieve a built-in transfer function for the specified preset.
    ///
    /// Returns a `TransferFunction` configured with color and alpha points optimized
    /// for the specified imaging modality and anatomical region. Returns `nil` if
    /// the preset definition cannot be loaded.
    ///
    /// - Parameter preset: The built-in preset to load
    /// - Returns: A configured `TransferFunction`, or `nil` if loading fails
    ///
    /// ## Example
    /// ```swift
    /// // Load CT bone preset
    /// if let boneTF = VolumeTransferFunctionLibrary.transferFunction(for: .ctBone) {
    ///     print("Loaded \(boneTF.name)")
    ///     print("Value range: \(boneTF.minimumValue)...\(boneTF.maximumValue)")
    /// }
    /// ```
    public static func transferFunction(for preset: VolumeRenderingBuiltinPreset) -> TransferFunction? {
        TransferFunctions.transferFunction(for: preset)
    }
}
