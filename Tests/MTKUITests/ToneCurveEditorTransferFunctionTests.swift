import simd
import XCTest
@testable import MTKCore
@testable import MTKUI

final class ToneCurveEditorTransferFunctionTests: XCTestCase {
    func testTransferFunctionAdapterUpdatesPublicOpacityPoints() {
        var transferFunction = TransferFunction()
        transferFunction.minimumValue = -1024
        transferFunction.maximumValue = 3071
        transferFunction.alphaPoints = [
            .init(dataValue: -1024, alphaValue: 0),
            .init(dataValue: 3071, alphaValue: 1)
        ]

        ToneCurveEditorTransferFunctionAdapter.update(
            &transferFunction,
            normalizedControlPoints: [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(0.5, 0.4),
                SIMD2<Float>(1, 1)
            ]
        )

        XCTAssertEqual(transferFunction.alphaPoints.count, 3)
        XCTAssertEqual(transferFunction.alphaPoints[0].dataValue, -1024, accuracy: 1e-5)
        XCTAssertEqual(transferFunction.alphaPoints[1].dataValue, 1023.5, accuracy: 1e-5)
        XCTAssertEqual(transferFunction.alphaPoints[1].alphaValue, 0.4, accuracy: 1e-5)
        XCTAssertEqual(transferFunction.alphaPoints[2].dataValue, 3071, accuracy: 1e-5)
        XCTAssertEqual(transferFunction.version, TransferFunction.currentVersion)
    }

    func testTransferFunctionAdapterReadsOpacityPointsFromPublicModel() {
        var transferFunction = TransferFunction()
        transferFunction.minimumValue = 0
        transferFunction.maximumValue = 100
        transferFunction.alphaPoints = [
            .init(dataValue: 0, alphaValue: 0),
            .init(dataValue: 25, alphaValue: 0.2),
            .init(dataValue: 100, alphaValue: 0.8)
        ]

        let points = ToneCurveEditorTransferFunctionAdapter.normalizedControlPoints(for: transferFunction)

        XCTAssertEqual(points.map(\.x), [0, 0.25, 1])
        XCTAssertEqual(points.map(\.y), [0, 0.2, 0.8])
    }
}
