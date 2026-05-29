import CoreGraphics
import MTKCore
@testable import MTKUI
import XCTest

@MainActor
final class ProgressiveVolumeUpdateTests: XCTestCase {
    func testMedicalViewportProgressiveUpdatesApplyInOrderAndUsePreviewQuality() async throws {
        let viewport = FakeProgressiveMedicalViewport()
        let updates = AsyncThrowingStream<ProgressiveVolumeDatasetUpdate, Error> { continuation in
            continuation.yield(makeUpdate(index: 0, quality: .preview, fraction: 0.25, final: false, voxelValue: 10))
            continuation.yield(makeUpdate(index: 1, quality: .refinement, fraction: 0.75, final: false, voxelValue: 20))
            continuation.yield(makeUpdate(index: 2, quality: .final, fraction: 1.0, final: true, voxelValue: 30))
            continuation.finish()
        }

        try await viewport.applyProgressiveDatasetUpdates(updates)

        XCTAssertEqual(viewport.appliedVoxelValues, [10, 20, 30])
        XCTAssertEqual(viewport.progressiveVolumeState.phase, .complete)
        XCTAssertEqual(viewport.progressiveVolumeState.currentLayer?.quality, .final)
        XCTAssertEqual(viewport.state.dataset?.intensityRange, 30...30)
        XCTAssertEqual(
            viewport.events,
            [
                "begin-preview",
                "apply:10",
                "layer:0:preview",
                "apply:20",
                "layer:1:refinement",
                "apply:30",
                "layer:2:final",
                "end-preview",
                "force-final"
            ]
        )
    }

    func testMedicalViewportProgressiveUpdatesStopPendingUpdatesWhenCancelled() async throws {
        let viewport = FakeProgressiveMedicalViewport()
        let updates = DelayedProgressiveUpdateSequence(updates: [
            makeUpdate(index: 0, quality: .preview, fraction: 0.2, final: false, voxelValue: 10),
            makeUpdate(index: 1, quality: .refinement, fraction: 0.8, final: false, voxelValue: 20)
        ])

        let task = Task {
            try await viewport.applyProgressiveDatasetUpdates(updates)
        }
        try await waitUntil { viewport.appliedVoxelValues.count == 1 }

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected progressive update cancellation to throw")
        } catch is CancellationError {
            XCTAssertEqual(viewport.appliedVoxelValues, [10])
            XCTAssertEqual(viewport.progressiveVolumeState.phase, .cancelled)
            XCTAssertEqual(viewport.progressiveVolumeState.currentLayer?.index, 0)
            XCTAssertTrue(viewport.events.contains("cancel"))
        }
    }

    private func makeUpdate(index: Int,
                            quality: ProgressiveVolumeQuality,
                            fraction: Double,
                            final: Bool,
                            voxelValue: Int16) -> ProgressiveVolumeDatasetUpdate {
        ProgressiveVolumeDatasetUpdate(
            layer: ProgressiveVolumeLayer(
                index: index,
                totalLayerCount: 3,
                quality: quality,
                byteRange: index..<(index + 1),
                fractionComplete: fraction,
                isFinal: final
            ),
            dataset: makeDataset(voxelValue: voxelValue)
        )
    }

    private func makeDataset(voxelValue: Int16) -> VolumeDataset {
        let voxels = [voxelValue, voxelValue, voxelValue, voxelValue]
        return VolumeDataset(
            data: voxels.withUnsafeBytes { Data($0) },
            dimensions: VolumeDimensions(width: 2, height: 2, depth: 1),
            spacing: VolumeSpacing(x: 1, y: 1, z: 1),
            pixelFormat: .int16Signed,
            intensityRange: Int32(voxelValue)...Int32(voxelValue),
            recommendedWindow: Int32(voxelValue)...Int32(voxelValue)
        )
    }

    private func waitUntil(_ predicate: @MainActor @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for progressive update")
    }
}

private struct DelayedProgressiveUpdateSequence: AsyncSequence {
    typealias Element = ProgressiveVolumeDatasetUpdate

    let updates: [ProgressiveVolumeDatasetUpdate]

    func makeAsyncIterator() -> Iterator {
        Iterator(updates: updates)
    }

    struct Iterator: AsyncIteratorProtocol {
        let updates: [ProgressiveVolumeDatasetUpdate]
        var index = 0

        mutating func next() async throws -> ProgressiveVolumeDatasetUpdate? {
            guard index < updates.count else { return nil }
            if index > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            try Task.checkCancellation()
            defer { index += 1 }
            return updates[index]
        }
    }
}

@MainActor
private final class FakeProgressiveMedicalViewport: MedicalViewport {
    let id = ViewportID()
    let viewportType: MedicalViewportType = .volume3D
    let renderMode: MedicalViewportRenderMode = .volume3D(method: .dvr)
    let surface: any ViewportPresenting = FakeViewportSurface()

    private(set) var state: MedicalViewportState
    private(set) var progressiveVolumeState: ProgressiveVolumeStreamState = .idle
    private(set) var appliedVoxelValues: [Int16] = []
    private(set) var events: [String] = []
    private var currentDataset: VolumeDataset?

    init() {
        state = MedicalViewportState(
            viewportID: id,
            viewportType: viewportType,
            renderMode: renderMode,
            presentation: MedicalViewportPresentationState(
                isMetalBacked: false,
                drawablePixelSize: .zero
            )
        )
    }

    func applyDataset(_ dataset: VolumeDataset) async {
        currentDataset = dataset
        let value = firstVoxelValue(in: dataset)
        appliedVoxelValues.append(value)
        events.append("apply:\(value)")
        refreshState()
    }

    func recordProgressiveVolumeUpdate(_ update: ProgressiveVolumeDatasetUpdate) async {
        progressiveVolumeState = update.layer.isFinal
            ? .complete(layer: update.layer)
            : .streaming(layer: update.layer)
        events.append("layer:\(update.layer.index):\(update.layer.quality.rawValue)")
        refreshState()
    }

    func recordProgressiveVolumeStreamCancellation() async {
        progressiveVolumeState = .cancelled(layer: progressiveVolumeState.currentLayer)
        events.append("cancel")
        refreshState()
    }

    func beginProgressivePreviewInteraction() async {
        events.append("begin-preview")
    }

    func endProgressivePreviewInteraction() async {
        events.append("end-preview")
    }

    func forceProgressiveFinalRenderQuality() async {
        events.append("force-final")
    }

    func setWindowLevel(window: Double, level: Double) async {
        _ = (window, level)
    }

    func resetCamera() async {}

    private func refreshState() {
        state = MedicalViewportState(
            viewportID: id,
            viewportType: viewportType,
            renderMode: renderMode,
            dataset: currentDataset.map(MedicalViewportDatasetSummary.init(dataset:)),
            progressiveVolumeState: progressiveVolumeState,
            presentation: MedicalViewportPresentationState(
                isMetalBacked: false,
                drawablePixelSize: .zero
            )
        )
    }

    private func firstVoxelValue(in dataset: VolumeDataset) -> Int16 {
        dataset.data.withUnsafeBytes { bytes in
            bytes.load(as: Int16.self)
        }
    }
}

@MainActor
private final class FakeViewportSurface: ViewportPresenting {
    let view = PlatformView(frame: .zero)

    func setContentScale(_ scale: CGFloat) {
        _ = scale
    }
}
