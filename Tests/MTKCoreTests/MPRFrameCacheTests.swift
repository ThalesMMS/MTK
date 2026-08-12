import XCTest
import Metal

@_spi(Testing) @testable import MTKCore

final class MPRFrameCacheTests: XCTestCase {
    func testConcurrentAccessPreservesCacheIntegrity() async throws {
        let cache = MPRFrameCache<Int>()
        let frame = try makeFrame()
        let signatures = (0..<8).map { makeSignature(slicePosition: Float($0)) }

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<16 {
                group.addTask {
                    for iteration in 0..<250 {
                        let key = iteration % signatures.count
                        let signature = signatures[key]
                        switch (worker + iteration) % 3 {
                        case 0:
                            cache.store(frame, for: key, signature: signature)
                        case 1:
                            _ = cache.cachedFrame(for: key, matching: signature)
                        default:
                            cache.invalidate(key)
                        }
                    }
                }
            }
        }

        cache.invalidateAll()
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testCachedFrameReturnsOnlyForMatchingSignature() throws {
        let cache = MPRFrameCache<String>()
        let frame = try makeFrame()
        let signature = makeSignature(slicePosition: 0)
        let otherSignature = makeSignature(slicePosition: 1)

        cache.store(frame, for: "axial", signature: signature)

        let cachedTextureID = ObjectIdentifier(try XCTUnwrap(cache.cachedFrame(for: "axial", matching: signature)?.texture) as AnyObject)
        let storedTextureID = ObjectIdentifier(frame.texture as AnyObject)
        XCTAssertEqual(cachedTextureID, storedTextureID)
        XCTAssertNil(cache.cachedFrame(for: "axial", matching: otherSignature))
        XCTAssertEqual(cache.storedSignature(for: "axial"), signature)
    }

    func testCachedFrameMissesWhenAnySignatureFieldChanges() throws {
        let cache = MPRFrameCache<String>()
        let frame = try makeFrame()
        let baseline = makeSignature(slicePosition: 0,
                                     slabThickness: 1,
                                     slabSteps: 1,
                                     blend: .single)

        cache.store(frame, for: "axial", signature: baseline)

        XCTAssertNil(cache.cachedFrame(for: "axial",
                                       matching: makeSignature(slicePosition: 1,
                                                               slabThickness: 1,
                                                               slabSteps: 1,
                                                               blend: .single)))
        XCTAssertNil(cache.cachedFrame(for: "axial",
                                       matching: makeSignature(slicePosition: 0,
                                                               slabThickness: 3,
                                                               slabSteps: 1,
                                                               blend: .single)))
        XCTAssertNil(cache.cachedFrame(for: "axial",
                                       matching: makeSignature(slicePosition: 0,
                                                               slabThickness: 1,
                                                               slabSteps: 3,
                                                               blend: .single)))
        XCTAssertNil(cache.cachedFrame(for: "axial",
                                       matching: makeSignature(slicePosition: 0,
                                                               slabThickness: 1,
                                                               slabSteps: 1,
                                                               blend: .maximum)))
    }

    func testInvalidateRemovesSingleEntry() throws {
        let cache = MPRFrameCache<String>()
        let axialFrame = try makeFrame()
        let coronalFrame = try makeFrame()
        let signature = makeSignature(slicePosition: 0)

        cache.store(axialFrame, for: "axial", signature: signature)
        cache.store(coronalFrame, for: "coronal", signature: signature)
        cache.invalidate("axial")

        XCTAssertNil(cache.cachedFrame(for: "axial", matching: signature))
        XCTAssertNil(cache.storedSignature(for: "axial"))
        XCTAssertNotNil(cache.cachedFrame(for: "coronal", matching: signature))
    }

    func testInvalidateAllClearsAllEntries() throws {
        let cache = MPRFrameCache<String>()
        let frame = try makeFrame()
        let signature = makeSignature(slicePosition: 0)

        cache.store(frame, for: "axial", signature: signature)
        cache.store(frame, for: "coronal", signature: signature)
        cache.invalidateAll()

        XCTAssertNil(cache.cachedFrame(for: "axial", matching: signature))
        XCTAssertNil(cache.cachedFrame(for: "coronal", matching: signature))
    }

    func testStoreOverwritesExistingEntryForSameKey() throws {
        let cache = MPRFrameCache<String>()
        let firstFrame = try makeFrame()
        let secondFrame = try makeFrame()
        let firstSignature = makeSignature(slicePosition: 0)
        let secondSignature = makeSignature(slicePosition: 1)

        cache.store(firstFrame, for: "axial", signature: firstSignature)
        cache.store(secondFrame, for: "axial", signature: secondSignature)

        XCTAssertNil(cache.cachedFrame(for: "axial", matching: firstSignature))
        let cachedTextureID = ObjectIdentifier(try XCTUnwrap(cache.cachedFrame(for: "axial",
                                                                               matching: secondSignature)?.texture) as AnyObject)
        XCTAssertEqual(cachedTextureID, ObjectIdentifier(secondFrame.texture as AnyObject))
        XCTAssertEqual(cache.storedSignature(for: "axial"), secondSignature)
    }

    func test_cachedFrameLease_releasesAfterPresentationAndInvalidation() throws {
        let device = try requireMetalDevice()
        let pool = OutputTexturePool()
        let lease = try pool.acquireWithLease(width: 1,
                                              height: 1,
                                              pixelFormat: .r16Uint,
                                              device: device)
        let frame = makeFrame(texture: lease.texture,
                              outputTextureLease: lease)
        let cache = MPRFrameCache<String>()
        let signature = makeSignature(slicePosition: 0)

        let retainedFrame = cache.store(frame, for: "axial", signature: signature)

        XCTAssertTrue(retainedFrame.debugHasOutputTextureLease)
        XCTAssertTrue(retainedFrame.outputTextureLeaseRetainedByCache)
        XCTAssertNil(retainedFrame.presentationManagedOutputTextureLease)
        lease.markPresented()
        cache.invalidate("axial")
        XCTAssertFalse(retainedFrame.debugHasOutputTextureLease)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    func test_cacheInvalidation_releasesLeaseNeverSubmittedForPresentation() throws {
        let device = try requireMetalDevice()
        let pool = OutputTexturePool()
        let lease = try pool.acquireWithLease(width: 1,
                                              height: 1,
                                              pixelFormat: .r16Uint,
                                              device: device)
        let frame = makeFrame(texture: lease.texture,
                              outputTextureLease: lease)
        let cache = MPRFrameCache<String>()

        let retainedFrame = cache.store(
            frame,
            for: "axial",
            signature: makeSignature(slicePosition: 0)
        )

        cache.invalidate("axial")

        XCTAssertFalse(retainedFrame.debugHasOutputTextureLease)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    func test_cacheInvalidation_waitsForSubmittedPresentation() throws {
        let device = try requireMetalDevice()
        let pool = OutputTexturePool()
        let lease = try pool.acquireWithLease(width: 1,
                                              height: 1,
                                              pixelFormat: .r16Uint,
                                              device: device)
        let frame = makeFrame(texture: lease.texture,
                              outputTextureLease: lease)
        let cache = MPRFrameCache<String>()
        let retainedFrame = cache.store(
            frame,
            for: "axial",
            signature: makeSignature(slicePosition: 0)
        )

        lease.markPresentationSubmitted()
        cache.invalidate("axial")

        XCTAssertTrue(retainedFrame.debugHasOutputTextureLease)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 0)

        lease.markPresented()

        XCTAssertFalse(retainedFrame.debugHasOutputTextureLease)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    func test_cacheDeinit_releasesRetainedLeaseNeverSubmittedForPresentation() throws {
        let device = try requireMetalDevice()
        let pool = OutputTexturePool()
        let lease = try pool.acquireWithLease(width: 1,
                                              height: 1,
                                              pixelFormat: .r16Uint,
                                              device: device)
        let frame = makeFrame(texture: lease.texture,
                              outputTextureLease: lease)
        let retainedFrame: MPRTextureFrame

        do {
            let cache = MPRFrameCache<String>()
            retainedFrame = cache.store(
                frame,
                for: "axial",
                signature: makeSignature(slicePosition: 0)
            )
        }

        XCTAssertFalse(retainedFrame.debugHasOutputTextureLease)
        XCTAssertEqual(pool.debugLeaseReleasedCount, 1)
    }

    private func makeFrame() throws -> MPRTextureFrame {
        let device = try requireMetalDevice()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            XCTFail("Failed to create test texture")
            throw XCTSkip("Unable to create Metal texture")
        }
        return makeFrame(texture: texture)
    }

    private func makeFrame(texture: any MTLTexture,
                           outputTextureLease: OutputTextureLease? = nil) -> MPRTextureFrame {
        MPRTextureFrame(texture: texture,
                        intensityRange: 0...0,
                        pixelFormat: .int16Unsigned,
                        planeGeometry: .canonical(axis: .z),
                        outputTextureLease: outputTextureLease)
    }

    private func makeSignature(slicePosition: Float,
                               slabThickness: Int = 1,
                               slabSteps: Int = 1,
                               blend: MPRBlendMode = .single) -> MPRFrameSignature {
        MPRFrameSignature(
            planeGeometry: MPRPlaneGeometry(originVoxel: SIMD3<Float>(0, 0, slicePosition),
                                            axisUVoxel: SIMD3<Float>(1, 0, 0),
                                            axisVVoxel: SIMD3<Float>(0, 1, 0),
                                            originWorld: .zero,
                                            axisUWorld: SIMD3<Float>(1, 0, 0),
                                            axisVWorld: SIMD3<Float>(0, 1, 0),
                                            originTexture: .zero,
                                            axisUTexture: SIMD3<Float>(1, 0, 0),
                                            axisVTexture: SIMD3<Float>(0, 1, 0),
                                            normalWorld: SIMD3<Float>(0, 0, 1)),
            slabThickness: slabThickness,
            slabSteps: slabSteps,
            blend: blend
        )
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }
}
