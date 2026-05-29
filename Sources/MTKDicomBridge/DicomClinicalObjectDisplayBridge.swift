import DicomCore
import Foundation
import MTKUI

public enum DicomClinicalObjectDisplayBridge {
    public static func makeItem(from document: DicomEncapsulatedDocument,
                                sourceURL: URL? = nil) -> ClinicalNonImageObjectDisplayItem {
        let kind = ClinicalEncapsulatedDocumentKind(
            mimeType: document.mimeType,
            preferredFileExtension: document.preferredFileExtension
        )
        let title = ClinicalDisplayTextSanitizer.safeSeriesTitle(document.documentTitle)
            ?? document.conceptName?.codeMeaning
            ?? kind.displayName
        let state = ClinicalEncapsulatedDocumentDisplayState(
            title: title,
            kind: kind,
            mimeType: document.mimeType,
            byteCount: document.encapsulatedDocumentLength,
            preferredFileExtension: document.preferredFileExtension,
            sourceInstanceCount: document.sourceInstances.count,
            documentData: document.documentData
        )
        let filename = exportFilename(
            title: title,
            fallback: kind.displayName,
            preferredExtension: document.preferredFileExtension
        )

        return ClinicalNonImageObjectDisplayItem(
            id: stableID(prefix: "document", sopInstanceUID: document.sopInstanceUID, sourceURL: sourceURL),
            kind: .encapsulatedDocument,
            title: title,
            subtitle: metadataSubtitle([kind.displayName, document.mimeType]),
            documentState: state,
            exportState: ClinicalObjectExportState(
                suggestedFilename: filename,
                byteCount: document.encapsulatedDocumentLength,
                data: document.documentData
            )
        )
    }

    public static func makeItem(from waveform: DicomWaveform,
                                sourceURL: URL? = nil) -> ClinicalNonImageObjectDisplayItem {
        let title = ClinicalDisplayTextSanitizer.safeSeriesTitle(waveform.modality)
            ?? waveform.kind.map(title(for:))
            ?? "Waveform"
        let state = ClinicalWaveformDisplayState(
            title: title,
            traces: makeTraces(from: waveform)
        )
        let csvData = makeWaveformCSVData(from: state)
        let filename = exportFilename(title: title, fallback: "waveform", preferredExtension: "csv")

        return ClinicalNonImageObjectDisplayItem(
            id: stableID(prefix: "waveform", sopInstanceUID: waveform.sopInstanceUID, sourceURL: sourceURL),
            kind: .waveform,
            title: title,
            subtitle: metadataSubtitle([
                "\(waveform.totalChannelCount) channels",
                durationLabel(state.durationSeconds)
            ]),
            waveformState: state,
            exportState: ClinicalObjectExportState(
                suggestedFilename: filename,
                byteCount: csvData.count,
                data: csvData
            )
        )
    }

    public static func makeItem(from video: DicomVideo,
                                streamURL: URL? = nil,
                                sourceURL: URL? = nil) -> ClinicalNonImageObjectDisplayItem {
        let title = ClinicalDisplayTextSanitizer.safeSeriesTitle(video.modality)
            ?? video.kind.map(title(for:))
            ?? "Video"
        let state = ClinicalVideoDisplayState(
            title: title,
            codecLabel: video.codec.displayName,
            dimensions: ClinicalVideoDimensions(columns: video.columns, rows: video.rows),
            frameCount: video.numberOfFrames,
            frameRate: video.frameRate,
            durationSeconds: video.durationSeconds,
            streamByteCount: video.streamData.count,
            streamURL: streamURL
        )
        let filename = exportFilename(
            title: title,
            fallback: "video",
            preferredExtension: preferredVideoExtension(for: video.codec)
        )

        return ClinicalNonImageObjectDisplayItem(
            id: stableID(prefix: "video", sopInstanceUID: video.sopInstanceUID, sourceURL: sourceURL),
            kind: .video,
            title: title,
            subtitle: metadataSubtitle([
                video.codec.displayName,
                state.dimensionsLabel,
                state.durationLabel
            ]),
            videoState: state,
            exportState: ClinicalObjectExportState(
                suggestedFilename: filename,
                byteCount: video.streamData.count,
                sourceURL: streamURL
            )
        )
    }
}

private extension DicomClinicalObjectDisplayBridge {
    static func makeTraces(from waveform: DicomWaveform) -> [ClinicalWaveformTrace] {
        waveform.multiplexGroups.enumerated().flatMap { groupIndex, group in
            group.channels.enumerated().map { channelIndex, channel in
                let channelNumber = channel.number ?? channelIndex + 1
                let label = [
                    group.label,
                    channel.label ?? "Ch \(channelNumber)"
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
                    .joined(separator: " ")
                return ClinicalWaveformTrace(
                    id: "g\(groupIndex + 1)-c\(channelNumber)",
                    label: label.isEmpty ? "Ch \(channelNumber)" : label,
                    unitLabel: channel.sensitivityUnits?.codeMeaning,
                    samplingFrequency: group.samplingFrequency,
                    samples: channel.samples
                )
            }
        }
    }

    static func makeWaveformCSVData(from state: ClinicalWaveformDisplayState) -> Data {
        let maxSampleCount = state.traces.map { $0.samples.count }.max() ?? 0
        guard maxSampleCount > 0 else { return Data() }

        var rows: [String] = []
        rows.append((["sample"] + state.traces.map { csvEscaped($0.label) }).joined(separator: ","))
        for sampleIndex in 0..<maxSampleCount {
            let values = state.traces.map { trace -> String in
                guard trace.samples.indices.contains(sampleIndex) else { return "" }
                return String(trace.samples[sampleIndex])
            }
            rows.append(([String(sampleIndex)] + values).joined(separator: ","))
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    static func title(for kind: DicomWaveformStorageKind) -> String {
        switch kind {
        case .twelveLeadECG:
            return "12-lead ECG"
        case .generalECG:
            return "ECG waveform"
        case .ambulatoryECG:
            return "Ambulatory ECG"
        case .general32BitECG:
            return "32-bit ECG"
        case .hemodynamic:
            return "Hemodynamic waveform"
        case .cardiacElectrophysiology:
            return "Electrophysiology waveform"
        case .arterialPulse:
            return "Arterial pulse waveform"
        case .respiratory:
            return "Respiratory waveform"
        }
    }

    static func title(for kind: DicomVideoStorageKind) -> String {
        switch kind {
        case .endoscopic:
            return "Endoscopic video"
        case .microscopic:
            return "Microscopic video"
        case .photographic:
            return "Photographic video"
        }
    }

    static func preferredVideoExtension(for codec: DicomVideoCodec) -> String {
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

    static func stableID(prefix: String, sopInstanceUID: String?, sourceURL: URL?) -> String {
        if let sopInstanceUID = sopInstanceUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return "\(prefix)-\(sopInstanceUID)"
        }
        if let sourceURL {
            return "\(prefix)-\(sourceURL.standardizedFileURL.path)"
        }
        return "\(prefix)-\(UUID().uuidString)"
    }

    static func exportFilename(title: String, fallback: String, preferredExtension: String) -> String {
        let stem = safeFileStem(title).nilIfEmpty ?? safeFileStem(fallback).nilIfEmpty ?? "dicom-object"
        let ext = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "bin"
        return "\(stem).\(ext)"
    }

    static func safeFileStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    static func metadataSubtitle(_ parts: [String?]) -> String? {
        let values = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " | ")
    }

    static func durationLabel(_ durationSeconds: Double) -> String? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return String(format: "%.3g s", durationSeconds)
    }

    static func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
