import Foundation
import MTKCore

public enum ViewerSyncOption: String, CaseIterable, Identifiable, Sendable {
    case transforms
    case windowLevel
    case location
    case sameStudy

    public var id: String { rawValue }
}

public struct ViewerSyncState: Equatable, Sendable {
    public var syncTransforms: Bool
    public var syncWindowLevel: Bool
    public var syncLocation: Bool
    public var syncSameStudy: Bool

    public init(syncTransforms: Bool = false,
                syncWindowLevel: Bool = false,
                syncLocation: Bool = false,
                syncSameStudy: Bool = true) {
        self.syncTransforms = syncTransforms
        self.syncWindowLevel = syncWindowLevel
        self.syncLocation = syncLocation
        self.syncSameStudy = syncSameStudy
    }

    public static let `default` = ViewerSyncState()

    public var hasActiveSyncChannels: Bool {
        syncTransforms || syncWindowLevel || syncLocation
    }

    public func setting(_ option: ViewerSyncOption,
                        enabled: Bool) -> ViewerSyncState {
        var next = self
        switch option {
        case .transforms:
            next.syncTransforms = enabled
        case .windowLevel:
            next.syncWindowLevel = enabled
        case .location:
            next.syncLocation = enabled
        case .sameStudy:
            next.syncSameStudy = enabled
        }
        return next
    }
}

public struct ViewerPanelIdentity: Equatable, Sendable {
    public var panelID: String
    public var datasetIdentifier: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var frameOfReferenceUID: String?

    public init(panelID: String,
                datasetIdentifier: String? = nil,
                studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil,
                frameOfReferenceUID: String? = nil) {
        self.panelID = panelID
        self.datasetIdentifier = datasetIdentifier
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
    }

    public init(panelID: String,
                dataset: VolumeDataset?) {
        self.init(
            panelID: panelID,
            datasetIdentifier: Self.datasetIdentifier(for: dataset),
            studyInstanceUID: dataset?.imageData.clinicalMetadata?.studyInstanceUID,
            seriesInstanceUID: dataset?.imageData.clinicalMetadata?.seriesInstanceUID,
            frameOfReferenceUID: dataset?.imageData.clinicalMetadata?.frameOfReferenceUID
        )
    }

    public func canSyncWith(_ other: ViewerPanelIdentity,
                            sameStudyOnly: Bool) -> Bool {
        guard panelID != other.panelID else { return false }
        guard sameStudyOnly else { return true }
        if let lhsStudy = nonEmpty(studyInstanceUID),
           let rhsStudy = nonEmpty(other.studyInstanceUID) {
            return lhsStudy == rhsStudy
        }
        guard let lhsDataset = nonEmpty(datasetIdentifier),
              let rhsDataset = nonEmpty(other.datasetIdentifier) else {
            return false
        }
        return lhsDataset == rhsDataset
    }

    public func hasCompatibleLocationGeometry(with other: ViewerPanelIdentity) -> Bool {
        if let lhsFrame = nonEmpty(frameOfReferenceUID),
           let rhsFrame = nonEmpty(other.frameOfReferenceUID) {
            return lhsFrame == rhsFrame
        }
        guard let lhsDataset = nonEmpty(datasetIdentifier),
              let rhsDataset = nonEmpty(other.datasetIdentifier) else {
            return false
        }
        return lhsDataset == rhsDataset
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func datasetIdentifier(for dataset: VolumeDataset?) -> String? {
        guard let dataset else { return nil }
        return [
            "\(dataset.dimensions.width)x\(dataset.dimensions.height)x\(dataset.dimensions.depth)",
            "\(dataset.spacing.x),\(dataset.spacing.y),\(dataset.spacing.z)",
            "\(dataset.pixelFormat)",
            "\(dataset.data.count)"
        ].joined(separator: "|")
    }
}

public struct Viewer2DPanelSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { identity.panelID }
    public var identity: ViewerPanelIdentity
    public var transform: Viewer2DTransform
    public var windowLevelState: TwoDWindowLevelState
    public var sliceIndex: Int
    public var normalizedLocation: Double?

    public init(identity: ViewerPanelIdentity,
                transform: Viewer2DTransform = .identity,
                windowLevelState: TwoDWindowLevelState = .default,
                sliceIndex: Int = 0,
                normalizedLocation: Double? = nil) {
        self.identity = identity
        self.transform = transform
        self.windowLevelState = windowLevelState
        self.sliceIndex = max(sliceIndex, 0)
        self.normalizedLocation = normalizedLocation?.isFinite == true ? normalizedLocation : nil
    }
}

public struct Clinical2DSyncCoordinator: Equatable, Sendable {
    public var syncState: ViewerSyncState
    public private(set) var panels: [Viewer2DPanelSnapshot]

    public init(syncState: ViewerSyncState = .default,
                panels: [Viewer2DPanelSnapshot] = []) {
        self.syncState = syncState
        self.panels = panels
    }

    public mutating func setPanels(_ panels: [Viewer2DPanelSnapshot]) {
        self.panels = panels
    }

    @discardableResult
    public mutating func applySourcePanelUpdate(_ source: Viewer2DPanelSnapshot) -> [Viewer2DPanelSnapshot] {
        guard let sourceIndex = panels.firstIndex(where: { $0.id == source.id }) else {
            panels.append(source)
            return panels
        }
        panels[sourceIndex] = source
        guard panels.count > 1, syncState.hasActiveSyncChannels else { return panels }

        for index in panels.indices where panels[index].id != source.id {
            guard source.identity.canSyncWith(panels[index].identity,
                                              sameStudyOnly: syncState.syncSameStudy) else {
                continue
            }
            if syncState.syncTransforms {
                panels[index].transform = source.transform
            }
            if syncState.syncWindowLevel {
                panels[index].windowLevelState = source.windowLevelState
            }
            if syncState.syncLocation,
               source.identity.hasCompatibleLocationGeometry(with: panels[index].identity) {
                panels[index].sliceIndex = source.sliceIndex
                panels[index].normalizedLocation = source.normalizedLocation
            }
        }
        return panels
    }
}
