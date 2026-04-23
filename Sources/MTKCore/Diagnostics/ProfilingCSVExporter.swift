//
//  ProfilingCSVExporter.swift
//  MTK
//
//  CSV export for clinical profiling sessions.
//

import Foundation

public struct ProfilingCSVExporter: Sendable {
    public static let headers: [String] = [
        "timestamp",
        "stage",
        "cpuTimeMs",
        "gpuTimeMs",
        "memoryBytes",
        "resolution",
        "viewportType",
        "quality",
        "renderMode",
        "deviceName",
        "osVersion",
        "gpuFamily",
        "maxThreadsPerThreadgroupWidth",
        "maxThreadsPerThreadgroupHeight",
        "maxThreadsPerThreadgroupDepth",
        "recommendedMaxWorkingSetSize",
        "appVersion",
        "buildNumber",
        "metadata"
    ]

    public init() {}

    public func export(session: ProfilingSession) -> String {
        let rows = session.samples.map { row(for: $0, environment: session.environment) }
        return ([Self.headers.joined(separator: ",")] + rows).joined(separator: "\n")
    }

    private func row(for sample: ProfilingSample,
                     environment: ProfilingEnvironment) -> String {
        let context = sample.viewportContext
        let values = [
            Self.format(sample.timestamp),
            sample.stageType.rawValue,
            Self.format(sample.cpuTimeMilliseconds),
            sample.gpuTimeMilliseconds.map(Self.format) ?? "",
            sample.memoryEstimateBytes.map(String.init) ?? "",
            Self.resolution(context),
            context.viewportType,
            context.quality,
            context.renderMode,
            environment.deviceName,
            environment.osVersion,
            environment.gpuFamily,
            String(environment.maxThreadsPerThreadgroupDimensions.width),
            String(environment.maxThreadsPerThreadgroupDimensions.height),
            String(environment.maxThreadsPerThreadgroupDimensions.depth),
            String(environment.recommendedMaxWorkingSetSize),
            environment.appVersion,
            environment.buildNumber,
            Self.format(metadata: sample.metadata)
        ]
        return values.map(Self.escapeCSV).joined(separator: ",")
    }

    private static func resolution(_ context: ProfilingViewportContext) -> String {
        guard context.resolutionWidth > 0, context.resolutionHeight > 0 else {
            return ""
        }
        return "\(context.resolutionWidth)x\(context.resolutionHeight)"
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func format(metadata: [String: String]?) -> String {
        guard let metadata, !metadata.isEmpty else {
            return ""
        }

        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return metadata.keys.sorted().map { key in
                "\(key)=\(metadata[key] ?? "")"
            }.joined(separator: ";")
        }

        return string
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
