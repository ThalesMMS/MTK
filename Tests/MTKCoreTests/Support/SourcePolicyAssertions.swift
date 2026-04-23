import XCTest

func assertSourceDoesNotUseReadbackOrCGImage(_ source: String,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
    XCTAssertFalse(source.contains("getBytes("), file: file, line: line)
    XCTAssertFalse(source.contains("contents("), file: file, line: line)
    XCTAssertFalse(source.contains("MTLBuffer.contents"), file: file, line: line)
    XCTAssertFalse(source.contains("buffer.contents"), file: file, line: line)
    XCTAssertFalse(source.contains("CGImage"), file: file, line: line)
    XCTAssertFalse(source.contains("TextureSnapshotExporter"), file: file, line: line)
}
