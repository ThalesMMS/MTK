import Metal
import simd
import XCTest
@testable import MTKCore

final class ClinicalTransferFunctionTests: XCTestCase {
    func test_existingBuiltinPresetsRoundTripThroughVersionedJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for preset in VolumeRenderingBuiltinPreset.allCases {
            let transferFunction = try XCTUnwrap(
                VolumeTransferFunctionLibrary.transferFunction(for: preset),
                "Expected builtin preset \(preset.rawValue) to load"
            )

            let data = try encoder.encode(transferFunction)
            let decoded = try decoder.decode(TransferFunction.self, from: data)

            XCTAssertEqual(decoded.version, TransferFunction.currentVersion)
            XCTAssertEqual(decoded.name, transferFunction.name)
            XCTAssertEqual(decoded.minimumValue, transferFunction.minimumValue, accuracy: 1e-5)
            XCTAssertEqual(decoded.maximumValue, transferFunction.maximumValue, accuracy: 1e-5)
            XCTAssertEqual(decoded.shift, transferFunction.shift, accuracy: 1e-5)
            XCTAssertEqual(decoded.colourPoints.count, transferFunction.colourPoints.count)
            XCTAssertEqual(decoded.alphaPoints.count, transferFunction.alphaPoints.count)
        }
    }

    func test_clinicalPresetCatalogRoundTripsWithMetadataAndRenderingIntent() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for preset in ClinicalTransferFunctionPreset.allCases {
            let transferFunction = try preset.loadTransferFunction()
            let data = try encoder.encode(transferFunction)
            let decoded = try decoder.decode(TransferFunction.self, from: data)

            XCTAssertEqual(decoded.version, TransferFunction.currentVersion)
            XCTAssertEqual(decoded.metadata, preset.metadata)
            XCTAssertEqual(decoded.renderingIntent, preset.renderingIntent)
            XCTAssertEqual(decoded.gradientOpacity, preset.gradientOpacity)
            XCTAssertEqual(decoded.colourPoints.count, transferFunction.colourPoints.count)
            XCTAssertEqual(decoded.alphaPoints.count, transferFunction.alphaPoints.count)
        }
    }

    func testClinicalCTPresetsUseExactHounsfieldCurves() throws {
        try assertClinicalCTPreset(
            .ctSoftTissue,
            expectedName: "CT-Soft-Tissue",
            points: [
                .init(hu: -1000, color: .init(0, 0, 0), opacity: 0),
                .init(hu: -300, color: .init(0.45, 0.22, 0.16), opacity: 0),
                .init(hu: -150, color: .init(0.45, 0.22, 0.16), opacity: 0.02),
                .init(hu: 40, color: .init(0.85, 0.52, 0.42), opacity: 0.18),
                .init(hu: 300, color: .init(1.0, 0.82, 0.68), opacity: 0.35),
                .init(hu: 1200, color: .init(1.0, 0.95, 0.88), opacity: 0.45)
            ]
        )
        try assertClinicalCTPreset(
            .ctBone,
            expectedName: "CT-Bone",
            points: [
                .init(hu: -1000, color: .init(0, 0, 0), opacity: 0),
                .init(hu: 150, color: .init(0.35, 0.18, 0.12), opacity: 0),
                .init(hu: 300, color: .init(0.72, 0.48, 0.38), opacity: 0.2),
                .init(hu: 700, color: .init(0.92, 0.82, 0.72), opacity: 0.65),
                .init(hu: 1800, color: .init(1.0, 0.98, 0.92), opacity: 0.95)
            ]
        )
        try assertClinicalCTPreset(
            .ctLung,
            expectedName: "CT-Lung",
            points: [
                .init(hu: -1000, color: .init(0, 0, 0), opacity: 0),
                .init(hu: -850, color: .init(0.55, 0.7, 0.95), opacity: 0.05),
                .init(hu: -600, color: .init(0.9, 0.55, 0.45), opacity: 0.18),
                .init(hu: -200, color: .init(0.95, 0.75, 0.62), opacity: 0.08),
                .init(hu: 350, color: .init(1.0, 0.96, 0.88), opacity: 0.4)
            ]
        )
        try assertClinicalCTPreset(
            .ctBrain,
            expectedName: "CT-Brain",
            points: [
                .init(hu: -1000, color: .init(0, 0, 0), opacity: 0),
                .init(hu: 0, color: .init(0.18, 0.12, 0.1), opacity: 0),
                .init(hu: 25, color: .init(0.7, 0.52, 0.46), opacity: 0.12),
                .init(hu: 55, color: .init(0.9, 0.72, 0.62), opacity: 0.24),
                .init(hu: 90, color: .init(1.0, 0.88, 0.78), opacity: 0.28),
                .init(hu: 600, color: .init(1.0, 0.96, 0.88), opacity: 0.45)
            ]
        )
        try assertClinicalCTPreset(
            .ctAbdomen,
            expectedName: "CT-Abdomen",
            points: [
                .init(hu: -1000, color: .init(0, 0, 0), opacity: 0),
                .init(hu: -150, color: .init(0.38, 0.16, 0.12), opacity: 0),
                .init(hu: 20, color: .init(0.75, 0.42, 0.32), opacity: 0.12),
                .init(hu: 80, color: .init(0.95, 0.65, 0.5), opacity: 0.22),
                .init(hu: 250, color: .init(1.0, 0.82, 0.68), opacity: 0.34),
                .init(hu: 1000, color: .init(1.0, 0.95, 0.88), opacity: 0.5)
            ]
        )
    }

    func test_ctBrainAndAbdomenClinicalMetadataAndIntent() throws {
        XCTAssertEqual(ClinicalTransferFunctionPreset.ctBrain.metadata.modality, .ct)
        XCTAssertEqual(ClinicalTransferFunctionPreset.ctBrain.metadata.tissue, .neurological)
        XCTAssertEqual(ClinicalTransferFunctionPreset.ctBrain.renderingIntent,
                       TransferFunctionRenderingIntent(mode: .dvr,
                                                       lightingEnabled: true,
                                                       projectionsUseTransferFunction: true))

        XCTAssertEqual(ClinicalTransferFunctionPreset.ctAbdomen.metadata.modality, .ct)
        XCTAssertEqual(ClinicalTransferFunctionPreset.ctAbdomen.metadata.tissue, .softTissue)
        XCTAssertEqual(ClinicalTransferFunctionPreset.ctAbdomen.renderingIntent,
                       TransferFunctionRenderingIntent(mode: .dvr,
                                                       lightingEnabled: true,
                                                       projectionsUseTransferFunction: true))

        XCTAssertEqual(try ClinicalTransferFunctionPreset.ctBrain.loadTransferFunction().metadata,
                       ClinicalTransferFunctionPreset.ctBrain.metadata)
        XCTAssertEqual(try ClinicalTransferFunctionPreset.ctAbdomen.loadTransferFunction().metadata,
                       ClinicalTransferFunctionPreset.ctAbdomen.metadata)
    }

    func test_falconParityCTPresetsUseGradientOpacity() throws {
        let expected = try XCTUnwrap(ClinicalTransferFunctionPreset.ctVRBone.gradientOpacity)

        XCTAssertEqual(expected.maximumGradient, 100)
        XCTAssertEqual(try XCTUnwrap(expected.opacity(at: 0)), 0.0, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(expected.opacity(at: 20)), 0.2, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(expected.opacity(at: 100)), 1.0, accuracy: 1e-5)

        for preset in [ClinicalTransferFunctionPreset.ctBrain, .ctBone, .ctSoftTissue] {
            XCTAssertEqual(preset.gradientOpacity, expected, "Expected \(preset) to reuse the CT surface gradient opacity curve")
            XCTAssertEqual(try preset.loadTransferFunction().gradientOpacity, expected)
        }
    }

    @MainActor
    func testClinicalCTPresetTextureCreationUsesClampedAlphaPoints() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable for transfer texture validation.")
        }

        for preset in clinicalCTPresets {
            let transferFunction = try XCTUnwrap(VolumeTransferFunctionLibrary.transferFunction(for: preset))
            let texture = try XCTUnwrap(TransferFunctions.texture(for: transferFunction, device: device))

            XCTAssertGreaterThan(texture.width, 0, "Expected \(preset.rawValue) to create a non-empty transfer texture")
            XCTAssertGreaterThan(texture.height, 0, "Expected \(preset.rawValue) to create a non-empty transfer texture")
            for point in transferFunction.sanitizedAlphaPoints() {
                XCTAssertTrue(point.alphaValue.isFinite, "Expected finite alpha for \(preset.rawValue)")
                XCTAssertGreaterThanOrEqual(point.alphaValue, 0, "Expected clamped alpha lower bound for \(preset.rawValue)")
                XCTAssertLessThanOrEqual(point.alphaValue, 1, "Expected clamped alpha upper bound for \(preset.rawValue)")
            }
        }
    }

    func test_customGradientOpacityPresetRoundTripPreservesPublicContract() throws {
        var transferFunction = TransferFunction()
        transferFunction.name = "Custom Gradient Bone"
        transferFunction.minimumValue = -1024
        transferFunction.maximumValue = 3071
        transferFunction.metadata = TransferFunctionMetadata(
            identifier: "custom.gradient.bone",
            displayName: "Custom Gradient Bone",
            modality: .ct,
            tissue: .bone,
            clinicalUse: "Custom user-authored bone transfer function",
            source: "unit-test",
            tags: ["custom", "bone"]
        )
        transferFunction.renderingIntent = TransferFunctionRenderingIntent(mode: .dvr,
                                                                           lightingEnabled: true,
                                                                           projectionsUseTransferFunction: true)
        transferFunction.colourPoints = [
            .init(dataValue: -1024, colourValue: .init(r: 0, g: 0, b: 0, a: 1)),
            .init(dataValue: 300, colourValue: .init(r: 0.8, g: 0.7, b: 0.55, a: 1)),
            .init(dataValue: 3071, colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        transferFunction.alphaPoints = [
            .init(dataValue: -1024, alphaValue: 0),
            .init(dataValue: 300, alphaValue: 0.2),
            .init(dataValue: 3071, alphaValue: 0.9)
        ]
        transferFunction.gradientOpacity = GradientOpacityFunction(
            minimumGradient: 0,
            maximumGradient: 900,
            points: [
                .init(gradientMagnitude: 0, opacity: 0.25),
                .init(gradientMagnitude: 200, opacity: 0.7),
                .init(gradientMagnitude: 900, opacity: 1.0)
            ],
            resolution: 128
        )

        let data = try JSONEncoder().encode(transferFunction)
        let decoded = try JSONDecoder().decode(TransferFunction.self, from: data)

        XCTAssertEqual(decoded, transferFunction)
        XCTAssertEqual(try XCTUnwrap(decoded.gradientOpacity?.opacity(at: 0)), 0.25, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(decoded.gradientOpacity?.opacity(at: 900)), 1.0, accuracy: 1e-5)
    }

    func test_volumeTransferFunctionConversionPreservesGradientOpacity() throws {
        let transferFunction = try ClinicalTransferFunctionPreset.ctVRBone.loadTransferFunction()
        let converted = transferFunction.volumeTransferFunction()

        XCTAssertEqual(converted.gradientOpacity, transferFunction.gradientOpacity)
        XCTAssertEqual(converted.colourPoints.count, transferFunction.sanitizedColourPoints().count)
        XCTAssertEqual(converted.opacityPoints.count, transferFunction.sanitizedAlphaPoints().count)
    }

    @MainActor
    func test_transferTextureUses2DHeightOnlyWhenGradientOpacityIsPresent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable for transfer texture validation.")
        }

        let legacy = try XCTUnwrap(VolumeTransferFunctionLibrary.transferFunction(for: .ctBone))
        let legacyTexture = try XCTUnwrap(TransferFunctions.texture(for: legacy, device: device))
        XCTAssertEqual(legacyTexture.height, 1)

        let gradientAware = try ClinicalTransferFunctionPreset.ctVRBone.loadTransferFunction()
        let gradientTexture = try XCTUnwrap(TransferFunctions.texture(for: gradientAware, device: device))
        XCTAssertEqual(gradientTexture.height, gradientAware.gradientOpacity?.resolution)
    }
}

private extension ClinicalTransferFunctionTests {
    var clinicalCTPresets: [VolumeRenderingBuiltinPreset] {
        [.ctSoftTissue, .ctBone, .ctLung, .ctBrain, .ctAbdomen]
    }

    struct ExpectedTransferPoint {
        let hu: Float
        let color: SIMD3<Float>
        let opacity: Float
    }

    func assertClinicalCTPreset(_ preset: VolumeRenderingBuiltinPreset,
                                expectedName: String,
                                points: [ExpectedTransferPoint],
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let transferFunction = try XCTUnwrap(
            VolumeTransferFunctionLibrary.transferFunction(for: preset),
            "Expected \(preset.rawValue) to load",
            file: file,
            line: line
        )

        XCTAssertEqual(transferFunction.name, expectedName, file: file, line: line)
        XCTAssertEqual(transferFunction.minimumValue, -1200, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(transferFunction.maximumValue, 3000, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(transferFunction.shift, 0, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(transferFunction.colourPoints.count, points.count, file: file, line: line)
        XCTAssertEqual(transferFunction.alphaPoints.count, points.count, file: file, line: line)

        for (index, point) in points.enumerated() {
            let colourPoint = transferFunction.colourPoints[index]
            let alphaPoint = transferFunction.alphaPoints[index]
            XCTAssertEqual(colourPoint.dataValue, point.hu, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(colourPoint.colourValue.r, point.color.x, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(colourPoint.colourValue.g, point.color.y, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(colourPoint.colourValue.b, point.color.z, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(colourPoint.colourValue.a, 1, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(alphaPoint.dataValue, point.hu, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(alphaPoint.alphaValue, point.opacity, accuracy: 0.0001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(alphaPoint.alphaValue, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(alphaPoint.alphaValue, 1, file: file, line: line)
        }
    }
}
