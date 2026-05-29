@testable import MTKUI
import XCTest

final class KeyImageNavigationStateTests: XCTestCase {
    func testReferencesResolveLoadedInstancesInSliceOrder() {
        let state = KeyImageNavigationState(
            references: [
                reference(sop: "2.25.3"),
                reference(sop: "2.25.missing"),
                reference(sop: "2.25.1")
            ],
            loadedInstances: [
                instance(sop: "2.25.1", slice: 1),
                instance(sop: "2.25.3", slice: 3)
            ]
        )

        XCTAssertEqual(state.resolvedImages.map(\.sliceIndex), [1, 3])
        XCTAssertEqual(state.selectedImage?.sliceIndex, 1)
        XCTAssertFalse(state.isFilterEnabled)
    }

    func testFilterSelectionNavigatesBetweenResolvedKeyImages() {
        var state = KeyImageNavigationState(
            references: [
                reference(sop: "2.25.2"),
                reference(sop: "2.25.5")
            ],
            loadedInstances: [
                instance(sop: "2.25.2", slice: 2),
                instance(sop: "2.25.5", slice: 5)
            ],
            isFilterEnabled: true
        )

        XCTAssertTrue(state.isFilterEnabled)
        XCTAssertEqual(state.selectedImage?.sliceIndex, 2)

        state.selectNext()
        XCTAssertEqual(state.selectedImage?.sliceIndex, 5)

        state.selectPrevious()
        XCTAssertEqual(state.selectedImage?.sliceIndex, 2)

        state.selectRelative(toSliceIndex: 2, offset: 1, wrapping: true)
        XCTAssertEqual(state.selectedImage?.sliceIndex, 5)
    }

    func testSeriesMismatchDoesNotResolveReference() {
        let state = KeyImageNavigationState(
            references: [
                reference(series: "2.25.series-a", sop: "2.25.1")
            ],
            loadedInstances: [
                instance(series: "2.25.series-b", sop: "2.25.1", slice: 1)
            ]
        )

        XCTAssertTrue(state.resolvedImages.isEmpty)
        XCTAssertNil(state.selectedImage)
    }

    private func reference(series: String = "2.25.series",
                           sop: String) -> KeyImageReference {
        KeyImageReference(
            studyInstanceUID: "2.25.study",
            seriesInstanceUID: series,
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: sop
        )
    }

    private func instance(series: String = "2.25.series",
                          sop: String,
                          slice: Int) -> LoadedKeyImageInstance {
        LoadedKeyImageInstance(
            studyInstanceUID: "2.25.study",
            seriesInstanceUID: series,
            sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
            sopInstanceUID: sop,
            sliceIndex: slice
        )
    }
}
