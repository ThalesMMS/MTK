//
//  ClinicalViewportGridController+RTDose.swift
//  MTKUI
//
//  RT dose colorwash and picking integration.
//

import CoreGraphics
import Foundation
import MTKCore

extension ClinicalViewportGridController {
    public func setRTDoseOverlays(_ overlays: [RTDoseVolumeOverlay]) async {
        let previousDoseLayerIDs = rtDoseVolumeLayerIDs
        let newDoseLayerIDs = Set(overlays.map(\.volumeLayer.id))
        rtDoseOverlays = overlays
        rtDoseVolumeLayerIDs = newDoseLayerIDs

        let preservedLayers = volumeLayers.filter { layer in
            !previousDoseLayerIDs.contains(layer.id) && !newDoseLayerIDs.contains(layer.id)
        }
        volumeLayers = preservedLayers + overlays.map(\.volumeLayer)
        await commitVolumeLayers()
    }

    public func setRTDoseOverlayOpacity(id: String, opacity: Float) async {
        guard let index = rtDoseOverlays.firstIndex(where: { $0.id == id || $0.volumeLayer.id == id }) else {
            return
        }
        var overlays = rtDoseOverlays
        overlays[index] = overlays[index].settingOpacity(opacity)
        await setRTDoseOverlays(overlays)
    }

    public func setRTDoseColorLookupTable(id: String,
                                          colorLookupTable: RTDoseColorLookupTable) async {
        guard let index = rtDoseOverlays.firstIndex(where: { $0.id == id || $0.volumeLayer.id == id }) else {
            return
        }
        var overlays = rtDoseOverlays
        overlays[index] = overlays[index].settingColorLookupTable(colorLookupTable)
        await setRTDoseOverlays(overlays)
    }

    public func pickRTDose(in viewport: ViewportID,
                           screenPoint: CGPoint) throws -> [RTDoseSample] {
        let pickResult = try pick(in: viewport, screenPoint: screenPoint)
        return rtDoseSamples(atBaseWorldPoint: pickResult.worldPoint)
    }

    public func pickRTDose(in axis: MTKCore.Axis,
                           screenPoint: CGPoint) throws -> [RTDoseSample] {
        let pickResult = try pick(in: axis, screenPoint: screenPoint)
        return rtDoseSamples(atBaseWorldPoint: pickResult.worldPoint)
    }

    public func doseStatistics(overlayID: String,
                               roiLayerID: String,
                               label: UInt16? = nil) throws -> RTDoseStatistics {
        guard let overlay = rtDoseOverlays.first(where: { $0.id == overlayID || $0.volumeLayer.id == overlayID }) else {
            throw RTDoseVolumePickingError.missingDoseDataset(overlayID)
        }
        guard let roiLayer = volumeLayers.first(where: { $0.id == roiLayerID }) else {
            throw RTDoseVolumePickingError.missingLabelmap(roiLayerID)
        }
        return try overlay.doseStatistics(in: roiLayer, label: label)
    }

    public func quantitativeScalarStatistics(layerID: String,
                                             roiLayerID: String,
                                             label: UInt16? = nil) throws -> QuantitativeScalarStatistics {
        guard let layer = volumeLayers.first(where: { $0.id == layerID }) else {
            throw QuantitativeScalarVolumePickingError.missingScalarDataset(layerID)
        }
        guard let roiLayer = volumeLayers.first(where: { $0.id == roiLayerID }) else {
            throw QuantitativeScalarVolumePickingError.missingLabelmap(roiLayerID)
        }
        return try QuantitativeScalarVolumePicking.statistics(in: layer,
                                                              roiLayer: roiLayer,
                                                              label: label)
    }

    private func rtDoseSamples(atBaseWorldPoint worldPoint: SIMD3<Float>) -> [RTDoseSample] {
        rtDoseOverlays.compactMap { overlay in
            guard overlay.volumeLayer.isVisible,
                  overlay.volumeLayer.clampedOpacity > 0 else {
                return nil
            }
            return try? overlay.sampleDose(atBaseWorldPoint: worldPoint)
        }
    }
}
