//  MetallibPackagingTests.swift
//  MTK
//  Ensures MTK.metallib ships in MTKCore bundles.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
@testable import MTKCore

final class MetallibPackagingTests: XCTestCase {
    func testBundleContainsMTKMetallib() throws {
        let bundle = VolumeRenderingResources.bundle
        guard let url = bundle.url(forResource: "MTK", withExtension: "metallib") else {
#if DEBUG
            XCTFail("Bundle.module is missing required MTK.metallib in Debug build")
#else
            XCTFail("Bundle.module is missing required MTK.metallib in Release build")
#endif
            return
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "Required MTK.metallib should be non-empty")
    }
}
