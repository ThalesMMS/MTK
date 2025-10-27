//
//  VolumeTransferFunctionLibrary.swift
//  Isis DICOM Viewer
//
//  Fornece uma fachada retrocompatível para a biblioteca unificada de transfer functions.
//  Encaminha chamadas herdadas aos presets e caches definidos em TransferFunctions.swift sem quebrar o código existente.
//  Thales Matheus Mendonça Santos - September 2025
//

import Foundation

public enum VolumeTransferFunctionLibrary {
    public static func transferFunction(for preset: VolumeCubeMaterial.Preset) -> TransferFunction? {
        TransferFunctions.transferFunction(for: preset)
    }
}
