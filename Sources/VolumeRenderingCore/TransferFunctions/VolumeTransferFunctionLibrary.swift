//
//  VolumeTransferFunctionLibrary.swift
//  VolumeRenderingKit
//

import Foundation

public enum VolumeTransferFunctionLibrary {
    public static func transferFunction(for preset: VolumeRenderingBuiltinPreset) -> TransferFunction? {
        TransferFunctions.transferFunction(for: preset)
    }
}
