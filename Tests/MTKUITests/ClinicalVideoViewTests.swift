import XCTest
@testable import MTKUI

final class ClinicalVideoViewTests: XCTestCase {
    func testVideoDisplayStateNormalizesMetadata() {
        let url = URL(fileURLWithPath: "/tmp/video.h264")
        let state = ClinicalVideoDisplayState(
            title: "  Endoscopy Clip  ",
            codecLabel: "  H.264  ",
            dimensions: ClinicalVideoDimensions(columns: 640, rows: 480),
            frameCount: 120,
            frameRate: 30,
            streamByteCount: 4096,
            streamURL: url
        )

        XCTAssertEqual(state.title, "Endoscopy Clip")
        XCTAssertEqual(state.codecLabel, "H.264")
        XCTAssertEqual(state.dimensionsLabel, "640 x 480")
        XCTAssertEqual(state.frameRateLabel, "30 fps")
        XCTAssertEqual(state.durationSeconds, 4)
        XCTAssertEqual(state.durationLabel, "4 s")
        XCTAssertTrue(state.isPlayable)
    }

    func testVideoDisplayStateRejectsInvalidDimensionsAndTiming() {
        let state = ClinicalVideoDisplayState(
            codecLabel: "",
            dimensions: ClinicalVideoDimensions(columns: 0, rows: 480),
            frameCount: -2,
            frameRate: .nan,
            durationSeconds: -Double.infinity,
            streamByteCount: -1
        )

        XCTAssertEqual(state.codecLabel, "Video")
        XCTAssertNil(state.dimensions)
        XCTAssertEqual(state.frameCount, 0)
        XCTAssertNil(state.frameRate)
        XCTAssertNil(state.durationSeconds)
        XCTAssertEqual(state.streamByteCount, 0)
        XCTAssertFalse(state.isPlayable)
    }

    func testVideoDisplayStateUsesExplicitDurationWhenProvided() {
        let state = ClinicalVideoDisplayState(
            codecLabel: "MPEG-2",
            dimensions: ClinicalVideoDimensions(columns: 320, rows: 240),
            frameCount: 100,
            frameRate: 25,
            durationSeconds: 3.5,
            streamByteCount: 128
        )

        XCTAssertEqual(state.durationSeconds, 3.5)
        XCTAssertEqual(state.durationLabel, "3.5 s")
    }
}
