import XCTest
import MTKCore
@_spi(Testing) @testable import MTKUI

@MainActor
protocol RenderQualityProviding: AnyObject {
    var renderQualityState: RenderQualityState { get }
}

extension ClinicalViewportGridController: RenderQualityProviding {}
extension VolumeViewportController: RenderQualityProviding {}

@MainActor
func waitForRenderQuality(_ state: RenderQualityState,
                          controller: any RenderQualityProviding,
                          file: StaticString = #filePath,
                          line: UInt = #line) async throws {
    for _ in 0..<80 {
        if controller.renderQualityState == state {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(controller.renderQualityState, state, file: file, line: line)
}
