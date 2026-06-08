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
                observedRenderModes: [String] = []) {
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
    }
}

public struct ClinicalBenchmarkStageMeasurement: Codable, Equatable, Sendable {
    public var stage: ProfilingStage
    public var sampleCount: Int
    public var cpuTimeMilliseconds: Double
    public var gpuTimeMilliseconds: Double?
    public var peakMemoryBytes: Int?

    public init(stage: ProfilingStage,
                sampleCount: Int,
                cpuTimeMilliseconds: Double,
                gpuTimeMilliseconds: Double? = nil,
                peakMemoryBytes: Int? = nil) {
        self.stage = stage
        self.sampleCount = sampleCount
        self.cpuTimeMilliseconds = cpuTimeMilliseconds
        self.gpuTimeMilliseconds = gpuTimeMilliseconds
        self.peakMemoryBytes = peakMemoryBytes
    }
}

public struct ClinicalBenchmarkReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var environment: ProfilingEnvironment
    public var scenarios: [ClinicalBenchmarkScenario]
    public var measurements: [ClinicalBenchmarkMeasurement]
    public var metadata: [String: String]

    public init(generatedAt: Date = Date(),
                environment: ProfilingEnvironment,
                scenarios: [ClinicalBenchmarkScenario],
                measurements: [ClinicalBenchmarkMeasurement],
                metadata: [String: String] = [:]) {
        self.generatedAt = generatedAt
        self.environment = environment
        self.scenarios = scenarios
        self.measurements = measurements
        self.metadata = metadata
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
        "benchmarkMode",
        "expectedLimit",
        "deviceName",
        "osVersion",
        "gpuFamily",
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
                environment.gpuFamily,
                Self.format(stageMeasurements: measurement.stageMeasurements),
                Self.format(metadata: metadata)
            ]
            return values.map(Self.escapeCSV).joined(separator: ",")
        }
        return ([Self.csvHeaders.joined(separator: ",")] + rows).joined(separator: "\n")
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

    private static func format(stageMeasurements: [ClinicalBenchmarkStageMeasurement]) -> String {
        stageMeasurements.map { measurement in
            let gpu = measurement.gpuTimeMilliseconds.map { "gpu=\(format($0))" } ?? "gpu="
            let memory = measurement.peakMemoryBytes.map { "mem=\($0)" } ?? "mem="
            return "\(measurement.stage.rawValue):samples=\(measurement.sampleCount);cpu=\(format(measurement.cpuTimeMilliseconds));\(gpu);\(memory)"
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
            observedRenderModes: sortedUnique(samples.map(\.viewportContext.renderMode))
        )
    }

    private static func stageMeasurements(for samples: [ProfilingSample]) -> [ClinicalBenchmarkStageMeasurement] {
        Dictionary(grouping: samples, by: \.stageType)
            .map { stage, stageSamples in
                let totalGPU = stageSamples.compactMap(\.gpuTimeMilliseconds).reduce(0, +)
                return ClinicalBenchmarkStageMeasurement(
                    stage: stage,
                    sampleCount: stageSamples.count,
                    cpuTimeMilliseconds: stageSamples.map(\.cpuTimeMilliseconds).reduce(0, +),
                    gpuTimeMilliseconds: stageSamples.contains { $0.gpuTimeMilliseconds != nil } ? totalGPU : nil,
                    peakMemoryBytes: stageSamples.compactMap(\.memoryEstimateBytes).max()
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

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
