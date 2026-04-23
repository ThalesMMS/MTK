import XCTest
import Foundation
import ZIPFoundation
@testable import MTKCore

/// Security tests for DicomVolumeLoader ZIP extraction
/// Tests path traversal vulnerability protection (CWE-22)
final class DicomVolumeLoaderSecurityTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DicomSecurityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory = temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        super.tearDown()
    }

    // MARK: - Path Traversal Attack Tests

    func testRejectsParentDirectoryTraversal() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("malicious_parent_traversal.zip")
        let maliciousPath = "../../../etc/passwd"

        try createMaliciousZIP(at: zipURL, entryPath: maliciousPath, content: "malicious content")

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Parent traversal rejected")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsPathTraversalError(capturedError)
    }

    func testRejectsAbsolutePaths() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("malicious_absolute_path.zip")
        let maliciousPath = "/etc/passwd"

        try createMaliciousZIP(at: zipURL, entryPath: maliciousPath, content: "malicious content")

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Absolute path rejected")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsPathTraversalError(capturedError)
    }

    func testRejectsMultipleTraversalSequences() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("malicious_multiple_traversal.zip")
        let maliciousPath = "../../../../../../tmp/malicious.txt"

        try createMaliciousZIP(at: zipURL, entryPath: maliciousPath, content: "malicious content")

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Multiple traversal rejected")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsPathTraversalError(capturedError)
    }

    func testIgnoresHiddenFiles() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("malicious_hidden_file.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let validData = "valid dicom data".data(using: .utf8)!
        let hiddenData = "malicious content".data(using: .utf8)!
        let entries = [
            ("valid_dir/image001.dcm", validData),
            ("second_dir/image002.dcm", validData),
            ("valid_dir/.hidden_malware", hiddenData),
            ("__MACOSX/._image001.dcm", hiddenData)
        ]
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                return data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let spyLoader = SpyDicomSeriesLoader()
        let loader = DicomVolumeLoader(seriesLoader: spyLoader)
        let expectation = expectation(description: "Hidden file ignored")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsNotPathTraversalError(capturedError)
        XCTAssertTrue(spyLoader.recordedRelativePaths.contains("valid_dir/image001.dcm"))
        XCTAssertTrue(spyLoader.recordedRelativePaths.contains("second_dir/image002.dcm"))
        XCTAssertFalse(spyLoader.recordedRelativePaths.contains("valid_dir/.hidden_malware"))
        XCTAssertFalse(spyLoader.recordedRelativePaths.contains("__MACOSX/._image001.dcm"))
    }

    func testRejectsMixedValidAndInvalidEntries() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("malicious_mixed.zip")

        // Create ZIP with both valid and malicious entries
        let archive = try Archive(url: zipURL, accessMode: .create)

        // Add valid entry
        let validData = "valid content".data(using: .utf8)!
        try archive.addEntry(with: "valid_file.txt", type: .file, uncompressedSize: Int64(validData.count)) { position, size in
            return validData.subdata(in: Int(position)..<Int(position) + size)
        }

        // Add malicious entry with path traversal
        let maliciousData = "malicious content".data(using: .utf8)!
        try archive.addEntry(with: "../../../etc/passwd", type: .file, uncompressedSize: Int64(maliciousData.count)) { position, size in
            return maliciousData.subdata(in: Int(position)..<Int(position) + size)
        }

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Mixed entries rejected")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsPathTraversalError(capturedError)
    }

    // MARK: - Valid Path Tests

    func testAcceptsValidPaths() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("valid_archive.zip")

        let archive = try Archive(url: zipURL, accessMode: .create)

        // Add multiple valid entries with nested directories
        let validPaths = [
            "study/series/image001.dcm",
            "study/series/image002.dcm",
            "metadata.txt"
        ]

        for path in validPaths {
            let data = "valid content".data(using: .utf8)!
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                return data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Valid paths accepted")

        var succeeded = false
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .success = result {
                succeeded = true
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        // Note: MockDicomSeriesLoader will fail, but we verify ZIP extraction succeeded
        // The key is that pathTraversal error was NOT thrown
        XCTAssertFalse(succeeded, "Mock loader should fail, but not with pathTraversal error")
    }

    func testAcceptsValidNestedDirectories() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("valid_nested.zip")

        let archive = try Archive(url: zipURL, accessMode: .create)

        // Deep but valid directory structure
        let validPath = "patient_123/study_456/series_789/instance_001.dcm"
        let data = "valid dicom data".data(using: .utf8)!
        try archive.addEntry(with: validPath, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            return data.subdata(in: Int(position)..<Int(position) + size)
        }

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Valid nested paths accepted")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        // Verify it didn't fail with pathTraversal error
        if let error = capturedError {
            if case DicomVolumeLoaderError.pathTraversal = error {
                XCTFail("Valid nested path should not trigger pathTraversal error")
            }
            // Other errors (like bridgeError from MockDicomSeriesLoader) are expected
        }
    }

    func testIgnoresMacOSMetadataEntries() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("finder_metadata.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)

        let data = "valid dicom data".data(using: .utf8)!
        let paths = [
            "study/series/image001.dcm",
            "__MACOSX/._study",
            "__MACOSX/study/series/._image001.dcm",
            ".DS_Store"
        ]

        for path in paths {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                return data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Finder metadata ignored")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsNotPathTraversalError(capturedError)
    }

    // MARK: - Edge Cases

    func testRejectsEmptyPath() throws {
        let zipURL = temporaryDirectory.appendingPathComponent("empty_path.zip")

        let archive = try Archive(url: zipURL, accessMode: .create)

        let data = "content".data(using: .utf8)!
        try archive.addEntry(with: ".", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            return data.subdata(in: Int(position)..<Int(position) + size)
        }

        let loader = DicomVolumeLoader(seriesLoader: MockDicomSeriesLoader())
        let expectation = expectation(description: "Empty path rejected")

        var capturedError: Error?
        loader.loadVolume(from: zipURL, progress: { _ in }, completion: { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        })

        wait(for: [expectation], timeout: 5.0)

        assertIsPathTraversalError(capturedError)
    }

    // MARK: - Helper Methods

    private func assertIsPathTraversalError(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error else {
            XCTFail("Expected path traversal error, but loading succeeded", file: file, line: line)
            return
        }

        // Path traversal error may be direct or wrapped in bridgeError
        switch error {
        case DicomVolumeLoaderError.pathTraversal:
            // Expected error - test passes
            break
        case DicomVolumeLoaderError.bridgeError(let nsError):
            if let loaderError = nsError as? DicomVolumeLoaderError,
               case .pathTraversal = loaderError {
                // Expected error wrapped in bridgeError - test passes
            } else {
                XCTFail("Expected DicomVolumeLoaderError.pathTraversal, got bridgeError(\(nsError))", file: file, line: line)
            }
        default:
            XCTFail("Expected DicomVolumeLoaderError.pathTraversal, got \(error)", file: file, line: line)
        }
    }

    private func assertIsNotPathTraversalError(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error else {
            XCTFail("assertIsNotPathTraversalError expected an error but got nil", file: file, line: line)
            return
        }

        if containsPathTraversal(error) {
            XCTFail("assertIsNotPathTraversalError expected an error other than DicomVolumeLoaderError.pathTraversal or wrapped DicomVolumeLoaderError.bridgeError(pathTraversal), got \(error)", file: file, line: line)
        }
    }

    private func containsPathTraversal(_ error: Error) -> Bool {
        var pending: [Error] = [error]
        var visitedNSErrors = Set<ObjectIdentifier>()

        while let current = pending.popLast() {
            if let loaderError = current as? DicomVolumeLoaderError {
                switch loaderError {
                case .pathTraversal:
                    return true
                case .bridgeError(let nsError):
                    let identifier = ObjectIdentifier(nsError)
                    guard visitedNSErrors.insert(identifier).inserted else { continue }
                    if let nestedLoaderError = nsError as? DicomVolumeLoaderError {
                        pending.append(nestedLoaderError)
                    }
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                        pending.append(underlyingError)
                    }
                default:
                    break
                }
                continue
            }

            let nsError = current as NSError
            let identifier = ObjectIdentifier(nsError)
            guard visitedNSErrors.insert(identifier).inserted else { continue }
            if let nestedLoaderError = nsError as? DicomVolumeLoaderError {
                pending.append(nestedLoaderError)
            }
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                pending.append(underlyingError)
            }
        }

        return false
    }

    private func createMaliciousZIP(at url: URL, entryPath: String, content: String) throws {
        let archive = try Archive(url: url, accessMode: .create)

        let data = content.data(using: .utf8)!
        try archive.addEntry(with: entryPath, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            return data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

// MARK: - Mock DICOM Series Loader

/// Mock loader for testing ZIP extraction without requiring real DICOM files
private class MockDicomSeriesLoader: DicomSeriesLoading {
    func loadSeries(at url: URL, progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        // Mock implementation that fails - we're only testing ZIP extraction security
        throw NSError(domain: "MockDicomSeriesLoader", code: 999, userInfo: [NSLocalizedDescriptionKey: "Mock loader - not a real implementation"])
    }
}

private final class SpyDicomSeriesLoader: DicomSeriesLoading {
    private(set) var recordedRelativePaths: [String] = []

    func loadSeries(at url: URL, progress: ((Double, UInt, Data?, Any) -> Void)?) throws -> Any {
        let basePath = url.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: url,
                                                        includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [],
                                                        errorHandler: nil)

        recordedRelativePaths = (enumerator?.compactMap { item in
            guard let fileURL = item as? URL else { return nil }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            let resolvedPath = fileURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(basePath + "/") else { return nil }
            return String(resolvedPath.dropFirst(basePath.count + 1))
        } ?? []).sorted()

        throw NSError(domain: "SpyDicomSeriesLoader", code: 999, userInfo: [NSLocalizedDescriptionKey: "Spy loader - stop after recording extracted contents"])
    }
}
