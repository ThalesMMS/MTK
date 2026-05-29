import Foundation
import MTKCore

@MainActor
public extension VolumeViewportControlling {
    var progressiveVolumeState: ProgressiveVolumeStreamState { .idle }

    func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        _ = update
    }

    func recordProgressiveVolumeStreamCancellation() async {}

    func applyProgressiveDatasetUpdates<S: AsyncSequence>(_ updates: S) async throws
    where S.Element == ProgressiveVolumeDatasetUpdate {
        var previewInteractionStarted = false
        do {
            for try await update in updates {
                try Task.checkCancellation()
                if !update.layer.isFinal, !previewInteractionStarted {
                    await beginAdaptiveSamplingInteraction()
                    previewInteractionStarted = true
                }
                await applyDataset(update.dataset)
                await recordProgressiveVolumeUpdate(update)
                try Task.checkCancellation()
                if update.layer.isFinal {
                    if previewInteractionStarted {
                        await endAdaptiveSamplingInteraction()
                        previewInteractionStarted = false
                    }
                    await forceFinalRenderQuality()
                }
            }
            if previewInteractionStarted {
                await endAdaptiveSamplingInteraction()
            }
        } catch is CancellationError {
            if previewInteractionStarted {
                await endAdaptiveSamplingInteraction()
            }
            await recordProgressiveVolumeStreamCancellation()
            throw CancellationError()
        }
    }
}

@MainActor
public extension MedicalViewport {
    func applyProgressiveDatasetUpdates<S: AsyncSequence>(_ updates: S) async throws
    where S.Element == ProgressiveVolumeDatasetUpdate {
        var previewInteractionStarted = false
        do {
            for try await update in updates {
                try Task.checkCancellation()
                if !update.layer.isFinal, !previewInteractionStarted {
                    await beginProgressivePreviewInteraction()
                    previewInteractionStarted = true
                }
                await applyDataset(update.dataset)
                await recordProgressiveVolumeUpdate(update)
                try Task.checkCancellation()
                if update.layer.isFinal {
                    if previewInteractionStarted {
                        await endProgressivePreviewInteraction()
                        previewInteractionStarted = false
                    }
                    await forceProgressiveFinalRenderQuality()
                }
            }
            if previewInteractionStarted {
                await endProgressivePreviewInteraction()
            }
        } catch is CancellationError {
            if previewInteractionStarted {
                await endProgressivePreviewInteraction()
            }
            await recordProgressiveVolumeStreamCancellation()
            throw CancellationError()
        }
    }
}
