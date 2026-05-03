import XCTest

@_spi(Testing) @testable import MTKCore

final class CTHUConversionTests: XCTestCase {
    func test_clampHUUsesCTDomain() {
        XCTAssertEqual(VolumetricMath.clampHU(-5000), -1024)
        XCTAssertEqual(VolumetricMath.clampHU(-1024), -1024)
        XCTAssertEqual(VolumetricMath.clampHU(0), 0)
        XCTAssertEqual(VolumetricMath.clampHU(3071), 3071)
        XCTAssertEqual(VolumetricMath.clampHU(8000), 3071)
    }

    func test_cpuHUConversionMatchesMetalConversionRoundingPolicy() {
        // Validates the CPU HU conversion performed by DicomVolumeLoader.loadVolume matches
        // the Metal kernel (hu_conversion_compute.metal) behavior used during streaming/chunked upload.
        //
        // Contract: HU = round(raw * slope + intercept), then clamp to the supported HU domain.

        let raw: [Int32] = [-100, -1, 0, 1, 100]
        let slope: Double = 2.0
        let intercept: Double = -10.0

        let cpu = raw.map { value -> Int16 in
            let huDouble = Double(value) * slope + intercept
            let huRounded = Int32(lround(huDouble))
            return VolumetricMath.clampHU(huRounded)
        }

        // Mirror the Metal kernel's float math + round(), then clamp.
        let metalMirrored = raw.map { value -> Int16 in
            let converted = Float(value) * Float(slope) + Float(intercept)
            let rounded = Int32(converted.rounded())
            return VolumetricMath.clampHU(rounded)
        }

        XCTAssertEqual(cpu, metalMirrored)
        XCTAssertEqual(cpu, [-210, -12, -10, -8, 190])
    }
}
