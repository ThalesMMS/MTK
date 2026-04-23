import Foundation
import MTKCore

@MainActor
enum RenderingTelemetry {
    enum VolumeRenderFailureReason: String {
        case runtimeError
        case missingImage
        case missingTransferFunction
    }

    enum MPRRenderFailureReason: String {
        case runtimeError
    }

    private struct Recorder {
        var metrics: any MetricsProtocol

        func increment(_ name: String, by amount: Int = 1) {
            metrics.incrementCounter(name, by: amount)
        }

        func trackTiming(_ category: String, interval: TimeInterval, name: String?) {
            metrics.trackTiming(category, interval: interval, name: name)
        }
    }

    private static var recorder = Recorder(metrics: Metrics.shared)
    private static let logger = Logger(category: "Volumetric.RenderingTelemetry")

    static func volumeRenderScheduled(qualityState: RenderQualityState) {
        recorder.increment("metal.volume.render.scheduled")
        recorder.increment("metal.volume.render.scheduled.\(metricName(for: qualityState))")
    }

    static func volumeRenderCompleted(duration: TimeInterval, qualityState: RenderQualityState) {
        recorder.trackTiming("metal.volume.render", interval: duration, name: "adapter")
        recorder.trackTiming("metal.volume.render.\(metricName(for: qualityState))", interval: duration, name: "adapter")
        recorder.increment("metal.volume.render.total")
        recorder.increment("metal.volume.render.adapter.success")
        recorder.increment("metal.volume.render.\(metricName(for: qualityState)).success")
    }

    static func volumeRenderFailed(duration: TimeInterval,
                                   qualityState: RenderQualityState,
                                   reason: VolumeRenderFailureReason,
                                   error: (any Error)?) {
        recorder.trackTiming("metal.volume.render", interval: duration, name: "failure")
        recorder.trackTiming("metal.volume.render.\(metricName(for: qualityState))", interval: duration, name: "failure")
        recorder.increment("metal.volume.render.total")
        recorder.increment("metal.volume.render.failure")
        recorder.increment("metal.volume.render.\(metricName(for: qualityState)).failure")
        logFailure(prefix: "Metal volume render failed", reason: reason.rawValue, error: error)
    }

    static func mprRenderScheduled(blend: MPRBlendMode, qualityState: RenderQualityState) {
        recorder.increment("metal.mpr.render.scheduled")
        recorder.increment("metal.mpr.render.scheduled.\(metricName(for: qualityState))")
        recorder.increment("metal.mpr.render.scheduled.\(metricName(for: blend))")
    }

    static func mprRenderCompleted(duration: TimeInterval, blend: MPRBlendMode, qualityState: RenderQualityState) {
        recorder.trackTiming("metal.mpr.render", interval: duration, name: "success")
        recorder.trackTiming("metal.mpr.render.\(metricName(for: qualityState))", interval: duration, name: "success")
        recorder.increment("metal.mpr.render.total")
        recorder.increment("metal.mpr.render.success")
        recorder.increment("metal.mpr.render.\(metricName(for: qualityState)).success")
        recorder.increment("metal.mpr.render.success.\(metricName(for: blend))")
    }

    static func mprRenderFailed(duration: TimeInterval,
                                qualityState: RenderQualityState,
                                reason: MPRRenderFailureReason,
                                error: (any Error)?) {
        recorder.trackTiming("metal.mpr.render", interval: duration, name: "failure")
        recorder.trackTiming("metal.mpr.render.\(metricName(for: qualityState))", interval: duration, name: "failure")
        recorder.increment("metal.mpr.render.total")
        recorder.increment("metal.mpr.render.failure")
        recorder.increment("metal.mpr.render.\(metricName(for: qualityState)).failure")
        logFailure(prefix: "Metal MPR render failed", reason: reason.rawValue, error: error)
    }

    @_spi(Testing)
    public static func withMetrics<T>(_ metrics: any MetricsProtocol,
                                      perform work: () async throws -> T) async rethrows -> T {
        let previous = recorder
        recorder = Recorder(metrics: metrics)
        defer { recorder = previous }
        return try await work()
    }

    private static func metricName(for blend: MPRBlendMode) -> String {
        switch blend {
        case .single:
            return "single"
        case .maximum:
            return "maximum"
        case .minimum:
            return "minimum"
        case .average:
            return "average"
        }
    }

    private static func metricName(for state: RenderQualityState) -> String {
        state.isPreview ? "preview" : "final"
    }

    private static func logFailure(prefix: String, reason: String, error: (any Error)?) {
        if let error {
            logger.error("\(prefix) reason=\(reason)", error: error)
        } else {
            logger.error("\(prefix) reason=\(reason)")
        }
    }
}
