import XCTest
import Metal
import simd
@_spi(Testing) @testable import MTKCore

final class MPRTextureFrameTests: MetalMPRComputeAdapterTestCase {

    func test_makeSlabTextureReturnsExpectedMetadataForSignedAndUnsignedVolumes() async throws {
        let dimensions = VolumeDimensions(width: 6, height: 5, depth: 4)

        for pixelFormat in [VolumePixelFormat.int16Signed, .int16Unsigned] {
            let dataset = VolumeDatasetTestFactory.makeTestDataset(
                dimensions: dimensions,
                pixelFormat: pixelFormat,
                seed: 17
            )
            let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
            let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
                .generateAsync(device: device, commandQueue: commandQueue)

            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 1,
                steps: 1,
                blend: .single
            )

            XCTAssertEqual(frame.texture.width, dimensions.width)
            XCTAssertEqual(frame.texture.height, dimensions.height)
            XCTAssertEqual(frame.pixelFormat, pixelFormat)
            XCTAssertEqual(frame.texture.pixelFormat, pixelFormat.rawIntensityMetalPixelFormat)
            XCTAssertEqual(frame.intensityRange, dataset.intensityRange)
            XCTAssertEqual(frame.planeGeometry, plane)
            XCTAssertTrue(frame.textureFormatMatchesPixelFormat)
        }
    }

    func test_makeSlabTextureProducesValidRawTextureForAllBlendModes() async throws {
        let dataset = VolumeDatasetTestFactory.makeTestDataset(
            dimensions: VolumeDimensions(width: 8, height: 8, depth: 8),
            pixelFormat: .int16Signed,
            seed: 3
        )
        let plane = MPRTestHelpers.makeTestPlaneGeometry(for: dataset, axis: .z)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)

        for blend in MPRBlendMode.allCases {
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: blend == .single ? 1 : 3,
                steps: blend == .single ? 1 : 3,
                blend: blend
            )

            XCTAssertEqual(frame.texture.width, dataset.dimensions.width)
            XCTAssertEqual(frame.texture.height, dataset.dimensions.height)
            XCTAssertEqual(frame.texture.textureType, .type2D)
            XCTAssertEqual(frame.texture.pixelFormat, .r16Sint)
            XCTAssertEqual(frame.intensityRange, dataset.intensityRange)
        }
    }

    func test_makeSlabTextureProducesRawSignedTexture() async throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let dataset = makeGradientDataset(dimensions: dimensions)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)

        for axis in MPRPlaneAxis.allCases {
            let plane = makeVoxelCenterPlane(axis: axis, index: 1, dimensions: dimensions)

            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 1,
                steps: 1,
                blend: .single
            )

            XCTAssertEqual(frame.pixelFormat, .int16Signed)
            XCTAssertEqual(frame.texture.pixelFormat, .r16Sint)
            XCTAssertTrue(frame.textureFormatMatchesPixelFormat)
            XCTAssertEqual(frame.intensityRange, dataset.intensityRange)

            let actual = try readSignedPixels(from: frame)
            let expected = expectedPixels(axis: axis, fixedIndex: 1, dimensions: dimensions)
            XCTAssertEqual(actual, expected)
        }
    }

    func test_makeSlabTextureObliquePlaneMatchesCPUReference() async throws {
        let dimensions = VolumeDimensions(width: 5, height: 5, depth: 5)
        let dataset = makeGradientDataset(dimensions: dimensions)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = makeObliquePlane(dimensions: dimensions)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let actual = try readSignedPixels(from: frame)
        let expected = cpuReferencePixels(dataset: dataset,
                                          plane: plane,
                                          thickness: 1,
                                          steps: 1,
                                          blend: .single)
        assertSignedPixels(actual, equal: expected, accuracy: 1, "Oblique slab mismatch")
        
        // NOTE:
        // The GPU sampling path can differ by ±1 voxel at certain oblique-plane boundaries
        // due to nearest-neighbor tie-breaking / floating-point rounding.
        // This test intentionally tolerates a 1-intensity-step mismatch.
        // Exact (bitwise) equality is still asserted in axis-aligned tests above.
    }

    func test_makeSlabTextureThickSlabBlendModesMatchCPUReference() async throws {
        let dimensions = VolumeDimensions(width: 5, height: 5, depth: 5)
        let dataset = makeGradientDataset(dimensions: dimensions)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = makeVoxelCenterPlane(axis: .z, index: 2, dimensions: dimensions)

        for blend in [MPRBlendMode.maximum, .minimum, .average] {
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 2,
                steps: 3,
                blend: blend
            )

            let actual = try readSignedPixels(from: frame)
            let expected = cpuReferencePixels(dataset: dataset,
                                              plane: plane,
                                              thickness: 2,
                                              steps: 3,
                                              blend: blend)
            assertSignedPixels(actual, equal: expected, accuracy: 12, "Mismatch for \(blend)")
            assertMeanAbsoluteError(actual, expected, maximum: 2.0, "Aggregate mismatch for \(blend)")
            
            // NOTE:
            // Thick-slab GPU sampling can diverge from the CPU reference due to
            // differing tie-breaks/rounding when stepping along the slab normal.
            // This keeps a modest per-pixel cap plus a stricter aggregate guard
            // so systematic drift cannot hide behind isolated tie-break differences.
        }
    }

    func test_signedNegativeHUValuesSurviveSingleSliceMPR() async throws {
        let dimensions = VolumeDimensions(width: 3, height: 2, depth: 2)
        let dataset = makeSignedCoordinateDataset(dimensions: dimensions)
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let actual = try readSignedPixels(from: frame)
        let expected = [
            signedCoordinateValue(x: 0, y: 0, z: 0),
            signedCoordinateValue(x: 1, y: 0, z: 0),
            signedCoordinateValue(x: 2, y: 0, z: 0),
            signedCoordinateValue(x: 0, y: 1, z: 0),
            signedCoordinateValue(x: 1, y: 1, z: 0),
            signedCoordinateValue(x: 2, y: 1, z: 0)
        ]

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.min(), -512)
        XCTAssertEqual(frame.intensityRange, -1024...1024)
    }

    func test_nonIdentityAffineWorldPlaneMatchesCPUReference() async throws {
        let dimensions = VolumeDimensions(width: 4, height: 4, depth: 4)
        let orientation = VolumeOrientation(
            row: SIMD3<Float>(0, 1, 0),
            column: SIMD3<Float>(0, 0, 1),
            origin: SIMD3<Float>(10, -20, 30)
        )
        let dataset = makeSignedCoordinateDataset(
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1.25, y: 2.5, z: 3.75),
            orientation: orientation
        )
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = makeAffineWorldPlane(
            dataset: dataset,
            originVoxel: SIMD3<Float>(0, 0, 1),
            axisUVoxel: SIMD3<Float>(2, 2, 0),
            axisVVoxel: SIMD3<Float>(0, 0, 2)
        )

        XCTAssertNotEqual(plane.originWorld, plane.originVoxel)
        XCTAssertNotEqual(plane.axisUWorld, plane.axisUVoxel)

        let frame = try await adapter.makeSlabTexture(
            dataset: dataset,
            volumeTexture: volumeTexture,
            plane: plane,
            thickness: 1,
            steps: 1,
            blend: .single
        )

        let actual = try readSignedPixels(from: frame)
        let expected = cpuReferencePixels(dataset: dataset,
                                          plane: plane,
                                          thickness: 1,
                                          steps: 1,
                                          blend: .single)
        assertSignedPixels(actual, equal: expected, accuracy: 1, "Affine oblique MPR mismatch")
        assertMeanAbsoluteError(actual, expected, maximum: 0.5, "Affine oblique MPR aggregate mismatch")
    }

    func test_anisotropicSlabBlendModesUseExpectedSamples() async throws {
        let dimensions = VolumeDimensions(width: 2, height: 2, depth: 5)
        let dataset = makeZStackDataset(
            dimensions: dimensions,
            zValues: [-512, -256, 0, 256, 512],
            spacing: VolumeSpacing(x: 0.7, y: 1.3, z: 2.5)
        )
        let volumeTexture = try await VolumeTextureFactory(dataset: dataset)
            .generateAsync(device: device, commandQueue: commandQueue)
        let plane = MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                      axis: .z,
                                                      slicePosition: 0.5)

        let expectations: [(blend: MPRBlendMode, value: Int16)] = [
            (.maximum, 256),
            (.minimum, -256),
            (.average, 0)
        ]

        for expectation in expectations {
            let frame = try await adapter.makeSlabTexture(
                dataset: dataset,
                volumeTexture: volumeTexture,
                plane: plane,
                thickness: 2,
                steps: 3,
                blend: expectation.blend
            )

            let actual = try readSignedPixels(from: frame)
            XCTAssertEqual(actual, Array(repeating: expectation.value, count: 4), "Mismatch for \(expectation.blend)")
        }
    }

    private func makeGradientDataset(dimensions: VolumeDimensions) -> VolumeDataset {
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(Int16(x + y * 10 + z * 100))
                }
            }
        }

        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: 0...1024
        )
    }

    private func makeSignedCoordinateDataset(dimensions: VolumeDimensions,
                                             spacing: VolumeSpacing = VolumeSpacing(x: 1, y: 1, z: 1),
                                             orientation: VolumeOrientation = .canonical) -> VolumeDataset {
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)

        for z in 0..<dimensions.depth {
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    values.append(signedCoordinateValue(x: x, y: y, z: z))
                }
            }
        }

        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: -1024...1024,
            orientation: orientation
        )
    }

    private func makeZStackDataset(dimensions: VolumeDimensions,
                                   zValues: [Int16],
                                   spacing: VolumeSpacing) -> VolumeDataset {
        precondition(zValues.count == dimensions.depth)
        var values: [Int16] = []
        values.reserveCapacity(dimensions.voxelCount)

        for z in 0..<dimensions.depth {
            values.append(contentsOf: Array(repeating: zValues[z], count: dimensions.width * dimensions.height))
        }

        return VolumeDataset(
            data: values.withUnsafeBytes { Data($0) },
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: -1024...1024
        )
    }

    private func signedCoordinateValue(x: Int, y: Int, z: Int) -> Int16 {
        Int16(-512 + x * 16 + y * 64 + z * 256)
    }

    private func makeVoxelCenterPlane(axis: MPRPlaneAxis,
                                      index: Int,
                                      dimensions: VolumeDimensions) -> MPRPlaneGeometry {
        let dataset = makeGradientDataset(dimensions: dimensions)
        let span: Float
        switch axis {
        case .x:
            span = max(Float(dimensions.width - 1), 1)
        case .y:
            span = max(Float(dimensions.height - 1), 1)
        case .z:
            span = max(Float(dimensions.depth - 1), 1)
        }

        return MPRPlaneGeometryFactory.makePlane(for: dataset,
                                                 axis: axis,
                                                 slicePosition: Float(index) / span)
    }

    private func makeObliquePlane(dimensions: VolumeDimensions) -> MPRPlaneGeometry {
        let dims = SIMD3<Float>(
            Float(dimensions.width),
            Float(dimensions.height),
            Float(dimensions.depth)
        )
        let originVoxel = SIMD3<Float>(0.5, 0.5, 2.5)
        let axisUVoxel = SIMD3<Float>(2, 2, 0)
        let axisVVoxel = SIMD3<Float>(0, 0, 2)
        let normal = simd_normalize(simd_cross(axisUVoxel, axisVVoxel))

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisUVoxel,
            axisVVoxel: axisVVoxel,
            originWorld: originVoxel,
            axisUWorld: axisUVoxel,
            axisVWorld: axisVVoxel,
            originTexture: originVoxel / dims,
            axisUTexture: axisUVoxel / dims,
            axisVTexture: axisVVoxel / dims,
            normalWorld: normal
        )
    }

    private func makeAffineWorldPlane(dataset: VolumeDataset,
                                      originVoxel: SIMD3<Float>,
                                      axisUVoxel: SIMD3<Float>,
                                      axisVVoxel: SIMD3<Float>) -> MPRPlaneGeometry {
        let imageData = dataset.imageData
        let originWorld = imageData.indexToWorld.transformPoint(originVoxel)
        let axisUWorld = imageData.indexToWorld.transformPoint(originVoxel + axisUVoxel) - originWorld
        let axisVWorld = imageData.indexToWorld.transformPoint(originVoxel + axisVVoxel) - originWorld
        let originTexture = imageData.worldToTexture.transformPoint(originWorld)
        let axisUTexture = imageData.worldToTexture.transformPoint(originWorld + axisUWorld) - originTexture
        let axisVTexture = imageData.worldToTexture.transformPoint(originWorld + axisVWorld) - originTexture
        let normalWorld = simd_normalize(simd_cross(axisUWorld, axisVWorld))

        return MPRPlaneGeometry(
            originVoxel: originVoxel,
            axisUVoxel: axisUVoxel,
            axisVVoxel: axisVVoxel,
            originWorld: originWorld,
            axisUWorld: axisUWorld,
            axisVWorld: axisVWorld,
            originTexture: originTexture,
            axisUTexture: axisUTexture,
            axisVTexture: axisVTexture,
            normalWorld: normalWorld
        )
    }

    private func expectedPixels(axis: MPRPlaneAxis,
                                fixedIndex: Int,
                                dimensions: VolumeDimensions) -> [Int16] {
        var expected: [Int16] = []

        switch axis {
        case .x:
            for z in 0..<dimensions.depth {
                for y in 0..<dimensions.height {
                    expected.append(Int16(fixedIndex + y * 10 + z * 100))
                }
            }
        case .y:
            for z in 0..<dimensions.depth {
                for x in stride(from: dimensions.width - 1, through: 0, by: -1) {
                    expected.append(Int16(x + fixedIndex * 10 + z * 100))
                }
            }
        case .z:
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    expected.append(Int16(x + y * 10 + fixedIndex * 100))
                }
            }
        }

        return expected
    }

    private func readSignedPixels(from frame: MPRTextureFrame) throws -> [Int16] {
        try MPRTextureReadbackHelper.readValues(Int16.self,
                                                from: frame,
                                                device: device,
                                                commandQueue: commandQueue)
    }

    private func assertSignedPixels(_ actual: [Int16],
                                    equal expected: [Int16],
                                    accuracy: Int,
                                    _ message: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)),
                                     accuracy,
                                     "\(message) at \(index): \(actual) != \(expected)",
                                     file: file,
                                     line: line)
        }
    }

    private func assertMeanAbsoluteError(_ actual: [Int16],
                                         _ expected: [Int16],
                                         maximum: Double,
                                         _ message: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        guard actual.count == expected.count, !actual.isEmpty else { return }

        let totalError = zip(actual, expected).reduce(0) { total, pair in
            total + abs(Int(pair.0) - Int(pair.1))
        }
        let meanAbsoluteError = Double(totalError) / Double(actual.count)
        XCTAssertLessThanOrEqual(meanAbsoluteError,
                                 maximum,
                                 "\(message): mean absolute error \(meanAbsoluteError) exceeds \(maximum)",
                                 file: file,
                                 line: line)
    }

    private func cpuReferencePixels(dataset: VolumeDataset,
                                    plane: MPRPlaneGeometry,
                                    thickness: Int,
                                    steps: Int,
                                    blend: MPRBlendMode) -> [Int16] {
        let width = max(1, Int(round(simd_length(plane.axisUVoxel))) + 1)
        let height = max(1, Int(round(simd_length(plane.axisVVoxel))) + 1)
        let normalizedThickness = MPRPlaneGeometryFactory.normalizedTextureThickness(
            for: Float(thickness),
            dataset: dataset,
            plane: plane
        )
        let slabHalf = normalizedThickness / 2
        let normal = simd_normalize(simd_cross(plane.axisUTexture, plane.axisVTexture))
        var output = [Int16]()
        output.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let u = width > 1 ? Float(x) / Float(width - 1) : 0
                let v = height > 1 ? Float(y) / Float(height - 1) : 0
                let basePosition = plane.originTexture + u * plane.axisUTexture + v * plane.axisVTexture

                if steps <= 1 || slabHalf <= 0 || blend == .single {
                    output.append(sampleSignedVoxel(dataset: dataset, position: basePosition))
                    continue
                }

                let effectiveSteps = max(2, steps)
                let invStepsMinusOne = 1 / Float(effectiveSteps - 1)
                let slabSpan = 2 * slabHalf
                var values: [Int16] = []
                values.reserveCapacity(effectiveSteps)

                for sampleIndex in 0..<effectiveSteps {
                    let normalizedIndex = Float(sampleIndex) * invStepsMinusOne
                    let offset = (normalizedIndex - 0.5) * slabSpan
                    let samplePosition = basePosition + offset * normal
                    guard isInBounds(samplePosition) else { continue }
                    values.append(sampleSignedVoxel(dataset: dataset, position: samplePosition))
                }

                output.append(accumulateSigned(values,
                                               range: dataset.intensityRange,
                                               blend: blend))
            }
        }

        return output
    }

    private func sampleSignedVoxel(dataset: VolumeDataset,
                                   position: SIMD3<Float>) -> Int16 {
        guard isInBounds(position) else { return 0 }
        let dims = dataset.dimensions
        let x = nearestSampleIndex(position.x, count: dims.width)
        let y = nearestSampleIndex(position.y, count: dims.height)
        let z = nearestSampleIndex(position.z, count: dims.depth)
        let linearIndex = (z * dims.height * dims.width) + (y * dims.width) + x

        return dataset.data.withUnsafeBytes { buffer in
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: Int16.self)
            return pointer[linearIndex]
        }
    }

    private func accumulateSigned(_ values: [Int16],
                                  range: ClosedRange<Int32>,
                                  blend: MPRBlendMode) -> Int16 {
        guard !values.isEmpty else { return 0 }

        switch blend {
        case .maximum:
            return values.max() ?? 0
        case .minimum:
            return values.min() ?? 0
        case .average:
            let minValue = Float(range.lowerBound)
            let maxValue = Float(range.upperBound)
            let span = maxValue - minValue
            let densitySum = values.reduce(Float(0)) { partial, value in
                partial + min(max((Float(value) - minValue) / span, 0), 1)
            }
            let density = densitySum / Float(values.count)
            return Int16(minValue + density * span)
        case .single:
            return values[0]
        }
    }
    private func isInBounds(_ position: SIMD3<Float>) -> Bool {
        position.x >= -1e-6 && position.x <= 1 + 1e-6 &&
        position.y >= -1e-6 && position.y <= 1 + 1e-6 &&
        position.z >= -1e-6 && position.z <= 1 + 1e-6
    }

    private func clampIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(0, count - 1))
    }

    private func nearestSampleIndex(_ coordinate: Float, count: Int) -> Int {
        let centeredIndex = coordinate * Float(count) - 0.5
        let roundedIndex = centeredIndex >= 0
            ? floor(centeredIndex + 0.5)
            : ceil(centeredIndex - 0.5)
        return clampIndex(Int(roundedIndex), count: count)
    }
}
