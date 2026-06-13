import Combine
import Foundation

/// Bridges live `ClinicalViewerCoordinator` instances (one per 2D panel) through the
/// pure `Clinical2DSyncCoordinator`, propagating slice location, window level and
/// transforms across panels according to the active `ViewerSyncState` channels.
///
/// Snapshots are rebuilt from the coordinators on every event, so dataset/study
/// changes are picked up automatically and no internal state can drift.
@MainActor
public final class Clinical2DPanelSyncHub: ObservableObject {
    public struct Panel {
        public let panelID: String
        public let coordinator: ClinicalViewerCoordinator

        public init(panelID: String, coordinator: ClinicalViewerCoordinator) {
            self.panelID = panelID
            self.coordinator = coordinator
        }
    }

    private enum PanelChange {
        case sliceIndex(Int)
        case transform(Viewer2DTransform)
        case windowLevel(TwoDWindowLevelState)
    }

    public private(set) var syncState: ViewerSyncState = .default
    private var panels: [Panel] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isApplyingSync = false

    public init() {}

    public func setPanels(_ panels: [Panel]) {
        self.panels = panels
        resubscribe()
    }

    public func setSyncState(_ state: ViewerSyncState) {
        syncState = state
    }

    private func resubscribe() {
        cancellables.removeAll()
        for (index, panel) in panels.enumerated() {
            panel.coordinator.$twoDSliceIndex
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.panelDidChange(at: index, change: .sliceIndex(value))
                }
                .store(in: &cancellables)
            panel.coordinator.$twoDTransform
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.panelDidChange(at: index, change: .transform(value))
                }
                .store(in: &cancellables)
            panel.coordinator.$twoDWindowLevelState
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.panelDidChange(at: index, change: .windowLevel(value))
                }
                .store(in: &cancellables)
        }
    }

    private func panelDidChange(at index: Int, change: PanelChange) {
        guard !isApplyingSync,
              panels.indices.contains(index),
              panels.count > 1,
              syncState.hasActiveSyncChannels else {
            return
        }

        // @Published emits on willSet, so the changed property must come from the
        // publisher payload instead of the coordinator, which still holds the old value.
        var before = panels.indices.map { snapshot(forPanelAt: $0) }
        before[index] = snapshot(forPanelAt: index, applying: change)

        var sync = Clinical2DSyncCoordinator(syncState: syncState, panels: before)
        let updated = sync.applySourcePanelUpdate(before[index])

        isApplyingSync = true
        defer { isApplyingSync = false }

        for (panelIndex, panel) in panels.enumerated() where panelIndex != index {
            guard let target = updated.first(where: { $0.id == panel.panelID }) else { continue }
            apply(target, prior: before[panelIndex], to: panel.coordinator)
        }
    }

    private func snapshot(forPanelAt index: Int,
                          applying change: PanelChange? = nil) -> Viewer2DPanelSnapshot {
        let panel = panels[index]
        let coordinator = panel.coordinator
        var sliceIndex = coordinator.twoDSliceIndex
        var transform = coordinator.twoDTransform
        var windowLevelState = coordinator.twoDWindowLevelState
        switch change {
        case .sliceIndex(let value):
            sliceIndex = value
        case .transform(let value):
            transform = value
        case .windowLevel(let value):
            windowLevelState = value
        case nil:
            break
        }
        let sliceCount = coordinator.twoDSliceCount
        return Viewer2DPanelSnapshot(
            identity: ViewerPanelIdentity(panelID: panel.panelID, dataset: coordinator.dataset),
            transform: transform,
            windowLevelState: windowLevelState,
            sliceIndex: sliceIndex,
            normalizedLocation: sliceCount > 1 ? Double(sliceIndex) / Double(sliceCount - 1) : nil
        )
    }

    private func apply(_ target: Viewer2DPanelSnapshot,
                       prior: Viewer2DPanelSnapshot,
                       to coordinator: ClinicalViewerCoordinator) {
        if target.transform != prior.transform {
            coordinator.setTwoDTransform(target.transform)
        }
        if target.windowLevelState != prior.windowLevelState {
            coordinator.applySyncedTwoDWindowLevelState(target.windowLevelState)
        }
        if target.sliceIndex != prior.sliceIndex || target.normalizedLocation != prior.normalizedLocation {
            coordinator.setTwoDSliceIndex(
                resolvedSliceIndex(for: target, sliceCount: coordinator.twoDSliceCount)
            )
        }
    }

    private func resolvedSliceIndex(for target: Viewer2DPanelSnapshot,
                                    sliceCount: Int) -> Int {
        if let location = target.normalizedLocation, sliceCount > 1 {
            return Int((location * Double(sliceCount - 1)).rounded())
        }
        return target.sliceIndex
    }
}
