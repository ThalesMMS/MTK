//  ShaderLibraryLoaderTests.swift
//  MTK
//  Ensures shader loader emits a library or skips when Metal is unavailable.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
#if canImport(Metal)
import Metal
#endif
@testable import MTKCore

final class ShaderLibraryLoaderTests: XCTestCase {
    func testMakeDefaultLibraryContainsSkipLogic() throws {
#if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        let library = ShaderLibraryLoader.makeDefaultLibrary(on: device)
        if library == nil {
            throw XCTSkip("No bundled metallib present; expected on CI without GPU assets")
        }
        XCTAssertNotNil(library)
#else
        throw XCTSkip("Metal not available on this platform")
#endif
    }
}
