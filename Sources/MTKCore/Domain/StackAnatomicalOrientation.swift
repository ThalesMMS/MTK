//
//  StackAnatomicalOrientation.swift
//  MTKCore
//
//  Classifies acquisition-relative stack axes into anatomical planes from their
//  world-space normals.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import Foundation
import simd

/// The anatomical plane a reslice axis displays.
public enum AnatomicalPlane: String, Sendable, Equatable, CaseIterable {
    case axial
    case coronal
    case sagittal
    case oblique

    public var clinicalDisplayName: String {
        switch self {
        case .axial: return "Axial"
        case .coronal: return "Coronal"
        case .sagittal: return "Sagittal"
        case .oblique: return "Oblique"
        }
    }
}

public enum StackAnatomicalOrientation {
    /// |cosine| a plane normal must reach against an LPS axis before the
    /// plane is named after it; anything less committed is oblique.
    public static let dominanceThreshold: Float = 0.8

    /// Classifies a plane by its normal in LPS space.
    public static func anatomicalPlane(forNormal normal: SIMD3<Float>) -> AnatomicalPlane {
        let length = simd_length(normal)
        guard length.isFinite, length > .ulpOfOne else { return .oblique }
        let unit = normal / length
        let absolute = SIMD3<Float>(abs(unit.x), abs(unit.y), abs(unit.z))
        // Normal along S/I ⇒ axial; along A/P ⇒ coronal; along L/R ⇒ sagittal.
        if absolute.z >= dominanceThreshold { return .axial }
        if absolute.y >= dominanceThreshold { return .coronal }
        if absolute.x >= dominanceThreshold { return .sagittal }
        return .oblique
    }

    /// The anatomical plane `axis` shows for `dataset`, or nil when the
    /// dataset's orientation is unverified — callers must then keep the
    /// stack-relative naming rather than guess.
    public static func plane(for axis: Axis, in dataset: VolumeDataset) -> AnatomicalPlane? {
        plane(for: axis, in: dataset.imageData)
    }

    public static func plane(for axis: Axis, in imageData: ImageData3D) -> AnatomicalPlane? {
        guard imageData.isOrientationVerified else { return nil }
        return anatomicalPlane(forNormal: planeNormal(for: axis, in: imageData))
    }

    /// The world-space normal of the plane `axis` displays: `.axial` sweeps
    /// along k, `.coronal` along j, `.sagittal` along i.
    public static func planeNormal(for axis: Axis, in imageData: ImageData3D) -> SIMD3<Float> {
        switch axis {
        case .axial: return imageData.sliceDirection
        case .coronal: return imageData.columnDirection
        case .sagittal: return imageData.rowDirection
        }
    }

    /// The stack axis that displays `plane` for `dataset`, when one does.
    public static func axis(showing plane: AnatomicalPlane, in dataset: VolumeDataset) -> Axis? {
        guard dataset.imageData.isOrientationVerified else { return nil }
        return Axis.allCases.first { self.plane(for: $0, in: dataset) == plane }
    }
}
