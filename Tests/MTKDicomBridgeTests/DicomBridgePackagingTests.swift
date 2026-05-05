import XCTest

import MTKCore
@testable import MTKDicomBridge

final class DicomBridgePackagingTests: XCTestCase {
    func testBridgeProvidesDefaultDecoderBackedLoaderWithoutChangingCoreInitializer() {
        let bridgeLoader: any DicomSeriesLoading = DicomDecoderSeriesLoader()
        let volumeLoader = DicomVolumeLoader()

        XCTAssertEqual(String(describing: type(of: bridgeLoader)), "DicomDecoderSeriesLoader")
        _ = volumeLoader
    }
}
