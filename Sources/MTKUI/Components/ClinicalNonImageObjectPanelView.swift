import Foundation

public enum ClinicalNonImageObjectKind: String, Equatable, Sendable {
    case encapsulatedDocument
    case waveform
    case video

    public var displayName: String {
        switch self {
        case .encapsulatedDocument:
            return "Document"
        case .waveform:
            return "Waveform"
        case .video:
            return "Video"
        }
    }

    public var systemImageName: String {
        switch self {
        case .encapsulatedDocument:
            return "doc"
        case .waveform:
            return "waveform.path.ecg"
        case .video:
            return "play.rectangle"
        }
    }
}

public struct ClinicalObjectExportState: Equatable, Sendable {
    public var suggestedFilename: String
    public var byteCount: Int
    public var data: Data?
    public var sourceURL: URL?

    public init(suggestedFilename: String,
                byteCount: Int,
                data: Data? = nil,
                sourceURL: URL? = nil) {
        self.suggestedFilename = suggestedFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "dicom-object"
        self.byteCount = max(0, byteCount)
        self.data = data
        self.sourceURL = sourceURL
    }

    public var isExportable: Bool {
        data != nil || sourceURL != nil
    }

    public var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

public struct ClinicalNonImageObjectDisplayItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ClinicalNonImageObjectKind
    public var title: String
    public var subtitle: String?
    public var documentState: ClinicalEncapsulatedDocumentDisplayState?
    public var waveformState: ClinicalWaveformDisplayState?
    public var videoState: ClinicalVideoDisplayState?
    public var exportState: ClinicalObjectExportState?

    public init(id: String,
                kind: ClinicalNonImageObjectKind,
                title: String,
                subtitle: String? = nil,
                documentState: ClinicalEncapsulatedDocumentDisplayState? = nil,
                waveformState: ClinicalWaveformDisplayState? = nil,
                videoState: ClinicalVideoDisplayState? = nil,
                exportState: ClinicalObjectExportState? = nil) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? kind.displayName
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.documentState = documentState
        self.waveformState = waveformState
        self.videoState = videoState
        self.exportState = exportState
    }
}

public struct ClinicalNonImageObjectPanelState: Equatable, Sendable {
    public var items: [ClinicalNonImageObjectDisplayItem]
    public var selectedItemID: String?

    public init(items: [ClinicalNonImageObjectDisplayItem] = [],
                selectedItemID: String? = nil) {
        self.items = items
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = selectedItemID
        } else {
            self.selectedItemID = items.first?.id
        }
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    public var selectedItem: ClinicalNonImageObjectDisplayItem? {
        guard let selectedItemID else { return items.first }
        return items.first { $0.id == selectedItemID } ?? items.first
    }

    public var selectedIndex: Int? {
        guard let selectedItem else { return nil }
        return items.firstIndex { $0.id == selectedItem.id }
    }

    public var selectedItemNumberLabel: String? {
        guard let selectedIndex else { return nil }
        return "\(selectedIndex + 1) / \(items.count)"
    }

    public mutating func selectItem(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedItemID = id
    }

    public mutating func selectNext() {
        selectRelative(1)
    }

    public mutating func selectPrevious() {
        selectRelative(-1)
    }

    public func selectingItem(id: String) -> ClinicalNonImageObjectPanelState {
        var copy = self
        copy.selectItem(id: id)
        return copy
    }

    public func selectingNext() -> ClinicalNonImageObjectPanelState {
        var copy = self
        copy.selectNext()
        return copy
    }

    public func selectingPrevious() -> ClinicalNonImageObjectPanelState {
        var copy = self
        copy.selectPrevious()
        return copy
    }

    private mutating func selectRelative(_ delta: Int) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        let currentIndex = selectedIndex ?? 0
        let nextIndex = (currentIndex + delta + items.count) % items.count
        selectedItemID = items[nextIndex].id
    }
}

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import SwiftUI

public struct ClinicalNonImageObjectPanelView: View {
    @Binding private var state: ClinicalNonImageObjectPanelState

    public init(state: Binding<ClinicalNonImageObjectPanelState>) {
        self._state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.18)
            objectContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.96))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ClinicalNonImageObjectPanel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let item = state.selectedItem {
                Image(systemName: item.kind.systemImageName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if let label = state.selectedItemNumberLabel, state.items.count > 1 {
                Button {
                    state.selectPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous object")
                .accessibilityIdentifier("ClinicalObjectPreviousButton")

                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48)

                Button {
                    state.selectNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next object")
                .accessibilityIdentifier("ClinicalObjectNextButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var objectContent: some View {
        if let item = state.selectedItem {
            VStack(alignment: .leading, spacing: 10) {
                switch item.kind {
                case .encapsulatedDocument:
                    if let documentState = item.documentState {
                        ClinicalEncapsulatedDocumentView(state: documentState)
                    } else {
                        unavailableObject(item)
                    }
                case .waveform:
                    if let waveformState = item.waveformState {
                        ClinicalWaveformView(state: waveformState)
                    } else {
                        unavailableObject(item)
                    }
                case .video:
                    if let videoState = item.videoState {
                        ClinicalVideoView(state: videoState)
                    } else {
                        unavailableObject(item)
                    }
                }

                if let exportState = item.exportState {
                    exportMetadata(exportState)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            unavailableObject(nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func exportMetadata(_ state: ClinicalObjectExportState) -> some View {
        HStack(spacing: 12) {
            Label(state.suggestedFilename, systemImage: "square.and.arrow.up")
                .labelStyle(.titleAndIcon)
            Text(state.byteCountLabel)
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier("ClinicalObjectExportState")
    }

    private func unavailableObject(_ item: ClinicalNonImageObjectDisplayItem?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item?.kind.systemImageName ?? "doc")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text(item?.kind.displayName ?? "Object")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
