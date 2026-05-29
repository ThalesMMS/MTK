//
//  ClinicalViewportGridController+HangingProtocol.swift
//  MTKUI
//
//  Hanging protocol application for the clinical viewport grid.
//

import Foundation
import MTKCore

extension ClinicalViewportGridController {
    @discardableResult
    public func applyHangingProtocol(_ definition: HangingProtocolDefinition,
                                     context explicitContext: HangingProtocolContext? = nil) async -> HangingProtocolResolvedLayout? {
        let context = explicitContext ??
            currentDataset.map { HangingProtocolContext(current: $0) } ??
            .empty
        let resolved = HangingProtocolEngine().resolve(definition, context: context)

        hangingProtocolDefinition = definition
        hangingProtocolContext = context
        hangingProtocolResolvedLayout = resolved
        hangingProtocolSlotAssignments = resolved?.viewports ?? []

        guard let resolved else { return nil }
        await applyResolvedHangingProtocolLayout(resolved)
        return resolved
    }

    public func clearHangingProtocol() {
        hangingProtocolDefinition = nil
        hangingProtocolContext = nil
        hangingProtocolResolvedLayout = nil
        hangingProtocolSlotAssignments = []
        scheduleMPRRenderAll()
    }

    public func hangingProtocolViewportContent(for slot: Int) -> HangingProtocolViewportContent? {
        hangingProtocolSlotAssignments.first { $0.slot == slot }?.content
    }

    public func prepareDisplayedVolumeViewport() async {
        guard datasetApplied else { return }
        do {
            try await configureVolumeWindow(windowLevel.range)
            try await configureVolumeCamera()
            try await configureVolumeRenderQuality()
            try await configureVolumeClipping()
            scheduleRender(for: volumeViewportID)
        } catch {
            recordError(error, for: volumeViewportID)
        }
    }

    private func applyResolvedHangingProtocolLayout(_ layout: HangingProtocolResolvedLayout) async {
        let assignedAxes = Set(layout.viewports.compactMap(\.content.mprAxis))
        if let firstAxis = assignedAxes.sorted(by: { $0.debugName < $1.debugName }).first {
            activeMPRAxis = firstAxis
        }

        if layout.viewports.contains(where: { $0.content == .volume3D }) {
            await prepareDisplayedVolumeViewport()
        }

        guard datasetApplied else { return }
        for axis in assignedAxes {
            scheduleRender(for: viewportID(for: axis))
        }
    }
}
