//
//  ClinicalViewportGridController+Picking.swift
//  MTKUI
//
//  Public picking integration for the clinical 2x2 viewport grid.
//

import CoreGraphics
import Foundation
import MTKCore
import simd

extension ClinicalViewportGridController {
    public func pick(in viewport: ViewportID,
                     screenPoint: CGPoint) throws -> VolumePickResult {
        guard datasetApplied, currentDataset != nil else {
            throw VolumePickError.invalidViewport
        }

        if let axis = viewportAxesByID[viewport] {
            return try pick(in: axis, screenPoint: screenPoint)
        }
        if viewport == volumeViewportID {
            return try pickVolume(screenPoint: screenPoint)
        }
        throw VolumePickError.invalidViewport
    }

    public func pick(in axis: MTKCore.Axis,
                     screenPoint: CGPoint) throws -> VolumePickResult {
        guard let context = mprGeometryDisplayContext(for: axis) else {
            throw VolumePickError.invalidViewport
        }
        return try context.pick(screenPoint: screenPoint,
                                layers: volumeLayers)
    }

    public func pickVolume(screenPoint: CGPoint) throws -> VolumePickResult {
        guard let dataset = currentDataset else {
            throw VolumePickError.invalidViewport
        }
        let parameters = qualityScheduler.currentParameters
        let samplingStep = max(parameters.volumeSamplingStep, 1)
        let configuration = Volume3DPickConfiguration(
            camera: Camera(
                position: volumeCameraTarget + volumeCameraOffset,
                target: volumeCameraTarget,
                up: volumeCameraUp,
                fieldOfView: 45,
                projectionType: .perspective
            ),
            viewportSize: volumeViewportSize(),
            transferFunction: currentVolumeTransferFunction,
            window: windowLevel.range,
            samplingDistance: 1 / samplingStep,
            compositing: volumeViewportMode.compositing,
            clipping: volumeClipping
        )
        return try VolumePicking.pickVolume3D(screenPoint: screenPoint,
                                             dataset: dataset,
                                             configuration: configuration,
                                             layers: volumeLayers)
    }

    func volumeViewportSize() -> CGSize {
        let size = volumeSurface.metalView.bounds.size
        return CGSize(width: max(size.width, 1),
                      height: max(size.height, 1))
    }
}
