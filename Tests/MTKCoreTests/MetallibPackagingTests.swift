//  MetallibPackagingTests.swift
//  MTK
//  Ensures MTK.metallib ships in Release bundles.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
@testable import MTKCore

final class MetallibPackagingTests: XCTestCase {
    func testReleaseBundleContainsVolumeRenderingMetallib() throws {
#if DEBUG
        throw XCTSkip("Skipped in Debug configuration")
#else
        let bundle = VolumeRenderingResources.bundle
        guard let url = bundle.url(forResource: "VolumeRendering", withExtension: "metallib") else {
            XCTFail("Bundle.module is missing MTK.metallib in Release build")
            return
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "MTK.metallib should be non-empty")
#endif
    }
}
