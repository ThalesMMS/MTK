import XCTest
@testable import MTKUI

final class HangingProtocolDefinitionTests: XCTestCase {
    func testJSONRoundTripPreservesDefinition() throws {
        let definition = makeComparisonDefinition()

        let data = try definition.serializedJSON()
        let parsed = try HangingProtocolDefinition.parse(json: data)

        XCTAssertEqual(parsed, definition)
    }

    func testEngineMatchesCurrentAndPriorByModalityAndAnatomy() throws {
        let definition = makeComparisonDefinition()
        let context = HangingProtocolContext(
            current: HangingProtocolStudyDescriptor(id: "current-ct",
                                                    role: .current,
                                                    modality: "CT",
                                                    anatomy: "CT Chest With Contrast"),
            priors: [
                HangingProtocolStudyDescriptor(id: "prior-ct",
                                               role: .prior,
                                               modality: "CT",
                                               anatomy: "Chest")
            ]
        )

        let resolved = try XCTUnwrap(HangingProtocolEngine().resolve(definition, context: context))

        XCTAssertEqual(resolved.definitionID, "ct-chest-follow-up")
        XCTAssertEqual(resolved.ruleID, "ct-chest-current-prior")
        XCTAssertEqual(resolved.screenLayout, .hSplit2x1)
        XCTAssertEqual(resolved.viewports.map(\.content), [
            .stack2D(.axial),
            .stack2D(.axial),
            .volume3D
        ])
        XCTAssertEqual(resolved.viewports.map(\.studyRole), [.current, .prior, .current])
        XCTAssertEqual(resolved.viewports[1].studyID, "prior-ct")
    }

    func testEngineRejectsRuleWhenPriorDisplaySetIsUnavailable() throws {
        let definition = makeComparisonDefinition()
        let context = HangingProtocolContext(
            current: HangingProtocolStudyDescriptor(id: "current-ct",
                                                    role: .current,
                                                    modality: "CT",
                                                    anatomy: "Chest")
        )

        XCTAssertNil(HangingProtocolEngine().resolve(definition, context: context))
    }

    private func makeComparisonDefinition() -> HangingProtocolDefinition {
        HangingProtocolDefinition(
            id: "ct-chest-follow-up",
            displayName: "CT Chest Follow-up",
            displaySets: [
                HangingProtocolDisplaySetDefinition(
                    id: "current",
                    role: .current,
                    filter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"])
                ),
                HangingProtocolDisplaySetDefinition(
                    id: "prior",
                    role: .prior,
                    filter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"])
                )
            ],
            rules: [
                HangingProtocolRule(
                    id: "ct-chest-current-prior",
                    priority: 10,
                    currentFilter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"]),
                    requiredPriorFilter: HangingProtocolStudyFilter(modalities: ["CT"], anatomies: ["Chest"]),
                    layout: HangingProtocolLayoutDefinition(
                        screenLayout: .hSplit2x1,
                        viewports: [
                            HangingProtocolViewportDefinition(slot: 1,
                                                              displaySetID: "current",
                                                              content: .stack2D(.axial)),
                            HangingProtocolViewportDefinition(slot: 2,
                                                              displaySetID: "prior",
                                                              content: .stack2D(.axial)),
                            HangingProtocolViewportDefinition(slot: 3,
                                                              displaySetID: "current",
                                                              content: .volume3D)
                        ]
                    )
                )
            ]
        )
    }
}
