import MTKCore
import XCTest

final class TransferFunctionOpacityScaleTests: XCTestCase {
    func testApplyingOpacityScaleClampsAlphaPoints() {
        var transfer = TransferFunction()
        transfer.alphaPoints = [
            .init(dataValue: -100, alphaValue: 0.2),
            .init(dataValue: 0, alphaValue: 0.8),
            .init(dataValue: 100, alphaValue: 1.0)
        ]

        let scaled = transfer.applyingOpacityScale(1.5)

        XCTAssertEqual(scaled.alphaPoints.map(\.dataValue), [-100, 0, 100])
        XCTAssertEqual(scaled.alphaPoints.map(\.alphaValue), [0.3, 1.0, 1.0])
        XCTAssertEqual(transfer.alphaPoints.map(\.alphaValue), [0.2, 0.8, 1.0])
    }

    func testApplyingOpacityScaleUsesIdentityForNonFiniteScale() {
        var transfer = TransferFunction()
        transfer.alphaPoints = [.init(dataValue: 0, alphaValue: 0.5)]

        XCTAssertEqual(transfer.applyingOpacityScale(.nan).alphaPoints.first?.alphaValue, 0.5)
    }
}
