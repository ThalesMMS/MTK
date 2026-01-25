//
//  SurfaceAdapterTests.swift
//  MTKCoreTests
//
//  Tests for RenderSurface protocol implementations and adapter patterns.
//  Demonstrates best practices for creating surface adapters that work with
//  the MTK volume rendering pipeline.
//
//  Thales Matheus Mendonça Santos — November 2025

import XCTest
import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import MTKCore

// MARK: - Mock Implementations

/// A simple test stub for RenderSurface implementations.
@MainActor
final class MockSurfaceAdapter: RenderSurface {
    var view: PlatformView {
#if os(iOS)
        UIView()
#elseif os(macOS)
        NSView()
#endif
    }

    // Track method calls for verification
    var displayedImages: [CGImage] = []
    var contentScales: [CGFloat] = []

    func display(_ image: CGImage) {
        displayedImages.append(image)
    }

    func setContentScale(_ scale: CGFloat) {
        contentScales.append(scale)
    }
}

/// A wrapper adapter demonstrating the pattern used in Isis.
@MainActor
final class WrappingSurfaceAdapter: RenderSurface {
    private var wrapped: any RenderSurface

    init(wrapped: any RenderSurface) {
        self.wrapped = wrapped
    }

    func update(wrapped: any RenderSurface) {
        self.wrapped = wrapped
    }

    var view: PlatformView { wrapped.view }

    func display(_ image: CGImage) {
        wrapped.display(image)
    }

    func setContentScale(_ scale: CGFloat) {
        wrapped.setContentScale(scale)
    }
}

/// A surface adapter for testing with image capture.
@MainActor
final class CaptureTestSurfaceAdapter: RenderSurface {
    var capturedImage: CGImage?
    var capturedScale: CGFloat?

    var view: PlatformView {
#if os(iOS)
        UIView()
#elseif os(macOS)
        NSView()
#endif
    }

    func display(_ image: CGImage) {
        capturedImage = image
    }

    func setContentScale(_ scale: CGFloat) {
        capturedScale = scale
    }
}

// MARK: - Test Cases

final class SurfaceAdapterTests: XCTestCase {
    @MainActor
    func testMockAdapterRecordsCalls() {
        let adapter = MockSurfaceAdapter()

        // Create a test image
        let testImage = createTestImage()
        adapter.display(testImage)
        adapter.setContentScale(2.0)

        XCTAssertEqual(adapter.displayedImages.count, 1)
        XCTAssertEqual(adapter.contentScales.count, 1)
        XCTAssertEqual(adapter.contentScales[0], 2.0)
    }

    @MainActor
    func testWrappingAdapterForwardsToWrapped() {
        let mockAdapter = MockSurfaceAdapter()
        let wrapper = WrappingSurfaceAdapter(wrapped: mockAdapter)

        let testImage = createTestImage()
        wrapper.display(testImage)
        wrapper.setContentScale(1.5)

        XCTAssertEqual(mockAdapter.displayedImages.count, 1)
        XCTAssertEqual(mockAdapter.contentScales.count, 1)
        XCTAssertEqual(mockAdapter.contentScales[0], 1.5)
    }

    @MainActor
    func testWrappingAdapterCanUpdateWrappedSurface() {
        let mockAdapter1 = MockSurfaceAdapter()
        let mockAdapter2 = MockSurfaceAdapter()
        let wrapper = WrappingSurfaceAdapter(wrapped: mockAdapter1)

        let testImage = createTestImage()
        wrapper.display(testImage)

        XCTAssertEqual(mockAdapter1.displayedImages.count, 1)
        XCTAssertEqual(mockAdapter2.displayedImages.count, 0)

        // Switch wrapped surface
        wrapper.update(wrapped: mockAdapter2)
        wrapper.display(testImage)

        XCTAssertEqual(mockAdapter1.displayedImages.count, 1)  // Still 1
        XCTAssertEqual(mockAdapter2.displayedImages.count, 1)  // Now 1
    }

    @MainActor
    func testCaptureAdapterStoresSurfaceCallData() {
        let adapter = CaptureTestSurfaceAdapter()

        let testImage = createTestImage()
        adapter.display(testImage)
        adapter.setContentScale(3.0)

        XCTAssertNotNil(adapter.capturedImage)
        XCTAssertEqual(adapter.capturedScale, 3.0)
    }

    @MainActor
    func testMultipleContentScaleUpdates() {
        let adapter = MockSurfaceAdapter()

        adapter.setContentScale(1.0)
        adapter.setContentScale(2.0)
        adapter.setContentScale(1.0)  // Change back

        XCTAssertEqual(adapter.contentScales, [1.0, 2.0, 1.0])
    }

    @MainActor
    func testViewAccessible() {
        let adapter = MockSurfaceAdapter()

        let view = adapter.view
        XCTAssertNotNil(view)
#if os(iOS)
        XCTAssertTrue(view is UIView)
#elseif os(macOS)
        XCTAssertTrue(view is NSView)
#endif
    }

    @MainActor
    func testAdapterConformanceToMainActor() {
        // This test ensures that adapters are properly annotated @MainActor.
        // The compiler will enforce this, but we verify it at runtime.
        let adapter = MockSurfaceAdapter()

        // All these calls should be safe on the main thread
        XCTAssert(Thread.isMainThread, "Tests should run on main thread")

        let testImage = createTestImage()
        adapter.display(testImage)
        adapter.setContentScale(1.0)

        XCTAssertEqual(adapter.contentScales.count, 1)
    }
}

// MARK: - Helper Functions

@MainActor
private func createTestImage() -> CGImage {
    let width = 10
    let height = 10
    let bytesPerRow = width
    let bytes = [UInt8](repeating: 128, count: width * height)

    let dataProvider = CGDataProvider(data: Data(bytes) as CFData)!
    let colorSpace = CGColorSpaceCreateDeviceGray()

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: dataProvider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

// MARK: - Integration Test Examples

final class SurfaceAdapterIntegrationTests: XCTestCase {
    /// Example demonstrating how a wrapper adapter can be used to add logging.
    @MainActor
    func testLoggingWrapperAdapter() {
        let baseAdapter = MockSurfaceAdapter()

        @MainActor
        final class LoggingWrapper: RenderSurface {
            let wrapped: any RenderSurface
            var loggedEvents: [String] = []

            init(wrapped: any RenderSurface) {
                self.wrapped = wrapped
            }

            var view: PlatformView { wrapped.view }

            func display(_ image: CGImage) {
                loggedEvents.append("display called")
                wrapped.display(image)
            }

            func setContentScale(_ scale: CGFloat) {
                loggedEvents.append("setContentScale called with \(scale)")
                wrapped.setContentScale(scale)
            }
        }

        let loggingWrapper = LoggingWrapper(wrapped: baseAdapter)
        let testImage = createTestImage()

        loggingWrapper.display(testImage)
        loggingWrapper.setContentScale(2.0)

        XCTAssertEqual(loggingWrapper.loggedEvents.count, 2)
        XCTAssertTrue(loggingWrapper.loggedEvents[0].contains("display"))
        XCTAssertTrue(loggingWrapper.loggedEvents[1].contains("setContentScale"))
    }

    /// Example demonstrating how multiple adapters can be chained.
    @MainActor
    func testChainedAdapters() {
        let base = MockSurfaceAdapter()

        @MainActor
        final class CountingWrapper: RenderSurface {
            let wrapped: any RenderSurface
            var displayCount = 0

            init(wrapped: any RenderSurface) {
                self.wrapped = wrapped
            }

            var view: PlatformView { wrapped.view }

            func display(_ image: CGImage) {
                displayCount += 1
                wrapped.display(image)
            }

            func setContentScale(_ scale: CGFloat) {
                wrapped.setContentScale(scale)
            }
        }

        let counter = CountingWrapper(wrapped: base)
        let testImage = createTestImage()

        counter.display(testImage)
        counter.display(testImage)
        counter.display(testImage)

        XCTAssertEqual(counter.displayCount, 3)
        XCTAssertEqual(base.displayedImages.count, 3)
    }
}
