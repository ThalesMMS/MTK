import Metal
import XCTest

@_spi(Testing) @testable import MTKCore

final class TransferFunctionTextureCacheBoundsTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        TransferFunctions.debugResetTextureCaches()
    }

    @MainActor
    func test_transferFunctionCache_shiftDrag_remainsBounded() throws {
        let device = try requireDevice()
        let capacity = TransferFunctions.debugTextureCacheCapacity

        for index in 0..<(capacity * 4) {
            let transfer = makeTransferFunction(shift: Float(index) * 0.125)
            XCTAssertNotNil(TransferFunctions.texture(for: transfer,
                                                       device: device,
                                                       options: smallOptions))
        }

        XCTAssertEqual(TransferFunctions.debugTextureCacheEntryCount, capacity)
    }

    @MainActor
    func test_transferFunctionCache_cacheHit_refreshesLRURecency() throws {
        let device = try requireDevice()
        let capacity = TransferFunctions.debugTextureCacheCapacity
        let hotTransfer = makeTransferFunction(shift: 0)
        let hotTexture = try XCTUnwrap(TransferFunctions.texture(for: hotTransfer,
                                                                 device: device,
                                                                 options: smallOptions))
        for index in 1..<capacity {
            XCTAssertNotNil(TransferFunctions.texture(for: makeTransferFunction(shift: Float(index)),
                                                       device: device,
                                                       options: smallOptions))
        }

        let cacheHit = try XCTUnwrap(TransferFunctions.texture(for: hotTransfer,
                                                               device: device,
                                                               options: smallOptions))
        XCTAssertTrue(hotTexture as AnyObject === cacheHit as AnyObject)
        XCTAssertNotNil(TransferFunctions.texture(for: makeTransferFunction(shift: Float(capacity)),
                                                   device: device,
                                                   options: smallOptions))
        let reused = try XCTUnwrap(TransferFunctions.texture(for: hotTransfer,
                                                             device: device,
                                                             options: smallOptions))

        XCTAssertTrue(hotTexture as AnyObject === reused as AnyObject)
        XCTAssertEqual(TransferFunctions.debugTextureCacheEntryCount, capacity)
    }

    @MainActor
    func test_transferFunction2DCache_shiftDrag_remainsBounded() throws {
        let device = try requireDevice()
        let capacity = TransferFunctions.debugTextureCacheCapacity

        for index in 0..<(capacity * 2) {
            let transfer = makeTransferFunction2D(shift: Float(index) * 0.125)
            XCTAssertNotNil(TransferFunctions.texture(for: transfer,
                                                       device: device,
                                                       options: smallOptions))
        }

        XCTAssertEqual(TransferFunctions.debugTexture2DCacheEntryCount, capacity)
    }

    func test_transferFunctionCache_concurrentMisses_convergeOnOneTexture() async throws {
        let device = try requireDevice()
        let transfer = makeTransferFunction(shift: 0.375)
        let options = smallOptions
        let identifiers = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    TransferFunctions.texture(for: transfer,
                                              device: device,
                                              options: options).map {
                        ObjectIdentifier($0 as AnyObject)
                    }
                }
            }
            var identifiers: [ObjectIdentifier] = []
            for await identifier in group {
                if let identifier {
                    identifiers.append(identifier)
                }
            }
            return identifiers
        }

        XCTAssertEqual(identifiers.count, 16)
        XCTAssertEqual(Set(identifiers).count, 1)
        let entryCount = await TransferFunctions.debugTextureCacheEntryCount
        XCTAssertEqual(entryCount, 1)
    }

    private var smallOptions: TransferFunctions.TextureOptions {
        TransferFunctions.TextureOptions(resolution: 4, gradientResolution: 4)
    }

    private func requireDevice() throws -> any MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    private func makeTransferFunction(shift: Float) -> TransferFunction {
        var transfer = TransferFunction()
        transfer.name = "LRU gradient fixture"
        transfer.minimumValue = 0
        transfer.maximumValue = 1
        transfer.shift = shift
        transfer.colorSpace = .linear
        transfer.colourPoints = [
            .init(dataValue: 0, colourValue: .init(r: 0, g: 0, b: 0, a: 1)),
            .init(dataValue: 1, colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        transfer.alphaPoints = [
            .init(dataValue: 0, alphaValue: 0),
            .init(dataValue: 1, alphaValue: 1)
        ]
        transfer.gradientOpacity = GradientOpacityFunction(
            minimumGradient: 0,
            maximumGradient: 1,
            points: [
                .init(gradientMagnitude: 0, opacity: 0),
                .init(gradientMagnitude: 1, opacity: 1)
            ],
            resolution: 4
        )
        return transfer
    }

    private func makeTransferFunction2D(shift: Float) -> TransferFunction2D {
        var transfer = TransferFunction2D()
        transfer.name = "LRU 2D fixture"
        transfer.minimumIntensity = 0
        transfer.maximumIntensity = 1
        transfer.minimumGradient = 0
        transfer.maximumGradient = 1
        transfer.shift = shift
        transfer.colorSpace = .linear
        transfer.colourPoints = [
            .init(intensity: 0,
                  gradientMagnitude: 0,
                  colourValue: .init(r: 0, g: 0, b: 0, a: 1)),
            .init(intensity: 1,
                  gradientMagnitude: 1,
                  colourValue: .init(r: 1, g: 1, b: 1, a: 1))
        ]
        transfer.alphaPoints = [
            .init(intensity: 0, gradientMagnitude: 0, alphaValue: 0),
            .init(intensity: 1, gradientMagnitude: 1, alphaValue: 1)
        ]
        return transfer
    }
}
