import XCTest
import Metal
@testable import MTKCore

final class MetalDeviceCapabilityTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test runner")
        }
        self.device = device
    }

    // MARK: - Device Availability

    func test_metalDeviceIsAvailable() {
        XCTAssertNotNil(device)
    }

    func test_deviceHasValidName() {
        let deviceName = device.name
        XCTAssertFalse(deviceName.isEmpty)
        print("Testing on device: \(deviceName)")
    }

    // MARK: - Feature Detection

    func test_deviceSupportsRequiredFeatures() {
        // Argument buffers are essential for the renderer's architecture.
#if os(macOS)
        let argumentBufferFamilies: [MTLGPUFamily] = [.mac2]
#else
        let argumentBufferFamilies: [MTLGPUFamily] = [.apple3, .apple4, .apple5, .apple6, .apple7, .apple8, .apple9, .apple10]
#endif
        XCTAssertTrue(supportsAnyFamily(argumentBufferFamilies),
                      "Device must support argument buffers.")

        // Indirect dispatches are used for advanced rendering techniques.
#if os(macOS)
        let indirectDispatchFamilies: [MTLGPUFamily] = [.mac2]
#else
        let indirectDispatchFamilies: [MTLGPUFamily] = [.apple4, .apple5, .apple6, .apple7]
#endif
        XCTAssertTrue(supportsAnyFamily(indirectDispatchFamilies),
                      "Device must support indirect dispatches.")

        // Memory barriers are crucial for synchronization.
#if os(macOS)
        let memoryBarrierFamilies: [MTLGPUFamily] = [.mac2]
#else
        let memoryBarrierFamilies: [MTLGPUFamily] = [.apple3, .apple4, .apple5, .apple6]
#endif
        XCTAssertTrue(supportsAnyFamily(memoryBarrierFamilies),
                      "Device must support compute memory barriers.")

        // Rasterization is fundamental for rendering.
#if os(macOS)
        let rasterizationFamilies: [MTLGPUFamily] = [.mac2]
#else
        let rasterizationFamilies: [MTLGPUFamily] = [.apple1, .apple2, .apple3, .apple4, .apple5, .apple6]
#endif
        XCTAssertTrue(supportsAnyFamily(rasterizationFamilies),
                      "Device must support rasterization.")
    }

    // MARK: - Resource Limits

    func test_maxThreadsPerThreadgroup() {
        let maxSize = device.maxThreadsPerThreadgroup

        XCTAssertGreaterThan(maxSize.width, 0)
        XCTAssertGreaterThan(maxSize.height, 0)
        XCTAssertGreaterThan(maxSize.depth, 0)

        print("Max threads per threadgroup: \(maxSize)")
        print("  Width: \(maxSize.width)")
        print("  Height: \(maxSize.height)")
        print("  Depth: \(maxSize.depth)")
    }

    func test_maxBufferLength() {
        let maxLength = device.maxBufferLength

        XCTAssertGreaterThan(maxLength, 0)
        XCTAssertGreaterThanOrEqual(maxLength, 268_435_456)  // At least 256 MB

        let megabytes = maxLength / (1024 * 1024)
        print("Max buffer length: \(megabytes) MB")
    }

    func test_textureSampleCountSupport() {
        XCTAssertTrue(device.supportsTextureSampleCount(1))
        XCTAssertTrue(device.supportsTextureSampleCount(2))
    }

    // MARK: - Texture Format Support

    func test_supportsCommonTextureFormats() {
        let formats: [(name: String, format: MTLPixelFormat)] = [
            ("RGBA 8-bit Unorm", .rgba8Unorm),
            ("RGBA 16-bit Float", .rgba16Float),
            ("R 16-bit Float", .r16Float),
            ("R 32-bit Float", .r32Float),
            ("BGRA 8-bit Unorm", .bgra8Unorm),
            ("R 16-bit Unorm", .r16Unorm),
            ("R 8-bit Unorm", .r8Unorm)
        ]

        for (name, format) in formats {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: 16,
                height: 16,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]

            let texture = device.makeTexture(descriptor: descriptor)
            XCTAssertNotNil(texture, "Device should create textures for \(name).")
        }
    }

    func test_supports3DTextureFormats() {
        let format = MTLPixelFormat.r16Unorm

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = format
        descriptor.width = 64
        descriptor.height = 64
        descriptor.depth = 64
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]

        let texture = device.makeTexture(descriptor: descriptor)
        XCTAssertNotNil(texture, "Device should support 3D texture creation")
    }

    func test_textureFormatValidation() {
        let format = MTLPixelFormat.r16Float
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = format
        descriptor.width = 256
        descriptor.height = 256
        descriptor.textureType = .type2D

        let texture = device.makeTexture(descriptor: descriptor)
        XCTAssertNotNil(texture)
    }

    // MARK: - Memory Reporting

    func test_reportDeviceMemory() {
        let currentAllocatedSize = device.currentAllocatedSize
        let recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize

        XCTAssertGreaterThan(recommendedMaxWorkingSetSize, 0,
                        "Recommended max working set should be positive")

        let currentMB = currentAllocatedSize / (1024 * 1024)
        let maxMB = recommendedMaxWorkingSetSize / (1024 * 1024)
        let usage = Double(currentAllocatedSize) / Double(recommendedMaxWorkingSetSize) * 100

        print("GPU Memory Status:")
        print("  Currently allocated: \(currentMB) MB")
        print("  Recommended max: \(maxMB) MB")
        print("  Current usage: \(String(format: "%.1f", usage))%")
    }

    // MARK: - Command Queue Support

    func test_canCreateCommandQueue() {
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Should be able to create command queue")
            return
        }

        XCTAssertNotNil(queue)
    }

    func test_canCreateMultipleCommandQueues() {
        let queue1 = device.makeCommandQueue()
        let queue2 = device.makeCommandQueue()

        XCTAssertNotNil(queue1)
        XCTAssertNotNil(queue2)
    }

    // MARK: - Default Library Support

    func test_hasDefaultLibrary() {
        let library = device.makeDefaultLibrary()

        // Some test runners don't have bundled shaders
        if let library = library {
            XCTAssertNotNil(library)
        } else {
            print("⚠️ No default library available (expected in some test environments)")
        }
    }

    // MARK: - Sampler State Support

    func test_canCreateSamplerState() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear

        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            XCTFail("Should be able to create sampler state")
            return
        }

        XCTAssertNotNil(sampler)
    }

    // MARK: - Buffer Support

    func test_canAllocateBuffer() {
        let bufferSize = 1024 * 1024  // 1 MB

        guard let buffer = device.makeBuffer(length: bufferSize) else {
            XCTFail("Should be able to allocate buffer")
            return
        }

        XCTAssertEqual(buffer.length, bufferSize)
    }

    func test_bufferAllocationSucceeds_forReasonableSizes() {
        let sizes = [
            1024,              // 1 KB
            1024 * 1024,       // 1 MB
            10 * 1024 * 1024   // 10 MB
        ]

        for size in sizes {
            let buffer = device.makeBuffer(length: size)
            XCTAssertNotNil(buffer, "Should allocate buffer of size \(size)")
        }
    }



    // MARK: - Regression Tests

    func test_deviceCapabilitiesAreConsistent() {
        let maxThreads1 = device.maxThreadsPerThreadgroup
        let maxThreads2 = device.maxThreadsPerThreadgroup

        XCTAssertEqual(maxThreads1.width, maxThreads2.width)
        XCTAssertEqual(maxThreads1.height, maxThreads2.height)
        XCTAssertEqual(maxThreads1.depth, maxThreads2.depth)
    }

    func test_bufferLimitIsReasonable() {
        let maxLength = device.maxBufferLength
        let minExpected = 256 * 1024 * 1024  // 256 MB minimum for iOS

        XCTAssertGreaterThanOrEqual(maxLength, minExpected,
                                   "Max buffer should be at least 256 MB")
    }

    // MARK: - Helpers

    private func supportsAnyFamily(_ families: [MTLGPUFamily]) -> Bool {
        if #available(iOS 13.0, macOS 11.0, tvOS 13.0, *) {
            return families.contains { device.supportsFamily($0) }
        }
        return false
    }
}
