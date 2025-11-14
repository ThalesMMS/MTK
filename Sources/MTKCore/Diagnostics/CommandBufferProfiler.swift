//
//  CommandBufferProfiler.swift
//  MTK
//
//  Captures CPU/GPU timings for Metal command buffers and emits concise
//  diagnostics so threadgroup tuning stays observable outside Xcode tools.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal
import OSLog

struct CommandBufferMetrics {
    let label: String
    let cpuMs: Double
    let gpuMs: Double?
    let kernelMs: Double?
    let status: MTLCommandBufferStatus
    let error: (any Error)?

    var formattedSummary: String {
        let cpu = CommandBufferMetrics.format(cpuMs)
        let gpu = gpuMs.map(CommandBufferMetrics.format) ?? "--"
        let kernel = kernelMs.map(CommandBufferMetrics.format) ?? "--"
        return "cpu=\(cpu) ms | gpu=\(gpu) ms | kernel=\(kernel) ms"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

public enum CommandBufferProfiler {

    public static func captureTimes(for commandBuffer: any MTLCommandBuffer,
                                    label: String,
                                    category: String = "Benchmark") {
        let cpuStart = DispatchTime.now().uptimeNanoseconds

        commandBuffer.addCompletedHandler { buffer in
            let cpuEnd = DispatchTime.now().uptimeNanoseconds
            let cpuMs = Double(cpuEnd &- cpuStart) / 1_000_000.0

            let gpuMs = interval(buffer.gpuStartTime, buffer.gpuEndTime)
            let kernelMs = interval(buffer.kernelStartTime, buffer.kernelEndTime)

            let metrics = CommandBufferMetrics(label: label,
                                               cpuMs: cpuMs,
                                               gpuMs: gpuMs,
                                               kernelMs: kernelMs,
                                               status: buffer.status,
                                               error: buffer.error)

            log(metrics: metrics, category: category)
        }
    }

    private static func interval(_ start: CFTimeInterval, _ end: CFTimeInterval) -> Double? {
        guard start > 0, end > 0 else { return nil }
        return max(0, (end - start) * 1000.0)
    }

    private static func log(metrics: CommandBufferMetrics, category: String) {
        let logger = Logger(subsystem: "com.mtk.volumerendering", category: category)

        if metrics.status == .completed {
            logger.info("CommandBuffer [\(metrics.label)] completed: \(metrics.formattedSummary)")
        } else if let error = metrics.error {
            logger.error("CommandBuffer [\(metrics.label)] failed: \(metrics.formattedSummary) → \(String(describing: error))")
        } else {
            logger.warning("CommandBuffer [\(metrics.label)] ended with status \(describe(metrics.status)): \(metrics.formattedSummary)")
        }
    }

    private static func describe(_ status: MTLCommandBufferStatus) -> String {
        switch status {
        case .notEnqueued: return "notEnqueued"
        case .enqueued: return "enqueued"
        case .committed: return "committed"
        case .scheduled: return "scheduled"
        case .completed: return "completed"
        case .error: return "error"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

public struct CommandBufferTimings {
    public let kernelTime: Double
    public let gpuTime: Double
    public let cpuTime: Double
}

public extension MTLCommandBuffer {
    func timings(cpuStart: CFTimeInterval, cpuEnd: CFTimeInterval) -> CommandBufferTimings {
        let kernelDuration = Self.durationMillis(start: kernelStartTime, end: kernelEndTime)
        let gpuDuration = Self.durationMillis(start: gpuStartTime, end: gpuEndTime)
        let cpuDuration = max(0, (cpuEnd - cpuStart) * 1000.0)

        return CommandBufferTimings(kernelTime: kernelDuration,
                                    gpuTime: gpuDuration,
                                    cpuTime: cpuDuration)
    }

    private static func durationMillis(start: CFTimeInterval, end: CFTimeInterval) -> Double {
        guard start > 0, end > 0, end >= start else {
            return 0
        }
        return (end - start) * 1000.0
    }
}
