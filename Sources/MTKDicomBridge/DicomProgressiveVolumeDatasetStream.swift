import DicomCore
import Foundation
import MTKCore

public struct DicomProgressiveVolumeBridgeUpdate: Sendable {
    public let layer: ProgressiveVolumeLayer
    public let volume: DicomSeriesVolume

    public init(layer: ProgressiveVolumeLayer, volume: DicomSeriesVolume) {
        self.layer = layer
        self.volume = volume
    }

    public init(dicomUpdate: DicomProgressiveVolumeUpdate) {
        self.init(layer: ProgressiveVolumeLayer(dicomLayer: dicomUpdate.layer),
                  volume: dicomUpdate.volume)
    }
}

public extension ProgressiveVolumeQuality {
    init(dicomQuality: DicomProgressiveUpdateQuality) {
        switch dicomQuality {
        case .preview:
            self = .preview
        case .refinement:
            self = .refinement
        case .final:
            self = .final
        }
    }
}

public extension ProgressiveVolumeLayer {
    init(dicomLayer: DicomProgressiveLayer) {
        self.init(index: dicomLayer.index,
                  totalLayerCount: dicomLayer.totalLayerCount,
                  quality: ProgressiveVolumeQuality(dicomQuality: dicomLayer.quality),
                  byteRange: dicomLayer.byteRange,
                  fractionComplete: dicomLayer.fractionComplete,
                  isFinal: dicomLayer.isFinal)
    }
}

public struct DicomProgressiveVolumeDatasetStream: Sendable {
    private let bufferingPolicy: AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error>.Continuation.BufferingPolicy

    public init(
        bufferingPolicy: AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) {
        self.bufferingPolicy = bufferingPolicy
    }

    public func datasetUpdates(
        from volumeUpdates: AsyncThrowingStream<DicomProgressiveVolumeBridgeUpdate, Error>
    ) -> AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                do {
                    for try await update in volumeUpdates {
                        try Task.checkCancellation()
                        let dataset = try DicomVolumeDatasetImporter.makeDataset(from: update.volume)
                        try Task.checkCancellation()
                        continuation.yield(
                            ProgressiveVolumeDatasetUpdate(
                                layer: update.layer,
                                dataset: dataset
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func datasetUpdates(
        from volumeUpdates: AsyncThrowingStream<DicomProgressiveVolumeUpdate, Error>
    ) -> AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                do {
                    for try await update in volumeUpdates {
                        try Task.checkCancellation()
                        let bridgedUpdate = DicomProgressiveVolumeBridgeUpdate(dicomUpdate: update)
                        let dataset = try DicomVolumeDatasetImporter.makeDataset(from: bridgedUpdate.volume)
                        try Task.checkCancellation()
                        continuation.yield(
                            ProgressiveVolumeDatasetUpdate(
                                layer: bridgedUpdate.layer,
                                dataset: dataset
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
