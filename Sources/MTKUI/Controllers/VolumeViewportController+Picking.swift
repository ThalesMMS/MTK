//
//  VolumeViewportController+Picking.swift
//  MTKUI
//
//  Public picking integration for the single 3D volume viewport.
//

import CoreGraphics
import Foundation
import MTKCore

extension VolumeViewportController {
    public func pickVolume(screenPoint: CGPoint,
                           dataset pickDataset: VolumeDataset? = nil) throws -> VolumePickResult {
        guard let dataset = pickDataset ?? self.dataset else {
            throw VolumePickError.invalidViewport
        }

        let display = currentDisplay ?? .volume(method: currentVolumeMethod)
        let method: VolumetricRenderMethod
        switch display {
        case .volume(let activeMethod):
            method = activeMethod
        case .mpr:
            method = currentVolumeMethod
        }

        let viewport = clampedViewportSize()
        let samplingStep = adaptiveSamplingEnabled
            ? max(1, qualityScheduler.currentParameters.volumeSamplingStep)
            : max(baseSamplingStep, 1)
        let configuration = Volume3DPickConfiguration(
            camera: VolumeRenderRequest.Camera(
                position: cameraTarget + cameraOffset,
                target: cameraTarget,
                up: cameraUpVector,
                fieldOfView: 60,
                projectionType: .perspective
            ),
            viewportSize: CGSize(width: viewport.width, height: viewport.height),
            transferFunction: makeVolumeTransferFunction(for: dataset),
            window: huWindow.map { $0.minHU...$0.maxHU } ?? dataset.recommendedWindow ?? dataset.intensityRange,
            samplingDistance: 1 / samplingStep,
            compositing: method.compositing,
            clipping: volumeClipping
        )
        return try VolumePicking.pickVolume3D(screenPoint: screenPoint,
                                             dataset: dataset,
                                             configuration: configuration,
                                             layers: volumeLayers)
    }
}
