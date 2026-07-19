//
//  ClinicalBenchmarkReport.swift
//  MTK
//
//  Reproducible clinical benchmark scenario manifest and report export.
//

import Foundation

public struct ClinicalBenchmarkScenario: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var volumeDescription: String
    public var viewportLayout: String
    public var benchmarkMode: String
    public var expectedLimit: String
    public var notes: String
    public var requiredStages: [ProfilingStage]

    public init(id: String,
                name: String,
                category: String,
                volumeDescription: String,
                viewportLayout: String,
                benchmarkMode: String,
                expectedLimit: String,
                notes: String,
                requiredStages: [ProfilingStage]) {
        self.id = id
        self.name = name
        self.category = category
        self.volumeDescription = volumeDescription
        self.viewportLayout = viewportLayout
        self.benchmarkMode = benchmarkMode
        self.expectedLimit = expectedLimit
        self.notes = notes
        self.requiredStages = requiredStages
    }
}

public enum ClinicalBenchmarkMeasurementStatus: String, Codable, Sendable {
    case measured
    case notRun
}

public enum ClinicalBenchmarkVerdict: String, Codable, Comparable, Sendable {
    case notEvaluated
    case pass
    case warning
    case failure

    public static func < (lhs: ClinicalBenchmarkVerdict,
                          rhs: ClinicalBenchmarkVerdict) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ verdict: ClinicalBenchmarkVerdict) -> Int {
        switch verdict {
        case .notEvaluated: return -1
        case .pass: return 0
        case .warning: return 1
        case .failure: return 2
        }
    }
}

public struct ClinicalBenchmarkWorkMeasurement: Codable, Equatable, Sendable {
    public var usefulBytes: Int
    public var cachedBytes: Int
    public var duplicatedBytes: Int
    public var staleBytes: Int
    public var discardedBytes: Int
    public var bytesAvoided: Int
    public var pixelsAvoided: Int
    public var cacheHits: Int
    public var cacheMisses: Int
    public var provisionalToFinalTransitions: Int
}

public struct ClinicalBenchmarkResourceMeasurement: Codable, Equatable, Sendable {
    public var peakRSSBytes: Int?
    public var residentDeltaBytes: Int?
    public var metalAllocatedBytes: Int?
    public var metalLeasedBytes: Int?
    public var metalReclaimableBytes: Int?
    public var metalPeakBytes: Int?
    public var newBufferCount: Int?
    public var reusedBufferCount: Int?
    public var newTextureCount: Int?
    public var reusedTextureCount: Int?
    public var cpuCopyCount: Int?
    public var gpuCopyCount: Int?
    public var temporaryFileIOBytes: Int?
    public var commandBufferDurationMilliseconds: Double?
    public var commandBufferFailureCount: Int?
    public var energyImpact: Double?
    public var thermalState: String?
}

public struct ClinicalBenchmarkMeasurement: Codable, Equatable, Sendable {
    public var scenarioID: String
    public var status: ClinicalBenchmarkMeasurementStatus
    public var sampleCount: Int
    public var totalCPUTimeMilliseconds: Double
    public var totalGPUTimeMilliseconds: Double?
    public var peakMemoryBytes: Int?
    public var stageMeasurements: [ClinicalBenchmarkStageMeasurement]
    public var peakVolumeTextureCount: Int?
    public var peakTransferTextureCount: Int?
    public var peakOutputTexturePoolSize: Int?
    public var volumeLayerCount: Int?
    public var surfaceLayerCount: Int?
    public var observedViewportTypes: [String]
    public var observedRenderModes: [String]
    public var work: ClinicalBenchmarkWorkMeasurement?
    public var resources: ClinicalBenchmarkResourceMeasurement?
    public var correctnessPassed: Bool?
    public var baselineDeltaPercent: Double?
    public var verdict: ClinicalBenchmarkVerdict
    public var verdictReason: String?

    public init(scenarioID: String,
                status: ClinicalBenchmarkMeasurementStatus,
                sampleCount: Int = 0,
                totalCPUTimeMilliseconds: Double = 0,
                totalGPUTimeMilliseconds: Double? = nil,
                peakMemoryBytes: Int? = nil,
                stageMeasurements: [ClinicalBenchmarkStageMeasurement] = [],
                peakVolumeTextureCount: Int? = nil,
                peakTransferTextureCount: Int? = nil,
                peakOutputTexturePoolSize: Int? = nil,
                volumeLayerCount: Int? = nil,
                surfaceLayerCount: Int? = nil,
                observedViewportTypes: [String] = [],
                observedRenderModes: [String] = [],
                work: ClinicalBenchmarkWorkMeasurement? = nil,
                resources: ClinicalBenchmarkResourceMeasurement? = nil,
                correctnessPassed: Bool? = nil,
                baselineDeltaPercent: Double? = nil,
                verdict: ClinicalBenchmarkVerdict = .notEvaluated,
                verdictReason: String? = nil) {
        self.scenarioID = scenarioID
        self.status = status
        self.sampleCount = sampleCount
        self.totalCPUTimeMilliseconds = totalCPUTimeMilliseconds
        self.totalGPUTimeMilliseconds = totalGPUTimeMilliseconds
        self.peakMemoryBytes = peakMemoryBytes
        self.stageMeasurements = stageMeasurements
        self.peakVolumeTextureCount = peakVolumeTextureCount
        self.peakTransferTextureCount = peakTransferTextureCount
        self.peakOutputTexturePoolSize = peakOutputTexturePoolSize
        self.volumeLayerCount = volumeLayerCount
        self.surfaceLayerCount = surfaceLayerCount
        self.observedViewportTypes = observedViewportTypes
        self.observedRenderModes = observedRenderModes
        self.work = work
        self.resources = resources
        self.correctnessPassed = correctnessPassed
        self.baselineDeltaPercent = baselineDeltaPercent
        self.verdict = verdict
        self.verdictReason = verdictReason
    }

    private enum CodingKeys: String, CodingKey {
        case scenarioID
        case status
        case sampleCount
        case totalCPUTimeMilliseconds
        case totalGPUTimeMilliseconds
        case peakMemoryBytes
        case stageMeasurements
        case peakVolumeTextureCount
        case peakTransferTextureCount
        case peakOutputTexturePoolSize
        case volumeLayerCount
        case surfaceLayerCount
        case observedViewportTypes
        case observedRenderModes
        case work
        case resources
        case correctnessPassed
        case baselineDeltaPercent
        case verdict
        case verdictReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.scenarioID = try container.decode(String.self, forKey: .scenarioID)
        self.status = try container.decode(ClinicalBenchmarkMeasurementStatus.self, forKey: .status)
        self.sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        self.totalCPUTimeMilliseconds = try container.decode(Double.self, forKey: .totalCPUTimeMilliseconds)
        self.totalGPUTimeMilliseconds = try container.decodeIfPresent(Double.self, forKey: .totalGPUTimeMilliseconds)
        self.peakMemoryBytes = try container.decodeIfPresent(Int.self, forKey: .peakMemoryBytes)
        self.stageMeasurements = try container.decodeIfPresent([ClinicalBenchmarkStageMeasurement].self,
                                                               forKey: .stageMeasurements) ?? []
        self.peakVolumeTextureCount = try container.decodeIfPresent(Int.self, forKey: .peakVolumeTextureCount)
        self.peakTransferTextureCount = try container.decodeIfPresent(Int.self, forKey: .peakTransferTextureCount)
        self.peakOutputTexturePoolSize = try container.decodeIfPresent(Int.self, forKey: .peakOutputTexturePoolSize)
        self.volumeLayerCount = try container.decodeIfPresent(Int.self, forKey: .volumeLayerCount)
        self.surfaceLayerCount = try container.decodeIfPresent(Int.self, forKey: .surfaceLayerCount)
        self.observedViewportTypes = try container.decode([String].self, forKey: .observedViewportTypes)
        self.observedRenderModes = try container.decode([String].self, forKey: .observedRenderModes)
        self.work = try container.decodeIfPresent(ClinicalBenchmarkWorkMeasurement.self, forKey: .work)
        self.resources = try container.decodeIfPresent(ClinicalBenchmarkResourceMeasurement.self, forKey: .resources)
        self.correctnessPassed = try container.decodeIfPresent(Bool.self, forKey: .correctnessPassed)
        self.baselineDeltaPercent = try container.decodeIfPresent(Double.self, forKey: .baselineDeltaPercent)
        self.verdict = try container.decodeIfPresent(ClinicalBenchmarkVerdict.self, forKey: .verdict) ?? .notEvaluated
        self.verdictReason = try container.decodeIfPresent(String.self, forKey: .verdictReason)
    }
}

public struct ClinicalBenchmarkStageMeasurement: Codable, Equatable, Sendable {
    public var stage: ProfilingStage
    public var sampleCount: Int
    public var cpuTimeMilliseconds: Double
    public var gpuTimeMilliseconds: Double?
    public var peakMemoryBytes: Int?
    public var meanCPUTimeMilliseconds: Double
    public var standardDeviationCPUTimeMilliseconds: Double
    public var coefficientOfVariationPercent: Double
    public var p50CPUTimeMilliseconds: Double
    public var p95CPUTimeMilliseconds: Double
    public var p99CPUTimeMilliseconds: Double

    public init(stage: ProfilingStage,
                sampleCount: Int,
                cpuTimeMilliseconds: Double,
                gpuTimeMilliseconds: Double? = nil,
                peakMemoryBytes: Int? = nil,
                meanCPUTimeMilliseconds: Double? = nil,
                standardDeviationCPUTimeMilliseconds: Double = 0,
                coefficientOfVariationPercent: Double = 0,
                p50CPUTimeMilliseconds: Double? = nil,
                p95CPUTimeMilliseconds: Double? = nil,
                p99CPUTimeMilliseconds: Double? = nil) {
        self.stage = stage
        self.sampleCount = sampleCount
        self.cpuTimeMilliseconds = cpuTimeMilliseconds
        self.gpuTimeMilliseconds = gpuTimeMilliseconds
        self.peakMemoryBytes = peakMemoryBytes
        let fallbackMean = sampleCount > 0 ? cpuTimeMilliseconds / Double(sampleCount) : 0
        self.meanCPUTimeMilliseconds = meanCPUTimeMilliseconds ?? fallbackMean
        self.standardDeviationCPUTimeMilliseconds = standardDeviationCPUTimeMilliseconds
        self.coefficientOfVariationPercent = coefficientOfVariationPercent
        self.p50CPUTimeMilliseconds = p50CPUTimeMilliseconds ?? fallbackMean
        self.p95CPUTimeMilliseconds = p95CPUTimeMilliseconds ?? fallbackMean
        self.p99CPUTimeMilliseconds = p99CPUTimeMilliseconds ?? fallbackMean
    }

    private enum CodingKeys: String, CodingKey {
        case stage
        case sampleCount
        case cpuTimeMilliseconds
        case gpuTimeMilliseconds
        case peakMemoryBytes
        case meanCPUTimeMilliseconds
        case standardDeviationCPUTimeMilliseconds
        case coefficientOfVariationPercent
        case p50CPUTimeMilliseconds
        case p95CPUTimeMilliseconds
        case p99CPUTimeMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(ProfilingStage.self, forKey: .stage)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        cpuTimeMilliseconds = try container.decode(Double.self, forKey: .cpuTimeMilliseconds)
        gpuTimeMilliseconds = try container.decodeIfPresent(Double.self, forKey: .gpuTimeMilliseconds)
        peakMemoryBytes = try container.decodeIfPresent(Int.self, forKey: .peakMemoryBytes)
        let fallbackMean = sampleCount > 0 ? cpuTimeMilliseconds / Double(sampleCount) : 0
        meanCPUTimeMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .meanCPUTimeMilliseconds
        ) ?? fallbackMean
        standardDeviationCPUTimeMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .standardDeviationCPUTimeMilliseconds
        ) ?? 0
        coefficientOfVariationPercent = try container.decodeIfPresent(
            Double.self,
            forKey: .coefficientOfVariationPercent
        ) ?? 0
        p50CPUTimeMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .p50CPUTimeMilliseconds
        ) ?? fallbackMean
        p95CPUTimeMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .p95CPUTimeMilliseconds
        ) ?? fallbackMean
        p99CPUTimeMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .p99CPUTimeMilliseconds
        ) ?? fallbackMean
    }
}

public struct ClinicalBenchmarkReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var environment: ProfilingEnvironment
    public var scenarios: [ClinicalBenchmarkScenario]
    public var measurements: [ClinicalBenchmarkMeasurement]
    public var metadata: [String: String]
    public var verdict: ClinicalBenchmarkVerdict

    public init(schemaVersion: Int = 2,
                generatedAt: Date = Date(),
                environment: ProfilingEnvironment,
                scenarios: [ClinicalBenchmarkScenario],
                measurements: [ClinicalBenchmarkMeasurement],
                metadata: [String: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.scenarios = scenarios
        self.measurements = measurements
        self.metadata = metadata
        self.verdict = measurements.map(\.verdict).max() ?? .notEvaluated
    }
}

public extension ClinicalBenchmarkReport {
    static let csvHeaders: [String] = [
        "scenarioID",
        "name",
        "status",
        "sampleCount",
        "totalCPUTimeMs",
        "totalGPUTimeMs",
        "peakMemoryBytes",
        "peakVolumeTextureCount",
        "peakTransferTextureCount",
        "peakOutputTexturePoolSize",
        "volumeLayerCount",
        "surfaceLayerCount",
        "viewportTypes",
        "renderModes",
        "volumeDescription",
        "viewportLayout",
        "scenarioMode",
        "expectedLimit",
        "deviceName",
        "osVersion",
        "architecture",
        "modelIdentifier",
        "buildConfiguration",
        "benchmarkMode",
        "tier",
        "commandLineStartupIncluded",
        "gpuFamily",
        "correctnessPassed",
        "baselineDeltaPercent",
        "verdict",
        "verdictReason",
        "workMetrics",
        "resourceMetrics",
        "stageBreakdown",
        "metadata"
    ]

    func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    func jsonString(prettyPrinted: Bool = true) throws -> String {
        String(decoding: try jsonData(prettyPrinted: prettyPrinted), as: UTF8.self)
    }

    func csvData() -> Data {
        Data(csvString().utf8)
    }

    func csvString() -> String {
        let scenariosByID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        let rows = measurements.map { measurement -> String in
            let scenario = scenariosByID[measurement.scenarioID]
            let totalGPUTime = measurement.totalGPUTimeMilliseconds.map(Self.format) ?? ""
            let peakMemoryBytes = measurement.peakMemoryBytes.map(String.init) ?? ""
            let peakVolumeTextureCount = measurement.peakVolumeTextureCount.map(String.init) ?? ""
            let peakTransferTextureCount = measurement.peakTransferTextureCount.map(String.init) ?? ""
            let peakOutputTexturePoolSize = measurement.peakOutputTexturePoolSize.map(String.init) ?? ""
            let volumeLayerCount = measurement.volumeLayerCount.map(String.init) ?? ""
            let surfaceLayerCount = measurement.surfaceLayerCount.map(String.init) ?? ""
            let values: [String] = [
                measurement.scenarioID,
                scenario?.name ?? "",
                measurement.status.rawValue,
                String(measurement.sampleCount),
                Self.format(measurement.totalCPUTimeMilliseconds),
                totalGPUTime,
                peakMemoryBytes,
                peakVolumeTextureCount,
                peakTransferTextureCount,
                peakOutputTexturePoolSize,
                volumeLayerCount,
                surfaceLayerCount,
                measurement.observedViewportTypes.joined(separator: "|"),
                measurement.observedRenderModes.joined(separator: "|"),
                scenario?.volumeDescription ?? "",
                scenario?.viewportLayout ?? "",
                scenario?.benchmarkMode ?? "",
                scenario?.expectedLimit ?? "",
                environment.deviceName,
                environment.osVersion,
                environment.architecture,
                environment.modelIdentifier,
                environment.buildConfiguration,
                environment.benchmarkMode,
                environment.tier,
                String(environment.commandLineStartupIncluded),
                environment.gpuFamily,
                measurement.correctnessPassed.map(String.init) ?? "",
                measurement.baselineDeltaPercent.map(Self.format) ?? "",
                measurement.verdict.rawValue,
                measurement.verdictReason ?? "",
                Self.format(work: measurement.work),
                Self.format(resources: measurement.resources),
                Self.format(stageMeasurements: measurement.stageMeasurements),
                Self.format(metadata: metadata)
            ]
            return values.map(Self.escapeCSV).joined(separator: ",")
        }
        return ([Self.csvHeaders.joined(separator: ",")] + rows).joined(separator: "\n")
    }

    func markdownData() -> Data {
        Data(markdownString().utf8)
    }

    func markdownString() -> String {
        let scenariosByID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        var lines = [
            "# MTK Clinical Performance Report",
            "",
            "- **Verdict**: \(verdict.rawValue)",
            "- **Device**: \(environment.deviceName)",
            "- **OS / architecture**: \(environment.osVersion) / \(environment.architecture)",
            "- **Build / tier**: \(environment.buildConfiguration) / \(environment.tier)",
            "- **Mode / fixture**: \(environment.benchmarkMode) / \(environment.fixtureID)",
            "- **CLI startup included**: \(environment.commandLineStartupIncluded)",
            "",
            "| Scenario | Samples | CPU total | Peak RSS / Metal | P50 / P95 / P99 stages | Baseline delta | Verdict |",
            "|---|---:|---:|---:|---|---:|---|"
        ]
        for measurement in measurements {
            let scenarioName = scenariosByID[measurement.scenarioID]?.name ?? measurement.scenarioID
            let stagePercentiles = measurement.stageMeasurements.map {
                "\($0.stage.rawValue): \(Self.format($0.p50CPUTimeMilliseconds))/"
                    + "\(Self.format($0.p95CPUTimeMilliseconds))/"
                    + "\(Self.format($0.p99CPUTimeMilliseconds)) ms"
            }.joined(separator: "<br>")
            let peakMetal = measurement.resources?.metalPeakBytes.map(String.init) ?? "n/a"
            let peakMemory = measurement.peakMemoryBytes.map(String.init) ?? "n/a"
            let baselineDelta = measurement.baselineDeltaPercent.map { Self.format($0) + "%" } ?? "n/a"
            let row = "| \(scenarioName) | \(measurement.sampleCount) | "
                + "\(Self.format(measurement.totalCPUTimeMilliseconds)) ms | "
                + "\(peakMemory) / \(peakMetal) B | \(stagePercentiles) | "
                + "\(baselineDelta) | \(measurement.verdict.rawValue) |"
            lines.append(row)
        }
        lines.append("")
        lines.append(
            "Correctness is a prerequisite for performance qualification; "
                + "faster incorrect output cannot select the default backend."
        )
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func format(metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return "" }
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return metadata.keys.sorted().map { key in
                "\(key)=\(metadata[key] ?? "")"
            }.joined(separator: ";")
        }
        return string
    }

    private static func format(work: ClinicalBenchmarkWorkMeasurement?) -> String {
        guard let work else { return "" }
        return [
            "useful=\(work.usefulBytes)",
            "cached=\(work.cachedBytes)",
            "duplicated=\(work.duplicatedBytes)",
            "stale=\(work.staleBytes)",
            "discarded=\(work.discardedBytes)",
            "bytesAvoided=\(work.bytesAvoided)",
            "pixelsAvoided=\(work.pixelsAvoided)",
            "cacheHits=\(work.cacheHits)",
            "cacheMisses=\(work.cacheMisses)",
            "previewFinal=\(work.provisionalToFinalTransitions)"
        ].joined(separator: ";")
    }

    private static func format(resources: ClinicalBenchmarkResourceMeasurement?) -> String {
        guard let resources else { return "" }
        return [
            "metalAllocated=\(resources.metalAllocatedBytes.map(String.init) ?? "")",
            "metalLeased=\(resources.metalLeasedBytes.map(String.init) ?? "")",
            "metalReclaimable=\(resources.metalReclaimableBytes.map(String.init) ?? "")",
            "metalPeak=\(resources.metalPeakBytes.map(String.init) ?? "")",
            "buffersNew=\(resources.newBufferCount.map(String.init) ?? "")",
            "buffersReused=\(resources.reusedBufferCount.map(String.init) ?? "")",
            "texturesNew=\(resources.newTextureCount.map(String.init) ?? "")",
            "texturesReused=\(resources.reusedTextureCount.map(String.init) ?? "")",
            "cpuCopies=\(resources.cpuCopyCount.map(String.init) ?? "")",
            "gpuCopies=\(resources.gpuCopyCount.map(String.init) ?? "")",
            "temporaryIO=\(resources.temporaryFileIOBytes.map(String.init) ?? "")",
            "peakRSS=\(resources.peakRSSBytes.map(String.init) ?? "")",
            "residentDelta=\(resources.residentDeltaBytes.map(String.init) ?? "")",
            "commandBufferDuration=\(resources.commandBufferDurationMilliseconds.map { format($0) } ?? "")",
            "commandBufferFailures=\(resources.commandBufferFailureCount.map(String.init) ?? "")",
            "energyImpact=\(resources.energyImpact.map { format($0) } ?? "")",
            "thermalState=\(resources.thermalState ?? "")"
        ].joined(separator: ";")
    }

    private static func format(stageMeasurements: [ClinicalBenchmarkStageMeasurement]) -> String {
        stageMeasurements.map { measurement in
            let gpu = measurement.gpuTimeMilliseconds.map { "gpu=\(format($0))" } ?? "gpu="
            let memory = measurement.peakMemoryBytes.map { "mem=\($0)" } ?? "mem="
            return [
                "\(measurement.stage.rawValue):samples=\(measurement.sampleCount)",
                "cpu=\(format(measurement.cpuTimeMilliseconds))",
                "mean=\(format(measurement.meanCPUTimeMilliseconds))",
                "stddev=\(format(measurement.standardDeviationCPUTimeMilliseconds))",
                "cv=\(format(measurement.coefficientOfVariationPercent))",
                "p50=\(format(measurement.p50CPUTimeMilliseconds))",
                "p95=\(format(measurement.p95CPUTimeMilliseconds))",
                "p99=\(format(measurement.p99CPUTimeMilliseconds))",
                gpu,
                memory
            ].joined(separator: ";")
        }.joined(separator: "|")
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public enum ClinicalBenchmarkSuite {
    public static let representativeScenarios: [ClinicalBenchmarkScenario] = [
        ClinicalBenchmarkScenario(
            id: "ct-multi-viewport",
            name: "CT axial/coronal/sagittal/3D",
            category: "multi-viewport",
            volumeDescription: "Clinical target: CT 512x512x300 int16 HU; CI scale may use a smaller deterministic fixture.",
            viewportLayout: "axial, coronal, sagittal, volume3D",
            benchmarkMode: "shared volume texture across four viewports",
            expectedLimit: "one shared volume texture with four viewport references; no duplicate primary volume uploads",
            notes: "Baseline scenario for resource sharing, frame timing, and memory snapshots.",
            requiredStages: [.textureUpload, .mprReslice, .volumeRaycast, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "mip-slab-thick",
            name: "Interactive thick MIP slab",
            category: "mpr",
            volumeDescription: "CT slab navigation over the same shared dataset.",
            viewportLayout: "MPR slab viewport",
            benchmarkMode: "MIP slab with increased slab thickness and steps",
            expectedLimit: "records slab thickness and step count without allocating duplicate volume textures",
            notes: "Used to compare interactive slab cost against single-slice MPR.",
            requiredStages: [.mprReslice, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "dvr-1d-transfer",
            name: "3D DVR with 1D transfer function",
            category: "volume3D",
            volumeDescription: "CT DVR using a 1D opacity/color transfer function.",
            viewportLayout: "volume3D",
            benchmarkMode: "front-to-back DVR",
            expectedLimit: "records raycast timing, transfer texture count, and output-pool reuse",
            notes: "Primary direct volume rendering benchmark.",
            requiredStages: [.texturePreparation, .volumeRaycast, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "dvr-2d-gradient",
            name: "3D DVR with 2D gradient opacity",
            category: "volume3D",
            volumeDescription: "CT DVR using intensity plus gradient-opacity transfer data.",
            viewportLayout: "volume3D",
            benchmarkMode: "front-to-back DVR with gradient opacity",
            expectedLimit: "documents additional transfer preparation cost separately from raycast cost",
            notes: "Captures the expected extra cost before optimizing gradient workflows.",
            requiredStages: [.texturePreparation, .volumeRaycast, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "ct-pet-overlay",
            name: "CT plus PET-like scalar overlay",
            category: "multi-volume",
            volumeDescription: "Registered CT base plus additive scalar overlay.",
            viewportLayout: "volume3D with volume layer",
            benchmarkMode: "scalar volume layer compositing",
            expectedLimit: "records volumeLayerCount separately from primary volume texture count",
            notes: "Represents CT+PET, dose, or registered scalar overlay workflows.",
            requiredStages: [.textureUpload, .volumeRaycast, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "volume-surface-segmentation",
            name: "Volume plus surface segmentation",
            category: "segmentation",
            volumeDescription: "CT base volume with a surface mesh segmentation layer.",
            viewportLayout: "volume3D with surface layer",
            benchmarkMode: "surface layer rendering",
            expectedLimit: "records surfaceLayerCount separately from scalar volume layers",
            notes: "Measures mesh-overlay cost independently from scalar overlays.",
            requiredStages: [.volumeRaycast, .presentationPass, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "dataset-swap",
            name: "Rapid series replacement",
            category: "resource-lifecycle",
            volumeDescription: "Two CT-like volumes with identical geometry and different scalar data.",
            viewportLayout: "all active clinical viewports",
            benchmarkMode: "dataset replacement",
            expectedLimit: "old resource handle is released or recycled; active resource count stays bounded",
            notes: "Guards against stale texture retention during rapid series changes.",
            requiredStages: [.textureUpload, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "continuous-resize",
            name: "Continuous viewport resize",
            category: "resource-lifecycle",
            volumeDescription: "Shared volume with repeated viewport-size changes.",
            viewportLayout: "all active clinical viewports",
            benchmarkMode: "resize loop",
            expectedLimit: "output pool and estimated memory do not grow indefinitely",
            notes: "Covers split-view, rotation, and window-resize workflows.",
            requiredStages: [.mprReslice, .volumeRaycast, .memorySnapshot]
        ),
        ClinicalBenchmarkScenario(
            id: "snapshot-readback",
            name: "Explicit snapshot/export readback",
            category: "export",
            volumeDescription: "Rendered volume frame exported through the explicit readback boundary.",
            viewportLayout: "volume3D snapshot",
            benchmarkMode: "snapshot readback",
            expectedLimit: "records snapshotReadback separately from interactive presentation",
            notes: "Confirms CPU readback remains opt-in and measurable.",
            requiredStages: [.volumeRaycast, .snapshotReadback]
        ),
        ClinicalBenchmarkScenario(
            id: "empty-space-skipping-toggle",
            name: "Empty-space skipping on/off",
            category: "acceleration",
            volumeDescription: "Sparse CT-like volume with transparent air regions.",
            viewportLayout: "volume3D",
            benchmarkMode: "DVR with ESS enabled and disabled when available",
            expectedLimit: "documents availability and timing delta; skips unsupported MPS paths predictably",
            notes: "Used to measure the acceleration path without making support mandatory.",
            requiredStages: [.texturePreparation, .volumeRaycast, .memorySnapshot]
        )
    ]

    public static func makeReport(from session: ProfilingSession,
                                  scenarios: [ClinicalBenchmarkScenario] = representativeScenarios,
                                  generatedAt: Date = Date(),
                                  metadata: [String: String] = [:]) -> ClinicalBenchmarkReport {
        let samplesByScenario = Dictionary(grouping: session.samples) { sample in
            sample.metadata?["scenarioID"] ?? ""
        }
        let measurements = scenarios.map { scenario in
            Self.measurement(for: scenario, samples: samplesByScenario[scenario.id] ?? [])
        }
        return ClinicalBenchmarkReport(generatedAt: generatedAt,
                                       environment: session.environment,
                                       scenarios: scenarios,
                                       measurements: measurements,
                                       metadata: metadata)
    }

    private static func measurement(for scenario: ClinicalBenchmarkScenario,
                                    samples: [ProfilingSample]) -> ClinicalBenchmarkMeasurement {
        guard !samples.isEmpty else {
            return ClinicalBenchmarkMeasurement(scenarioID: scenario.id, status: .notRun)
        }

        let totalGPU = samples.compactMap(\.gpuTimeMilliseconds).reduce(0, +)
        return ClinicalBenchmarkMeasurement(
            scenarioID: scenario.id,
            status: .measured,
            sampleCount: samples.count,
            totalCPUTimeMilliseconds: samples.map(\.cpuTimeMilliseconds).reduce(0, +),
            totalGPUTimeMilliseconds: samples.contains { $0.gpuTimeMilliseconds != nil } ? totalGPU : nil,
            peakMemoryBytes: samples.compactMap(\.memoryEstimateBytes).max(),
            stageMeasurements: stageMeasurements(for: samples),
            peakVolumeTextureCount: maxMetadataInteger("volumeTextureCount", in: samples),
            peakTransferTextureCount: maxMetadataInteger("transferTextureCount", in: samples),
            peakOutputTexturePoolSize: maxMetadataInteger("outputTexturePoolSize", in: samples),
            volumeLayerCount: maxMetadataInteger("volumeLayerCount", in: samples),
            surfaceLayerCount: maxMetadataInteger("surfaceLayerCount", in: samples),
            observedViewportTypes: sortedUnique(samples.map(\.viewportContext.viewportType)),
            observedRenderModes: sortedUnique(samples.map(\.viewportContext.renderMode)),
            work: workMeasurement(for: samples),
            resources: resourceMeasurement(for: samples),
            correctnessPassed: correctnessVerdict(in: samples),
            baselineDeltaPercent: metadataDoubles("baselineDeltaPercent", in: samples).last,
            verdict: performanceVerdict(in: samples),
            verdictReason: samples.compactMap { $0.metadata?["verdictReason"] }.last
        )
    }

    private static func stageMeasurements(for samples: [ProfilingSample]) -> [ClinicalBenchmarkStageMeasurement] {
        Dictionary(grouping: samples, by: \.stageType)
            .map { stage, stageSamples in
                let totalGPU = stageSamples.compactMap(\.gpuTimeMilliseconds).reduce(0, +)
                let cpuSamples = stageSamples.map(\.cpuTimeMilliseconds)
                let mean = cpuSamples.reduce(0, +) / Double(cpuSamples.count)
                let standardDeviation: Double
                if cpuSamples.count > 1 {
                    let variance = cpuSamples.map { pow($0 - mean, 2) }.reduce(0, +)
                        / Double(cpuSamples.count - 1)
                    standardDeviation = sqrt(variance)
                } else {
                    standardDeviation = 0
                }
                return ClinicalBenchmarkStageMeasurement(
                    stage: stage,
                    sampleCount: stageSamples.count,
                    cpuTimeMilliseconds: stageSamples.map(\.cpuTimeMilliseconds).reduce(0, +),
                    gpuTimeMilliseconds: stageSamples.contains { $0.gpuTimeMilliseconds != nil } ? totalGPU : nil,
                    peakMemoryBytes: stageSamples.compactMap(\.memoryEstimateBytes).max(),
                    meanCPUTimeMilliseconds: mean,
                    standardDeviationCPUTimeMilliseconds: standardDeviation,
                    coefficientOfVariationPercent: mean > 0 ? standardDeviation / mean * 100 : 0,
                    p50CPUTimeMilliseconds: percentile(50, values: cpuSamples),
                    p95CPUTimeMilliseconds: percentile(95, values: cpuSamples),
                    p99CPUTimeMilliseconds: percentile(99, values: cpuSamples)
                )
            }
            .sorted { $0.stage.rawValue < $1.stage.rawValue }
    }

    private static func maxMetadataInteger(_ key: String,
                                           in samples: [ProfilingSample]) -> Int? {
        samples
            .compactMap { $0.metadata?[key] }
            .compactMap(Int.init)
            .max()
    }

    private static func sumMetadataInteger(_ key: String,
                                           in samples: [ProfilingSample]) -> Int {
        samples
            .compactMap { $0.metadata?[key] }
            .compactMap(Int.init)
            .reduce(0, +)
    }

    private static func sumMetadataIntegerIfPresent(_ key: String,
                                                    in samples: [ProfilingSample]) -> Int? {
        let values = samples
            .compactMap { $0.metadata?[key] }
            .compactMap(Int.init)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private static func metadataDoubles(_ key: String,
                                        in samples: [ProfilingSample]) -> [Double] {
        samples
            .compactMap { $0.metadata?[key] }
            .compactMap(Double.init)
    }

    private static func workMeasurement(for samples: [ProfilingSample]) -> ClinicalBenchmarkWorkMeasurement? {
        let keys = [
            "usefulBytes", "cachedBytes", "duplicatedBytes", "staleBytes", "discardedBytes",
            "bytesAvoided", "pixelsAvoided", "cacheHits", "cacheMisses", "provisionalToFinalTransitions"
        ]
        guard samples.contains(where: { sample in keys.contains(where: { sample.metadata?[$0] != nil }) }) else {
            return nil
        }
        return ClinicalBenchmarkWorkMeasurement(
            usefulBytes: sumMetadataInteger("usefulBytes", in: samples),
            cachedBytes: sumMetadataInteger("cachedBytes", in: samples),
            duplicatedBytes: sumMetadataInteger("duplicatedBytes", in: samples),
            staleBytes: sumMetadataInteger("staleBytes", in: samples),
            discardedBytes: sumMetadataInteger("discardedBytes", in: samples),
            bytesAvoided: sumMetadataInteger("bytesAvoided", in: samples),
            pixelsAvoided: sumMetadataInteger("pixelsAvoided", in: samples),
            cacheHits: sumMetadataInteger("cacheHits", in: samples),
            cacheMisses: sumMetadataInteger("cacheMisses", in: samples),
            provisionalToFinalTransitions: sumMetadataInteger("provisionalToFinalTransitions", in: samples)
        )
    }

    private static func resourceMeasurement(for samples: [ProfilingSample]) -> ClinicalBenchmarkResourceMeasurement? {
        let keys = [
            "peakRSSBytes", "residentDeltaBytes",
            "metalAllocatedBytes", "metalLeasedBytes", "metalReclaimableBytes", "metalPeakBytes",
            "newBufferCount", "reusedBufferCount", "newTextureCount", "reusedTextureCount",
            "cpuCopyCount", "gpuCopyCount", "temporaryFileIOBytes", "commandBufferDurationMilliseconds",
            "commandBufferFailureCount", "energyImpact", "thermalState"
        ]
        guard samples.contains(where: { sample in keys.contains(where: { sample.metadata?[$0] != nil }) }) else {
            return nil
        }
        return ClinicalBenchmarkResourceMeasurement(
            peakRSSBytes: maxMetadataInteger("peakRSSBytes", in: samples),
            residentDeltaBytes: maxMetadataInteger("residentDeltaBytes", in: samples),
            metalAllocatedBytes: maxMetadataInteger("metalAllocatedBytes", in: samples),
            metalLeasedBytes: maxMetadataInteger("metalLeasedBytes", in: samples),
            metalReclaimableBytes: maxMetadataInteger("metalReclaimableBytes", in: samples),
            metalPeakBytes: maxMetadataInteger("metalPeakBytes", in: samples),
            newBufferCount: sumMetadataIntegerIfPresent("newBufferCount", in: samples),
            reusedBufferCount: sumMetadataIntegerIfPresent("reusedBufferCount", in: samples),
            newTextureCount: sumMetadataIntegerIfPresent("newTextureCount", in: samples),
            reusedTextureCount: sumMetadataIntegerIfPresent("reusedTextureCount", in: samples),
            cpuCopyCount: sumMetadataIntegerIfPresent("cpuCopyCount", in: samples),
            gpuCopyCount: sumMetadataIntegerIfPresent("gpuCopyCount", in: samples),
            temporaryFileIOBytes: sumMetadataIntegerIfPresent("temporaryFileIOBytes", in: samples),
            commandBufferDurationMilliseconds: metadataDoubles(
                "commandBufferDurationMilliseconds",
                in: samples
            ).max(),
            commandBufferFailureCount: sumMetadataIntegerIfPresent("commandBufferFailureCount", in: samples),
            energyImpact: metadataDoubles("energyImpact", in: samples).last,
            thermalState: samples.compactMap { $0.metadata?["thermalState"] }.last
        )
    }

    private static func correctnessVerdict(in samples: [ProfilingSample]) -> Bool? {
        let values = samples.compactMap { sample -> Bool? in
            guard let value = sample.metadata?["correctnessPassed"] else { return nil }
            return Bool(value)
        }
        return values.isEmpty ? nil : values.allSatisfy { $0 }
    }

    private static func performanceVerdict(in samples: [ProfilingSample]) -> ClinicalBenchmarkVerdict {
        samples
            .compactMap { $0.metadata?["verdict"] }
            .compactMap(ClinicalBenchmarkVerdict.init(rawValue:))
            .max() ?? .notEvaluated
    }

    private static func percentile(_ percentile: Double,
                                   values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(ceil(percentile / 100 * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
