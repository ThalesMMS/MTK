import Foundation

public enum ClinicalEncapsulatedDocumentKind: String, Equatable, Sendable {
    case pdf
    case cda
    case stl
    case other

    public init(mimeType: String, preferredFileExtension: String? = nil) {
        let normalizedMIME = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedExtension = preferredFileExtension?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch (normalizedMIME, normalizedExtension) {
        case ("application/pdf", _), (_, "pdf"):
            self = .pdf
        case ("text/xml", _), ("application/xml", _), (_, "xml"):
            self = .cda
        case ("model/stl", _), ("application/sla", _), (_, "stl"):
            self = .stl
        default:
            self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .pdf:
            return "PDF"
        case .cda:
            return "CDA/XML"
        case .stl:
            return "STL"
        case .other:
            return "Document"
        }
    }

    public var systemImageName: String {
        switch self {
        case .pdf:
            return "doc.richtext"
        case .cda:
            return "doc.text"
        case .stl:
            return "shippingbox"
        case .other:
            return "doc"
        }
    }
}

public struct ClinicalEncapsulatedDocumentDisplayState: Equatable, Sendable {
    public var title: String?
    public var kind: ClinicalEncapsulatedDocumentKind
    public var mimeType: String
    public var byteCount: Int
    public var preferredFileExtension: String
    public var sourceInstanceCount: Int
    public var documentData: Data?
    public var textPreview: String?

    public init(
        title: String? = nil,
        kind: ClinicalEncapsulatedDocumentKind,
        mimeType: String,
        byteCount: Int,
        preferredFileExtension: String,
        sourceInstanceCount: Int = 0,
        documentData: Data? = nil
    ) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.kind = kind
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "application/octet-stream"
        self.byteCount = max(0, byteCount)
        self.preferredFileExtension = preferredFileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "bin"
        self.sourceInstanceCount = max(0, sourceInstanceCount)
        self.documentData = documentData
        if kind == .cda, let documentData {
            self.textPreview = String(data: documentData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        } else {
            self.textPreview = nil
        }
    }

    public var displayTitle: String {
        title ?? kind.displayName
    }

    public var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    public var isExportable: Bool {
        documentData != nil && byteCount > 0
    }
}

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI

public struct ClinicalEncapsulatedDocumentView: View {
    private let state: ClinicalEncapsulatedDocumentDisplayState

    public init(state: ClinicalEncapsulatedDocumentDisplayState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            metadataStrip
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ClinicalEncapsulatedDocumentView")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.kind.systemImageName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(state.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.kind {
        case .pdf:
            pdfContent
        case .cda:
            xmlContent
        case .stl, .other:
            objectSummary
        }
    }

    @ViewBuilder
    private var pdfContent: some View {
        if let documentData = state.documentData {
            ClinicalPDFPreview(data: documentData)
                .frame(minHeight: 260)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            objectSummary
        }
    }

    @ViewBuilder
    private var xmlContent: some View {
        if let textPreview = state.textPreview {
            ScrollView {
                Text(textPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 220)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityIdentifier("ClinicalEncapsulatedDocumentXMLPreview")
        } else {
            objectSummary
        }
    }

    private var objectSummary: some View {
        VStack(spacing: 8) {
            Image(systemName: state.kind.systemImageName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text(state.mimeType)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var metadataStrip: some View {
        HStack(spacing: 12) {
            metadataText(state.mimeType)
            metadataText(state.byteCountLabel)
            metadataText(".\(state.preferredFileExtension)")
            if state.sourceInstanceCount > 0 {
                metadataText("\(state.sourceInstanceCount) refs")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataText(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
    }
}

#if canImport(PDFKit)
import PDFKit

private struct ClinicalPDFPreview {
    let data: Data
}

#if os(iOS)
extension ClinicalPDFPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#elseif os(macOS)
extension ClinicalPDFPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .black
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#endif
#else
private struct ClinicalPDFPreview: View {
    let data: Data

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .regular))
            Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
#endif
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
