import XCTest
import Metal
@testable import MTKCore

/// Issue #1682: a 3D texture extent Metal will not accept must be refused here,
/// because Metal does not refuse it — it aborts the process.
///
/// `MTLTextureDescriptor` validation ends in `MTLReportFailure` and `abort()`,
/// so `device.makeTexture(descriptor:)` never returns nil for a bad extent and
/// the `guard let` written to catch that never runs. On macOS this took the
/// whole app down when a series was opened from the database browser, and from
/// the outside it read as "double-clicking a series does not open the viewer".
///
/// These tests cannot assert the abort — a test that aborts takes the runner
/// with it. They assert the guard in front of it, which is the thing that has
/// to hold.
final class VolumeTextureDimensionValidationTests: XCTestCase {

    // MARK: - The extents Metal aborts on

    func test_zeroExtent_isRefusedRatherThanHandedToMetal() {
        for dimensions in [
            VolumeDimensions(width: 0, height: 4, depth: 4),
            VolumeDimensions(width: 4, height: 0, depth: 4),
            VolumeDimensions(width: 4, height: 4, depth: 0)
        ] {
            XCTAssertThrowsError(
                try VolumeTextureFactory.validateVolumeTextureDimensions(dimensions),
                "\(dimensions) would abort the process inside Metal"
            ) { error in
                XCTAssertEqual(
                    error as? VolumeTextureFactory.TextureUploadError,
                    .invalidDimensions(width: dimensions.width,
                                       height: dimensions.height,
                                       depth: dimensions.depth)
                )
            }
        }
    }

    func test_negativeExtent_isRefused() {
        XCTAssertThrowsError(
            try VolumeTextureFactory.validateVolumeTextureDimensions(
                VolumeDimensions(width: -1, height: 4, depth: 4)
            )
        )
    }

    /// Metal's ceiling for `type3D` is 2048 on every family this app runs on,
    /// and `MTLDevice` has no query for it — 1D and 2D limits are exposed, 3D is
    /// not. An oversized extent aborts exactly like a zero one.
    func test_extentAboveMetalsCeiling_isRefused() {
        let tooLarge = VolumeTextureFactory.maximumVolumeTextureExtent + 1
        XCTAssertThrowsError(
            try VolumeTextureFactory.validateVolumeTextureDimensions(
                VolumeDimensions(width: tooLarge, height: 4, depth: 4)
            )
        )
        XCTAssertNoThrow(
            try VolumeTextureFactory.validateVolumeTextureDimensions(
                VolumeDimensions(width: VolumeTextureFactory.maximumVolumeTextureExtent,
                                 height: 4,
                                 depth: 4)
            ),
            "the ceiling itself is a legal extent"
        )
    }

    // MARK: - The extents that must keep working

    func test_ordinaryVolumes_arePermitted() {
        for dimensions in [
            VolumeDimensions(width: 1, height: 1, depth: 1),
            VolumeDimensions(width: 512, height: 512, depth: 179),
            // A two-slice series is a real thing to open, and its depth of 2 is
            // as legal as 179. The guard must not turn "thin" into "invalid".
            VolumeDimensions(width: 512, height: 512, depth: 2)
        ] {
            XCTAssertNoThrow(
                try VolumeTextureFactory.validateVolumeTextureDimensions(dimensions),
                "\(dimensions) is a volume the viewer must still open"
            )
        }
    }

    // MARK: - Through the factory

    func test_generateAsync_throwsInsteadOfAbortingOnADegenerateVolume() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dataset = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 0, height: 0, depth: 0),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )
        let factory = VolumeTextureFactory(dataset: dataset)

        do {
            _ = try await factory.generateAsync(device: device, commandQueue: queue)
            XCTFail("a 0x0x0 volume must not produce a texture")
        } catch let error as VolumeTextureFactory.TextureUploadError {
            XCTAssertEqual(error, .invalidDimensions(width: 0, height: 0, depth: 0))
        }
    }

    func test_generate_returnsNilInsteadOfAbortingOnADegenerateVolume() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let dataset = VolumeDataset(
            data: Data(),
            dimensions: VolumeDimensions(width: 4, height: 4, depth: 0),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Unsigned
        )

        XCTAssertNil(VolumeTextureFactory(dataset: dataset).generate(device: device))
    }

    // MARK: - The other route to the same descriptor

    /// `ChunkedVolumeUploader` builds its own `type3D` descriptor and was
    /// checking extents against `UInt32.max` — four million, against a real
    /// ceiling of 2048. So the crash #1682 closed in `VolumeTextureFactory`
    /// was still reachable through here (issue #1684).
    ///
    /// A regression does not fail this test, it **aborts the runner**: that is
    /// the whole nature of the bug, and the reason the guard is worth a test of
    /// its own rather than being left to the call sites.
    func test_chunkedUploader_refusesAnExtentAboveTheCeiling() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let uploader = try ChunkedVolumeUploader(device: device, commandQueue: queue)
        // The radiograph from the issue, measured on the failing run.
        let descriptor = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 2500, height: 2048, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Unsigned
        )
        let noSlices = AsyncStream<VolumeUploadSlice> { $0.finish() }

        do {
            _ = try await uploader.upload(slices: noSlices, descriptor: descriptor)
            XCTFail("2500 × 2048 × 1 must never reach MTLTextureDescriptor validation")
        } catch let error as ChunkedVolumeUploadError {
            XCTAssertEqual(error, .invalidDimensions(descriptor.dimensions))
        }
    }

    /// The same uploader must still take an ordinary volume: a guard that
    /// refuses everything would read as "fixed" and break every CT.
    func test_chunkedUploader_stillAcceptsAnOrdinaryExtent() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        let uploader = try ChunkedVolumeUploader(device: device, commandQueue: queue)
        let descriptor = VolumeUploadDescriptor(
            dimensions: VolumeDimensions(width: 512, height: 512, depth: 8),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            sourcePixelFormat: .int16Unsigned
        )
        let noSlices = AsyncStream<VolumeUploadSlice> { $0.finish() }

        // It fails later, on the missing slices — the point is that it gets
        // past the dimension guard to fail for that reason instead.
        do {
            _ = try await uploader.upload(slices: noSlices, descriptor: descriptor)
        } catch let error as ChunkedVolumeUploadError {
            XCTAssertNotEqual(error, .invalidDimensions(descriptor.dimensions))
        } catch {
            // Any other error is equally fine: not a dimension refusal.
        }
    }
}
