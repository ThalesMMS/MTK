import XCTest

final class MPRPresentationPassSourceTests: XCTestCase {
    func test_sourceDoesNotUseReadbackOrCGImage() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKCore/Rendering/MPRPresentationPass.swift"))

        assertSourceDoesNotUseReadbackOrCGImage(source)
    }
}
