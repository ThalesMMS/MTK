import DicomCore
import Foundation
import MTKUI

public struct DicomClinicalObjectImportResult {
    public let sourceURL: URL
    public let objects: [ClinicalNonImageObjectDisplayItem]

    public init(sourceURL: URL, objects: [ClinicalNonImageObjectDisplayItem]) {
        self.sourceURL = sourceURL
        self.objects = objects
    }
}

public enum DicomClinicalObjectImportError: Error, LocalizedError, Sendable, Equatable {
    case noSupportedObjects

    public var errorDescription: String? {
        switch self {
        case .noSupportedObjects:
            return "No supported DICOM document, waveform, or video objects were found."
        }
    }
}

public protocol DicomClinicalObjectImporting: AnyObject {
    func loadObjects(from url: URL,
                     completion: @escaping (Result<DicomClinicalObjectImportResult, Error>) -> Void)
}

public final class DicomClinicalObjectImporter: DicomClinicalObjectImporting {
    private let callbackQueue: DispatchQueue
    private let fileManager: FileManager

    public init(callbackQueue: DispatchQueue = .main,
                fileManager: FileManager = .default) {
        self.callbackQueue = callbackQueue
        self.fileManager = fileManager
    }

    public func loadObjects(from url: URL,
                            completion: @escaping (Result<DicomClinicalObjectImportResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let objects = try self.loadObjectsSynchronously(from: url)
                guard !objects.isEmpty else {
                    throw DicomClinicalObjectImportError.noSupportedObjects
                }
                self.callbackQueue.async {
                    completion(.success(DicomClinicalObjectImportResult(sourceURL: url, objects: objects)))
                }
            } catch {
                self.callbackQueue.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func loadObjectsSynchronously(from url: URL) throws -> [ClinicalNonImageObjectDisplayItem] {
        try candidateDICOMFiles(from: url).compactMap { fileURL in
            guard let decoder = try? DCMDecoder(contentsOf: fileURL) else { return nil }
            if let document = decoder.encapsulatedDocument {
                return DicomClinicalObjectDisplayBridge.makeItem(from: document, sourceURL: fileURL)
            }
            if let waveform = decoder.waveform {
                return DicomClinicalObjectDisplayBridge.makeItem(from: waveform, sourceURL: fileURL)
            }
            if let video = decoder.video {
                let streamURL = try? writeTemporaryVideoStream(video, sourceURL: fileURL)
                return DicomClinicalObjectDisplayBridge.makeItem(
                    from: video,
                    streamURL: streamURL,
                    sourceURL: fileURL
                )
            }
            return nil
        }
    }

    private func candidateDICOMFiles(from url: URL) throws -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            return try candidateDICOMFiles(in: url)
        }
        if values?.isRegularFile == true || url.isFileURL {
            return [url]
        }
        return []
    }

    private func candidateDICOMFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            guard resourceValues.isRegularFile == true else { continue }
            if fileURL.pathExtension.lowercased() == "dcm" || fileURL.pathExtension.isEmpty {
                urls.append(fileURL)
            }
        }
        return urls.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func writeTemporaryVideoStream(_ video: DicomVideo, sourceURL: URL) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("mtk-dicom-video", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = [
            sourceURL.deletingPathExtension().lastPathComponent,
            video.sopInstanceUID ?? UUID().uuidString
        ]
            .map(safePathComponent)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let exportName = filename.isEmpty ? UUID().uuidString : filename
        let url = directory
            .appendingPathComponent(exportName)
            .appendingPathExtension(preferredVideoExtension(for: video.codec))
        try video.streamData.write(to: url, options: [.atomic])
        return url
    }

    private func preferredVideoExtension(for codec: DicomVideoCodec) -> String {
        switch codec {
        case .mpeg2:
            return "mpg"
        case .h264:
            return "h264"
        case .hevc:
            return "h265"
        case .unknown:
            return "bin"
        }
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
