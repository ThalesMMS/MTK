//
//  VolumeRenderingPreset.swift
//  VolumeRenderingKit
//

import Foundation

public enum VolumeRenderingBuiltinPreset: String, CaseIterable, Sendable, Identifiable {
    case ctEntire
    case ctArteries
    case ctLung

    public var id: String { rawValue }
}
