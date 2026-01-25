//
//  VolumeRenderingPreset.swift
//  MTK
//

import Foundation

public enum VolumeRenderingBuiltinPreset: String, CaseIterable, Sendable, Identifiable {
    // Original MTK presets
    case ctEntire
    case ctArteries
    case ctLung

    // New comprehensive medical presets (Phase 7)
    case ctBone
    case ctCardiac
    case ctLiverVasculature
    case mrT2Brain
    case ctChestContrast
    case ctSoftTissue
    case ctPulmonaryArteries
    case ctFat
    case mrAngio

    public var id: String { rawValue }
}
