//
//  VolumeDatasetPreset.swift
//  MTK
//

import Foundation

public enum VolumeDatasetPreset: String, CaseIterable, Sendable, Identifiable {
    case none
    case chest
    case head
    case dicom

    public var id: String { rawValue }
}
