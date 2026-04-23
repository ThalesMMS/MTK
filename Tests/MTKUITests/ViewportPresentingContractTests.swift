import XCTest

/// Regression guard for the public MTKUI viewport presentation contract.
///
/// This protects the Metal-native surface API from drifting back toward
/// CPU-backed `CGImage` display methods.
final class ViewportPresentingContractTests: XCTestCase {
    func testViewportPresentingProtocolDoesNotAcceptCGImageParameters() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKUI/Common/ViewportPresenting.swift"))
        let protocolSource = try viewportPresentingProtocolSource(from: source)
        let cgImageParameterPattern = try NSRegularExpression(
            pattern: #"\bfunc\s+[A-Za-z0-9_]+\s*\([^)]*:\s*(?:CoreGraphics\.)?CGImage(?:\?|!)?"#
        )
        let range = NSRange(protocolSource.startIndex..<protocolSource.endIndex, in: protocolSource)

        XCTAssertFalse(
            cgImageParameterPattern.firstMatch(in: protocolSource, range: range) != nil,
            "Viewport presentation contract must remain Metal-native and must not accept CGImage parameters."
        )
    }

    func testViewportPresentingProtocolDoesNotExposeDisplayMethod() throws {
        let source = try String(contentsOfFile: sourceFilePath("Sources/MTKUI/Common/ViewportPresenting.swift"))
        let protocolSource = try viewportPresentingProtocolSource(from: source)
        let displayPattern = try NSRegularExpression(pattern: #"\bfunc\s+display\b"#)
        let range = NSRange(protocolSource.startIndex..<protocolSource.endIndex, in: protocolSource)

        XCTAssertFalse(
            displayPattern.firstMatch(in: protocolSource, range: range) != nil,
            "Viewport presentation contract must not expose generic display methods."
        )
    }
}

private extension ViewportPresentingContractTests {
    func sourceFilePath(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appendingPathComponent(relativePath).path
    }

    func viewportPresentingProtocolSource(from source: String) throws -> String {
        guard let start = source.range(of: "public protocol ViewportPresenting: AnyObject {"),
              let end = source[start.lowerBound...].range(of: "\n}") else {
            XCTFail("Failed to locate ViewportPresenting protocol source.")
            throw ContractExtractionError.protocolNotFound
        }

        return String(source[start.lowerBound..<end.upperBound])
    }
}

private enum ContractExtractionError: Error {
    case protocolNotFound
}
