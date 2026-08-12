//
//  CPRComputeSourceTests.swift
//  MTKCoreTests
//
//  Checks that CPR shader sources provide stretched reformation kernels for signed and
//  unsigned volume textures.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation
import XCTest

final class CPRComputeSourceTests: XCTestCase {
    func test_cprShaderDefinesSignedAndUnsignedStretchedKernels() throws {
        let source = try String(
            contentsOfFile: sourceFilePath("Sources/MTKCore/Resources/MPR/cpr_compute.metal"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("kernel void computeStretchedCPR("))
        XCTAssertTrue(source.contains("kernel void computeStretchedCPRUnsigned("))
        XCTAssertTrue(source.contains("CPRColumnSample"))
        XCTAssertTrue(source.contains("centerTexture"))
        XCTAssertTrue(source.contains("verticalSpanTexture"))
    }
}
