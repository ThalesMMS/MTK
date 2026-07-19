import XCTest

final class MTKRenderingEngineSourceTests: XCTestCase {
    func test_perFrameViewportLog_requiresPerformanceLogging() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Engine/MTKRenderingEngine.swift"))

        XCTAssertTrue(source.contains("if Logger.performanceLoggingEnabled {"))
        XCTAssertTrue(source.contains("\"Rendering viewport viewportID="))
    }
}
