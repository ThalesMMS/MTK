import CoreGraphics
import Metal
import MetalKit
import ObjectiveC.runtime
import XCTest
@_spi(Testing) import MTKCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
@_spi(Testing) @testable import MTKUI

@MainActor
final class MetalViewportSurfaceTests: XCTestCase {
    func testSurfaceConfiguresMTKViewForManualPresentation() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 32, height: 24)
        surface.setContentScale(2)

        XCTAssertTrue(surface.metalView.isPaused)
        XCTAssertFalse(surface.metalView.enableSetNeedsDisplay)
        XCTAssertFalse(surface.metalView.framebufferOnly)
        XCTAssertFalse(surface.metalView.autoResizeDrawable)
        XCTAssertEqual(surface.drawablePixelSize.width, 64)
        XCTAssertEqual(surface.drawablePixelSize.height, 48)
        XCTAssertEqual(surface.metalView.drawableSize.width, 64)
        XCTAssertEqual(surface.metalView.drawableSize.height, 48)
    }

    func testDrawableSizeChangeCallbackTracksScaleAndResize() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
        var reportedSizes: [CGSize] = []
        surface.onDrawableSizeChange = { reportedSizes.append($0) }

        surface.view.frame = CGRect(x: 0, y: 0, width: 20, height: 10)
        surface.setContentScale(3)

        XCTAssertEqual(surface.drawablePixelSize, CGSize(width: 60, height: 30))
        XCTAssertEqual(reportedSizes.last, CGSize(width: 60, height: 30))
    }

    func testMultipleViewportSurfacesKeepIndependentDrawableState() throws {
        let device = try requireMetalDevice()
        let first = try MetalViewportSurface(device: device)
        let second = try MetalViewportSurface(device: device)

        XCTAssertNotEqual(first.viewObjectIdentifier, second.viewObjectIdentifier)
        XCTAssertNotEqual(first.commandQueueObjectIdentifier, second.commandQueueObjectIdentifier)

        first.view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        first.setContentScale(1)
        second.view.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        second.setContentScale(2)

        XCTAssertFalse(first.metalView === second.metalView)
        XCTAssertEqual(first.drawablePixelSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(second.drawablePixelSize, CGSize(width: 80, height: 40))
        XCTAssertEqual(first.metalView.drawableSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(second.metalView.drawableSize, CGSize(width: 80, height: 40))
    }

    func testExplicitlyInjectedCommandQueueCanBeShared() throws {
        let device = try requireMetalDevice()
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable on this test runner")
        }

        let first = try MetalViewportSurface(device: device, commandQueue: queue)
        let second = try MetalViewportSurface(device: device, commandQueue: queue)

        XCTAssertEqual(first.commandQueueObjectIdentifier, second.commandQueueObjectIdentifier)
        XCTAssertNotEqual(first.viewObjectIdentifier, second.viewObjectIdentifier)
    }

    func testMultiSurfacePresentationDoesNotCrossContaminateState() throws {
        let device = try requireMetalDevice()
        let first = try MetalViewportSurface(device: device)
        let second = try MetalViewportSurface(device: device)
        first.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        second.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        first.setContentScale(1)
        second.setContentScale(1)

        let firstTexture = try makeTexture(device: device,
                                           width: 4,
                                           height: 4,
                                           pixelFormat: .bgra8Unorm)
        let secondTexture = try makeTexture(device: device,
                                            width: 4,
                                            height: 4,
                                            pixelFormat: .bgra8Unorm)

        XCTAssertNoThrow(try first.present(firstTexture))
        XCTAssertNoThrow(try second.present(secondTexture))

        XCTAssertTrue(first.presentedTexture === firstTexture)
        XCTAssertTrue(second.presentedTexture === secondTexture)
        XCTAssertFalse(first.presentedTexture === second.presentedTexture)
    }

    func testOutputTextureDescriptorMatchesDrawableSize() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device, pixelFormat: .rgba16Float)
        surface.view.frame = CGRect(x: 0, y: 0, width: 17, height: 11)
        surface.setContentScale(2)

        let descriptor = surface.makeOutputTextureDescriptor()

        XCTAssertEqual(descriptor.pixelFormat, .rgba16Float)
        XCTAssertEqual(descriptor.width, 34)
        XCTAssertEqual(descriptor.height, 22)
        XCTAssertTrue(descriptor.usage.contains(.shaderRead))
        XCTAssertTrue(descriptor.usage.contains(.shaderWrite))
        XCTAssertTrue(descriptor.usage.contains(.renderTarget))
    }

    func testPresentFrameUsesTextureNativePath() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        surface.setContentScale(1)
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .bgra8Unorm)
        let frame = VolumeRenderFrame(
            texture: texture,
            metadata: VolumeRenderFrame.Metadata(
                viewportSize: CGSize(width: 4, height: 4),
                samplingDistance: 1,
                compositing: .frontToBack,
                quality: .interactive,
                pixelFormat: .bgra8Unorm
            )
        )

        XCTAssertNoThrow(try surface.present(frame: frame))
        XCTAssertTrue(surface.presentedTexture === texture)
    }

    func testPresentRejectsTexturePixelFormatMismatch() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device, pixelFormat: .bgra8Unorm)
        surface.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        surface.setContentScale(1)
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .rgba8Unorm)

        XCTAssertThrowsError(try surface.present(texture)) { error in
            XCTAssertEqual(
                error as? MetalViewportSurfaceError,
                .pixelFormatMismatch(surface: .bgra8Unorm, texture: .rgba8Unorm)
            )
        }
        XCTAssertNil(surface.presentedTexture)
    }

    func testSurfacePresentationReleasesLeaseAfterCommandBufferCompletion() async throws {
        let device = try requireMetalDevice()
        let engine = try await MTKRenderingEngine(device: device)
        let viewport = try await engine.createViewport(
            ViewportDescriptor(type: .volume3D,
                               initialSize: CGSize(width: 8, height: 8))
        )
        try await engine.setVolume(makeDataset(), for: viewport)

        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        surface.setContentScale(1)

        for _ in 0..<3 {
            let frame = try await engine.render(viewport)
            let lease = try XCTUnwrap(frame.outputTextureLease)

            try surface.present(frame)
            try await waitUntilReleased(lease)
        }

        let poolInUseCount = await engine.debugOutputPoolInUseCount
        let poolTextureCount = await engine.debugOutputPoolTextureCount
        let leaseAcquiredCount = await engine.debugOutputTextureLeaseAcquiredCount
        let leasePresentedCount = await engine.debugOutputTextureLeasePresentedCount
        let leaseReleasedCount = await engine.debugOutputTextureLeaseReleasedCount

        XCTAssertEqual(poolInUseCount, 0)
        XCTAssertEqual(poolTextureCount, 1)
        XCTAssertEqual(leaseAcquiredCount, 3)
        XCTAssertEqual(leasePresentedCount, 3)
        XCTAssertEqual(leaseReleasedCount, 3)
    }

    func testSurfacePresentationRecordsProfilerMetrics() async throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        surface.setContentScale(1)
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .bgra8Unorm)
        let profiler = ClinicalProfiler.shared
        profiler.reset(environment: .unknown)

        try surface.present(texture)

        let sample = try await waitForPresentationSample(profiler: profiler)
        XCTAssertEqual(sample.stageType, .presentationPass)
        XCTAssertEqual(sample.viewportContext.resolutionWidth, 4)
        XCTAssertEqual(sample.viewportContext.resolutionHeight, 4)
        XCTAssertEqual(sample.metadata?["sourceTextureSize"], "4x4")
        XCTAssertEqual(sample.metadata?["drawableSize"], "4x4")
        XCTAssertEqual(sample.metadata?["sourcePixelFormat"], "\(MTLPixelFormat.bgra8Unorm)")
        XCTAssertEqual(sample.metadata?["drawablePixelFormat"], "\(MTLPixelFormat.bgra8Unorm)")
        XCTAssertNotNil(sample.metadata?["cpuPresentTimeMilliseconds"])
        XCTAssertNotNil(sample.metadata?["gpuPresentTimeMilliseconds"])
    }

    /// Enforces the ADR contract that onscreen presentation never performs CPU readback.
    func testPresentationPassDoesNotInvokeTextureGetBytesDuringPresentation() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
        surface.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        surface.setContentScale(1)
        let texture = try makeTexture(device: device,
                                      width: 4,
                                      height: 4,
                                      pixelFormat: .bgra8Unorm)

        try TextureReadbackSpy.assertNoReadback(on: texture) {
            try surface.present(texture)
        }
    }

#if canImport(SwiftUI)
    func testViewportPresentingViewCanBeConstructedWithMetalViewportSurface() throws {
        let device = try requireMetalDevice()
        let surface: any ViewportPresenting = try MetalViewportSurface(device: device)

        _ = ViewportPresentingView(surface: surface)
    }

    func testMTKViewRepresentableContainerHostsSurfaceView() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)
#if os(iOS)
        let container = MTKViewRepresentable.ContainerView()
#elseif os(macOS)
        let container = MTKViewRepresentable.ContainerView(frame: .zero)
#endif

        container.host(surface.view)

        XCTAssertTrue(surface.view.superview === container)
        XCTAssertFalse(surface.view.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(container.constraints.count, 4)
    }

    func testMetalViewportContainerCanBeConstructedWithOverlay() throws {
        let device = try requireMetalDevice()
        let surface = try MetalViewportSurface(device: device)

        _ = MetalViewportContainer(surface: surface) {
            Color.clear
        }
    }
#endif

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }

    private func makeDataset() -> VolumeDataset {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        return VolumeDataset(
            data: Data(count: dimensions.voxelCount * VolumePixelFormat.int16Signed.bytesPerVoxel),
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: (-1024)...3071,
            recommendedWindow: (-100)...300
        )
    }

    private func waitUntilReleased(_ lease: OutputTextureLease,
                                   timeoutNanoseconds: UInt64 = 2_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !lease.isReleased {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for lease release")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForPresentationSample(profiler: ClinicalProfiler,
                                           timeoutNanoseconds: UInt64 = 2_000_000_000) async throws -> ProfilingSample {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let sample = profiler.sessionSnapshot()?.samples.last(where: { $0.stageType == .presentationPass }) {
                return sample
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for presentation sample")
        throw TestTimeoutError.presentationSample
    }

    private func makeTexture(device: any MTLDevice,
                             width: Int,
                             height: Int,
                             pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Failed to create test texture")
        }
        return texture
    }

    private func sourceFilePath(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appendingPathComponent(relativePath).path
    }
}

private enum TestTimeoutError: Error {
    case presentationSample
}

private enum TextureReadbackSpy {
    private typealias GetBytes2DFunction = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer,
        Int,
        MTLRegion,
        Int
    ) -> Void

    private typealias GetBytesSliceFunction = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer,
        Int,
        Int,
        MTLRegion,
        Int,
        Int
    ) -> Void

    private final class State {
        var didReadBack = false
    }

    private struct SwizzleRecord {
        let selector: Selector
        let originalIMP: IMP
        let swizzledIMP: IMP
    }

    static func assertNoReadback(on texture: any MTLTexture,
                                 file: StaticString = #filePath,
                                 line: UInt = #line,
                                 during body: () throws -> Void) throws {
        let textureClass: AnyClass = type(of: texture as AnyObject)
        let state = State()
        let records = try install(on: textureClass, state: state)
        defer { uninstall(records, from: textureClass) }

        try body()
        XCTAssertFalse(state.didReadBack, "Presentation path unexpectedly invoked getBytes on the source texture.", file: file, line: line)
    }

    private static func install(on textureClass: AnyClass, state: State) throws -> [SwizzleRecord] {
        var records: [SwizzleRecord] = []

        try install2D(on: textureClass, state: state, records: &records)
        try installSlice(on: textureClass, state: state, records: &records)

        return records
    }

    private static func install2D(on textureClass: AnyClass,
                                  state: State,
                                  records: inout [SwizzleRecord]) throws {
        let selector = NSSelectorFromString("getBytes:bytesPerRow:fromRegion:mipmapLevel:")
        guard let method = class_getInstanceMethod(textureClass, selector) else {
            throw XCTSkip("Concrete Metal texture class does not expose 2D getBytes selector.")
        }
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: GetBytes2DFunction.self)
        let block: @convention(block) (AnyObject, UnsafeMutableRawPointer, Int, MTLRegion, Int) -> Void = {
            object, pixelBytes, bytesPerRow, region, level in
            state.didReadBack = true
            original(object, selector, pixelBytes, bytesPerRow, region, level)
        }
        let swizzledIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, swizzledIMP)
        records.append(SwizzleRecord(selector: selector, originalIMP: originalIMP, swizzledIMP: swizzledIMP))
    }

    private static func installSlice(on textureClass: AnyClass,
                                     state: State,
                                     records: inout [SwizzleRecord]) throws {
        let selector = NSSelectorFromString("getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:")
        guard let method = class_getInstanceMethod(textureClass, selector) else {
            throw XCTSkip("Concrete Metal texture class does not expose slice getBytes selector.")
        }
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: GetBytesSliceFunction.self)
        let block: @convention(block) (AnyObject, UnsafeMutableRawPointer, Int, Int, MTLRegion, Int, Int) -> Void = {
            object, pixelBytes, bytesPerRow, bytesPerImage, region, level, slice in
            state.didReadBack = true
            original(object, selector, pixelBytes, bytesPerRow, bytesPerImage, region, level, slice)
        }
        let swizzledIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, swizzledIMP)
        records.append(SwizzleRecord(selector: selector, originalIMP: originalIMP, swizzledIMP: swizzledIMP))
    }

    private static func uninstall(_ records: [SwizzleRecord], from textureClass: AnyClass) {
        for record in records {
            guard let method = class_getInstanceMethod(textureClass, record.selector) else {
                continue
            }
            method_setImplementation(method, record.originalIMP)
            imp_removeBlock(record.swizzledIMP)
        }
    }
}
