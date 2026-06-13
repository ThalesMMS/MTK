import Foundation
import Metal
import MTKCore
@testable import MTKUI
import XCTest

@MainActor
final class Clinical2DPanelSyncHubTests: XCTestCase {
    func testLocationSyncPropagatesOnlyToSameStudyPanels() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a"),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a"),
            PanelFixture(study: "study-b", series: "series-c", frame: "frame-b")
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState(syncLocation: true, syncSameStudy: true))

        coordinators[0].setTwoDSliceIndex(4)

        XCTAssertEqual(coordinators[0].twoDSliceIndex, 4)
        XCTAssertEqual(coordinators[1].twoDSliceIndex, 4)
        XCTAssertEqual(coordinators[2].twoDSliceIndex, 0)
    }

    func testNothingPropagatesWithoutActiveChannels() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a"),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a")
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState())

        coordinators[0].setTwoDSliceIndex(3)
        coordinators[0].setTwoDTransform(Viewer2DTransform(zoom: 2))

        XCTAssertEqual(coordinators[1].twoDSliceIndex, 0)
        XCTAssertEqual(coordinators[1].twoDTransform, .identity)
    }

    func testWindowLevelSyncPreservesTargetTool() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a"),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a")
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState(syncWindowLevel: true, syncSameStudy: true))
        coordinators[1].setTwoDTool(.scroll)

        coordinators[0].setTwoDWindowLevel(window: 1500, level: -600)

        XCTAssertEqual(coordinators[1].twoDWindowLevelState.window, 1500)
        XCTAssertEqual(coordinators[1].twoDWindowLevelState.level, -600)
        XCTAssertEqual(coordinators[1].twoDTool, .scroll)
    }

    func testTransformSyncPropagatesToSameStudyPanel() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a"),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a")
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState(syncTransforms: true, syncSameStudy: true))

        let transform = Viewer2DTransform(zoom: 2.5,
                                          pan: SIMD2<Double>(0.2, -0.1),
                                          rotationRadians: .pi / 2)
        coordinators[0].setTwoDTransform(transform)

        XCTAssertEqual(coordinators[1].twoDTransform, transform)
    }

    func testLocationSyncRemapsAcrossDifferentSliceCounts() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a", depth: 5),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a", depth: 9)
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState(syncLocation: true, syncSameStudy: true))

        coordinators[0].setTwoDSliceIndex(2)

        XCTAssertEqual(coordinators[0].twoDSliceIndex, 2)
        XCTAssertEqual(coordinators[1].twoDSliceIndex, 4)
    }

    func testSyncIsBidirectionalAndSettlesWithoutEcho() async throws {
        let (hub, coordinators) = try await makeHub(panels: [
            PanelFixture(study: "study-a", series: "series-a", frame: "frame-a"),
            PanelFixture(study: "study-a", series: "series-b", frame: "frame-a")
        ])
        defer { coordinators.forEach { $0.shutdownActiveViewports() } }
        hub.setSyncState(ViewerSyncState(syncLocation: true, syncSameStudy: true))

        coordinators[0].setTwoDSliceIndex(5)
        XCTAssertEqual(coordinators[1].twoDSliceIndex, 5)

        coordinators[1].setTwoDSliceIndex(2)
        XCTAssertEqual(coordinators[0].twoDSliceIndex, 2)
        XCTAssertEqual(coordinators[1].twoDSliceIndex, 2)
    }

    // MARK: - Fixtures

    private struct PanelFixture {
        let study: String
        let series: String
        let frame: String
        var depth: Int = 8
    }

    private func makeHub(
        panels: [PanelFixture]
    ) async throws -> (Clinical2DPanelSyncHub, [ClinicalViewerCoordinator]) {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable in this environment.")
        }

        var coordinators: [ClinicalViewerCoordinator] = []
        for fixture in panels {
            let coordinator = ClinicalViewerCoordinator()
            coordinator.setMode(.stack2D)
            try await coordinator.applyDataset(makeDataset(fixture))
            coordinators.append(coordinator)
        }

        let hub = Clinical2DPanelSyncHub()
        hub.setPanels(coordinators.enumerated().map { index, coordinator in
            .init(panelID: "panel-\(index)", coordinator: coordinator)
        })
        return (hub, coordinators)
    }

    private func makeDataset(_ fixture: PanelFixture) -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: fixture.depth)
        let values = [Int16](repeating: 1, count: dimensions.voxelCount)
        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: 0...1,
            clinicalMetadata: ClinicalImageMetadata(studyInstanceUID: fixture.study,
                                                    seriesInstanceUID: fixture.series,
                                                    frameOfReferenceUID: fixture.frame)
        )
    }
}
