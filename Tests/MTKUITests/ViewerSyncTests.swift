import Foundation
import MTKCore
@testable import MTKUI
import XCTest

final class ViewerSyncTests: XCTestCase {
    func testViewerSyncStateTracksIndependentChannels() {
        let state = ViewerSyncState()
            .setting(.transforms, enabled: true)
            .setting(.windowLevel, enabled: true)
            .setting(.sameStudy, enabled: false)

        XCTAssertTrue(state.syncTransforms)
        XCTAssertTrue(state.syncWindowLevel)
        XCTAssertFalse(state.syncLocation)
        XCTAssertFalse(state.syncSameStudy)
        XCTAssertTrue(state.hasActiveSyncChannels)
    }

    func testPanelIdentityFiltersByStudyAndGeometry() {
        let source = ViewerPanelIdentity(panelID: "source",
                                         datasetIdentifier: "dataset-a",
                                         studyInstanceUID: "study-a",
                                         seriesInstanceUID: "series-a",
                                         frameOfReferenceUID: "frame-a")
        let sameStudy = ViewerPanelIdentity(panelID: "peer-a",
                                            datasetIdentifier: "dataset-b",
                                            studyInstanceUID: "study-a",
                                            seriesInstanceUID: "series-b",
                                            frameOfReferenceUID: "frame-a")
        let otherStudy = ViewerPanelIdentity(panelID: "peer-b",
                                             datasetIdentifier: "dataset-c",
                                             studyInstanceUID: "study-b",
                                             seriesInstanceUID: "series-c",
                                             frameOfReferenceUID: "frame-b")
        let unknown = ViewerPanelIdentity(panelID: "unknown")

        XCTAssertTrue(source.canSyncWith(sameStudy, sameStudyOnly: true))
        XCTAssertFalse(source.canSyncWith(otherStudy, sameStudyOnly: true))
        XCTAssertTrue(source.canSyncWith(otherStudy, sameStudyOnly: false))
        XCTAssertFalse(unknown.canSyncWith(ViewerPanelIdentity(panelID: "unknown-peer"), sameStudyOnly: true))
        XCTAssertTrue(source.hasCompatibleLocationGeometry(with: sameStudy))
        XCTAssertFalse(source.hasCompatibleLocationGeometry(with: otherStudy))
        XCTAssertFalse(unknown.hasCompatibleLocationGeometry(with: ViewerPanelIdentity(panelID: "unknown-peer")))
    }

    func testSyncCoordinatorPropagatesOnlyEnabledChannelsToEligiblePanels() throws {
        let sourceIdentity = ViewerPanelIdentity(panelID: "source",
                                                 datasetIdentifier: "dataset-a",
                                                 studyInstanceUID: "study-a",
                                                 frameOfReferenceUID: "frame-a")
        let peerIdentity = ViewerPanelIdentity(panelID: "peer",
                                               datasetIdentifier: "dataset-b",
                                               studyInstanceUID: "study-a",
                                               frameOfReferenceUID: "frame-a")
        let filteredIdentity = ViewerPanelIdentity(panelID: "filtered",
                                                   datasetIdentifier: "dataset-c",
                                                   studyInstanceUID: "study-b",
                                                   frameOfReferenceUID: "frame-a")
        let source = Viewer2DPanelSnapshot(
            identity: sourceIdentity,
            transform: Viewer2DTransform(zoom: 2,
                                         pan: SIMD2<Double>(0.1, -0.2),
                                         rotationRadians: .pi / 4,
                                         isFlippedHorizontally: true),
            windowLevelState: TwoDWindowLevelState(window: 100, level: 30),
            sliceIndex: 4,
            normalizedLocation: 0.4
        )
        let peer = Viewer2DPanelSnapshot(identity: peerIdentity,
                                         windowLevelState: TwoDWindowLevelState(window: 400, level: 40),
                                         sliceIndex: 1,
                                         normalizedLocation: 0.1)
        let filtered = Viewer2DPanelSnapshot(identity: filteredIdentity,
                                             windowLevelState: TwoDWindowLevelState(window: 400, level: 40),
                                             sliceIndex: 1,
                                             normalizedLocation: 0.1)
        var coordinator = Clinical2DSyncCoordinator(
            syncState: ViewerSyncState(syncTransforms: true,
                                       syncWindowLevel: true,
                                       syncLocation: true,
                                       syncSameStudy: true),
            panels: [source, peer, filtered]
        )

        let updated = coordinator.applySourcePanelUpdate(source)
        let syncedPeer = try XCTUnwrap(updated.first { $0.id == "peer" })
        let filteredPeer = try XCTUnwrap(updated.first { $0.id == "filtered" })

        XCTAssertEqual(syncedPeer.transform, source.transform)
        XCTAssertEqual(syncedPeer.windowLevelState, source.windowLevelState)
        XCTAssertEqual(syncedPeer.sliceIndex, source.sliceIndex)
        XCTAssertEqual(syncedPeer.normalizedLocation, source.normalizedLocation)
        XCTAssertNotEqual(filteredPeer.transform, source.transform)
        XCTAssertNotEqual(filteredPeer.windowLevelState, source.windowLevelState)
        XCTAssertNotEqual(filteredPeer.sliceIndex, source.sliceIndex)
    }

    func testSyncCoordinatorLeavesSinglePanelStateLocal() {
        let source = Viewer2DPanelSnapshot(
            identity: ViewerPanelIdentity(panelID: "single",
                                          datasetIdentifier: "dataset-a",
                                          studyInstanceUID: "study-a"),
            transform: Viewer2DTransform(zoom: 1.8),
            windowLevelState: TwoDWindowLevelState(window: 120, level: 40),
            sliceIndex: 3,
            normalizedLocation: 0.3
        )
        var coordinator = Clinical2DSyncCoordinator(
            syncState: ViewerSyncState(syncTransforms: true,
                                       syncWindowLevel: true,
                                       syncLocation: true,
                                       syncSameStudy: true),
            panels: [source]
        )

        let updated = coordinator.applySourcePanelUpdate(source)

        XCTAssertEqual(updated, [source])
        XCTAssertEqual(coordinator.panels, [source])
    }

    func testPanelIdentityCanBeBuiltFromDatasetMetadata() {
        let dataset = makeDataset(
            metadata: ClinicalImageMetadata(studyInstanceUID: "study-a",
                                            seriesInstanceUID: "series-a",
                                            frameOfReferenceUID: "frame-a")
        )

        let identity = ViewerPanelIdentity(panelID: "panel", dataset: dataset)

        XCTAssertEqual(identity.studyInstanceUID, "study-a")
        XCTAssertEqual(identity.seriesInstanceUID, "series-a")
        XCTAssertEqual(identity.frameOfReferenceUID, "frame-a")
        XCTAssertNotNil(identity.datasetIdentifier)
    }

    private func makeDataset(metadata: ClinicalImageMetadata) -> VolumeDataset {
        let values = [Int16](repeating: 1, count: 8)
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            clinicalMetadata: metadata
        )
    }
}
