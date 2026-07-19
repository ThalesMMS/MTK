//
//  VolumeDatasetFactoryTests.swift
//  MTKTests
//

import Foundation
import simd
import XCTest
@testable import MTKCore

final class VolumeDatasetFactoryTests: XCTestCase {

    func test_directInitializers_withoutProvenanceFlags_defaultToUnverified() {
        let dimensions = VolumeDimensions(width: 1, height: 1, depth: 1)
        let spacing = VolumeSpacing(x: 1, y: 1, z: 1)
        let imageData = ImageData3D(
            dimensions: dimensions,
            spacing: spacing,
            orientation: .canonical,
            pixelFormat: .int16Signed
        )
        let dataset = VolumeDataset(
            data: voxelData([0]),
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed
        )

        XCTAssertFalse(imageData.isInPlaneSpacingCalibrated)
        XCTAssertFalse(imageData.isOrientationVerified)
        XCTAssertFalse(dataset.isInPlaneSpacingCalibrated)
        XCTAssertFalse(dataset.isOrientationVerified)
    }

    func test_directDTOInput_mapsAllFieldsToVolumeDataset() {
        let voxels = voxelData([-12, 42, 512, 1_024])
        let dimensions = VolumetricDimensions(width: 2, height: 2, depth: 1)
        let spacing = VolumetricSpacing(x: 0.7, y: 0.8, z: 2.5)
        let orientation = VolumetricOrientation(
            row: SIMD3<Float>(0, 1, 0),
            column: SIMD3<Float>(-1, 0, 0),
            origin: SIMD3<Float>(12, -8, 30)
        )

        let dataset = VolumeDatasetFactory.makeVolumeDataset(
            voxels: voxels,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: (-12)...1_024,
            orientation: orientation,
            recommendedWindow: 0...400
        )

        assertDataset(
            dataset,
            matches: voxels,
            dimensions: dimensions,
            spacing: spacing,
            pixelFormat: .int16Signed,
            intensityRange: (-12)...1_024,
            orientation: orientation,
            recommendedWindow: 0...400
        )
        XCTAssertFalse(dataset.isInPlaneSpacingCalibrated)
        XCTAssertFalse(dataset.isOrientationVerified)
    }

    func test_volumetricSeriesData_preservesLoaderProvidedVolumeContract() {
        let seriesData = VolumetricSeriesData(
            voxels: voxelData([0, 1, 2, 3, 4, 5]),
            dimensions: VolumetricDimensions(width: 1, height: 2, depth: 3),
            spacing: VolumetricSpacing(x: 1.0, y: 1.0, z: 1.5),
            pixelFormat: .int16Unsigned,
            intensityRange: 0...5,
            orientation: VolumetricOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(3, 6, 9)
            ),
            recommendedWindow: 1...4
        )

        let dataset = VolumeDatasetFactory.makeVolumeDataset(from: seriesData)

        assertDataset(
            dataset,
            matches: seriesData.voxels,
            dimensions: seriesData.dimensions,
            spacing: seriesData.spacing,
            pixelFormat: .int16Unsigned,
            intensityRange: seriesData.intensityRange,
            orientation: seriesData.orientation,
            recommendedWindow: seriesData.recommendedWindow
        )
        XCTAssertFalse(seriesData.isInPlaneSpacingCalibrated)
        XCTAssertFalse(seriesData.isOrientationVerified)
        XCTAssertFalse(dataset.isInPlaneSpacingCalibrated)
        XCTAssertFalse(dataset.isOrientationVerified)
    }

    func test_explicitCalibrationFlags_preservesProvidedValues() {
        let dataset = VolumeDatasetFactory.makeVolumeDataset(
            voxels: voxelData([0]),
            dimensions: VolumetricDimensions(width: 1, height: 1, depth: 1),
            spacing: VolumetricSpacing(x: 1, y: 1, z: 1),
            isInPlaneSpacingCalibrated: true,
            isOrientationVerified: true,
            pixelFormat: .int16Signed,
            intensityRange: 0...0,
            orientation: VolumetricOrientation(
                row: SIMD3<Float>(1, 0, 0),
                column: SIMD3<Float>(0, 1, 0),
                origin: .zero
            ),
            recommendedWindow: nil
        )

        XCTAssertTrue(dataset.isInPlaneSpacingCalibrated)
        XCTAssertTrue(dataset.isOrientationVerified)
    }

    func test_providerBoundary_acceptsAppSideAdapterWithMTKDTOs() {
        let adapter = AppSideVolumeInput(
            voxels: voxelData([-1, 0, 1, 2, 3, 4, 5, 6]),
            dimensions: VolumetricDimensions(width: 2, height: 2, depth: 2),
            spacing: VolumetricSpacing(x: 0.5, y: 0.6, z: 0.7),
            pixelFormat: .int16Signed,
            intensityRange: (-1)...6,
            orientation: VolumetricOrientation(
                row: SIMD3<Float>(0, 1, 0),
                column: SIMD3<Float>(0, 0, 1),
                origin: SIMD3<Float>(5, 10, 15)
            ),
            recommendedWindow: nil
        )

        let dataset = VolumeDatasetFactory.makeVolumeDataset(from: adapter)

        assertDataset(
            dataset,
            matches: adapter.voxels,
            dimensions: adapter.dimensions,
            spacing: adapter.spacing,
            pixelFormat: adapter.pixelFormat,
            intensityRange: adapter.intensityRange,
            orientation: adapter.orientation,
            recommendedWindow: adapter.recommendedWindow
        )
    }

    private func assertDataset(_ dataset: VolumeDataset,
                               matches voxels: Data,
                               dimensions: VolumetricDimensions,
                               spacing: VolumetricSpacing,
                               pixelFormat: VolumetricPixelFormat,
                               intensityRange: ClosedRange<Int32>,
                               orientation: VolumetricOrientation,
                               recommendedWindow: ClosedRange<Int32>?,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertEqual(dataset.data, voxels, file: file, line: line)
        XCTAssertEqual(
            dataset.dimensions,
            VolumeDimensions(width: dimensions.width, height: dimensions.height, depth: dimensions.depth),
            file: file,
            line: line
        )
        XCTAssertEqual(
            dataset.spacing,
            VolumeSpacing(x: spacing.x, y: spacing.y, z: spacing.z),
            file: file,
            line: line
        )
        XCTAssertEqual(dataset.pixelFormat, pixelFormat.toVolumePixelFormat(), file: file, line: line)
        XCTAssertEqual(dataset.intensityRange, intensityRange, file: file, line: line)
        XCTAssertEqual(dataset.recommendedWindow, recommendedWindow, file: file, line: line)
        XCTAssertEqual(
            dataset.orientation,
            VolumeOrientation(row: orientation.row, column: orientation.column, origin: orientation.origin),
            file: file,
            line: line
        )
        XCTAssertEqual(dataset.imageData.origin, orientation.origin, file: file, line: line)
        XCTAssertEqual(dataset.imageData.rowDirection, orientation.row, file: file, line: line)
        XCTAssertEqual(dataset.imageData.columnDirection, orientation.column, file: file, line: line)
        XCTAssertEqual(
            dataset.imageData.sliceDirection,
            simd_normalize(simd_cross(orientation.row, orientation.column)),
            file: file,
            line: line
        )
    }
}

private struct AppSideVolumeInput: VolumetricSeriesDataProvider {
    let voxels: Data
    let dimensions: VolumetricDimensions
    let spacing: VolumetricSpacing
    let pixelFormat: VolumetricPixelFormat
    let intensityRange: ClosedRange<Int32>
    let orientation: VolumetricOrientation
    let recommendedWindow: ClosedRange<Int32>?
}

private func voxelData(_ values: [Int16]) -> Data {
    values.withUnsafeBytes { Data($0) }
}
