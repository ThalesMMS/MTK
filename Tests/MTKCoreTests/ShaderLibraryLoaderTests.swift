//  ShaderLibraryLoaderTests.swift
//  MTK
//  Ensures shader loader emits the required bundled MTK.metallib.
//  Thales Matheus Mendonça Santos — October 2025

import XCTest
#if canImport(Metal)
import Metal
#endif
@testable import MTKCore

final class ShaderLibraryLoaderTests: XCTestCase {
    func testLoadLibraryRequiresBundledMetallib() throws {
#if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        do {
            let library = try ShaderLibraryLoader.loadLibrary(for: device)
            XCTAssertNotNil(library)
        } catch ShaderLibraryLoader.LoaderError.metallibNotBundled {
#if DEBUG
            throw XCTSkip("MTK.metallib not bundled in this Debug configuration")
#else
            XCTFail("Bundle.module is missing required MTK.metallib in Release configuration")
#endif
        } catch ShaderLibraryLoader.LoaderError.metallibLoadFailed(let underlying) {
            XCTFail("Required MTK.metallib could not be loaded: \(underlying)")
        } catch {
            XCTFail("Unexpected shader loader error: \(error)")
        }
#else
        throw XCTSkip("Metal not available on this platform")
#endif
    }

    func testLoadLibraryReportsMetallibNotBundledWhenArtifactIsAbsent() throws {
#if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        do {
            _ = try ShaderLibraryLoader.loadLibrary(for: device, in: Bundle(for: Self.self))
            XCTFail("Expected metallibNotBundled when MTK.metallib is absent")
        } catch ShaderLibraryLoader.LoaderError.metallibNotBundled {
            let description = ShaderLibraryLoader.LoaderError.metallibNotBundled.errorDescription ?? ""
            XCTAssertTrue(
                description.contains("Required shader artifact MTK.metallib was not found"),
                "Unexpected error description: \(description)"
            )
        } catch {
            XCTFail("Expected metallibNotBundled, got \(error)")
        }
#else
        throw XCTSkip("Metal not available on this platform")
#endif
    }
}
