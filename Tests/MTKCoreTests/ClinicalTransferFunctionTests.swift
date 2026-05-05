import Metal
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
