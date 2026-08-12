//
//  VolumeDatasetPreset.swift
//  MTKCore
//
//  Identifies the supported volume dataset preset selections for fixture loading.
//
//  Thales Matheus Mendonça Santos — January 2026
//

import Foundation

public enum VolumeDatasetPreset: String, CaseIterable, Sendable, Identifiable {
    case none
    case dicom

    public var id: String { rawValue }
}
