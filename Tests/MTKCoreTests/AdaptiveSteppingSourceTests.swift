//
//  AdaptiveSteppingSourceTests.swift
//  MTKCoreTests
//
//  Checks that adaptive ray-march stepping evaluates opacity before requesting gradient
//  work.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation
import XCTest

final class AdaptiveSteppingSourceTests: XCTestCase {
    func test_adaptiveSteppingDoesNotRequireGradientBeforeOpacity() throws {
        let source = try String(contentsOfFile: sourceFilePath(
            "Sources/MTKCore/Resources/Shaders/volume_compute.metal"
        ))

        XCTAssertTrue(source.contains(
            "const bool needsGradientBeforeOpacity = need2DTF || (!isDVR && lightingEnabled);"
        ))
        XCTAssertFalse(source.contains(
            "const bool needsGradientBeforeOpacity = adaptiveEnabled"
        ))
        XCTAssertTrue(source.contains("abs(huValue - previousHuValue)"))
    }
}
