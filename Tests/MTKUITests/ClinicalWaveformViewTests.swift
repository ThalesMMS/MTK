@testable import MTKUI
import XCTest

final class ClinicalWaveformViewTests: XCTestCase {
    func testTraceNormalizesSamplesForPreviewRendering() {
        let trace = ClinicalWaveformTrace(
            id: "lead-i",
            label: " I ",
            unitLabel: " uV ",
            samplingFrequency: 500,
            samples: [-100, 0, 50, 100]
        )

        XCTAssertEqual(trace.label, "I")
        XCTAssertEqual(trace.unitLabel, "uV")
        XCTAssertEqual(trace.durationSeconds, 0.008)
        XCTAssertEqual(trace.amplitudeRange, -100...100)
        XCTAssertEqual(trace.normalizedSamples(), [-1, 0, 0.5, 1])
    }

    func testDisplayStateReportsLongestTraceDuration() {
        let state = ClinicalWaveformDisplayState(
            title: " ECG ",
            traces: [
                ClinicalWaveformTrace(id: "i", label: "I", samplingFrequency: 500, samples: [1, 2]),
                ClinicalWaveformTrace(id: "ii", label: "II", samplingFrequency: 250, samples: [1, 2, 3, 4])
            ]
        )

        XCTAssertEqual(state.title, "ECG")
        XCTAssertFalse(state.isEmpty)
        XCTAssertEqual(state.durationSeconds, 0.016)
    }

#if canImport(SwiftUI)
    @MainActor
    func testClinicalWaveformViewCompiles() {
        let state = ClinicalWaveformDisplayState(
            traces: [ClinicalWaveformTrace(id: "i", label: "I", samplingFrequency: 500, samples: [1, -1])]
        )
        _ = ClinicalWaveformView(state: state)
    }
#endif
}
