//
//  MTKRenderingEngineSourceTests.swift
//  MTKCoreTests
//
//  Checks that per-frame viewport logging is gated by the performance-logging setting.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import XCTest

final class MTKRenderingEngineSourceTests: XCTestCase {
    func test_perFrameViewportLog_requiresPerformanceLogging() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Engine/MTKRenderingEngine.swift"))

        XCTAssertTrue(source.contains("if Logger.performanceLoggingEnabled {"))
        XCTAssertTrue(source.contains("\"Rendering viewport viewportID="))
    }
}
