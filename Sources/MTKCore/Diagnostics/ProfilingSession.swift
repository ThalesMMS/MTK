//
//  ProfilingSession.swift
//  MTK
//
//  Clinical profiling sessions and export helpers.
//

import Foundation

public struct ProfilingSession: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var startTimestamp: Date
    public var endTimestamp: Date?
    public var environment: ProfilingEnvironment
    public var samples: [ProfilingSample]

    public init(sessionID: UUID = UUID(),
                startTimestamp: Date = Date(),
                endTimestamp: Date? = nil,
                environment: ProfilingEnvironment,
                samples: [ProfilingSample] = []) {
        self.sessionID = sessionID
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.environment = environment
        self.samples = samples
    }

    public mutating func addSample(_ sample: ProfilingSample) {
        samples.append(sample)
    }

    public mutating func finalize() {
        endTimestamp = Date()
    }
}

public extension ProfilingSession {
    static let csvHeaders: [String] = ProfilingCSVExporter.headers

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func jsonData(prettyPrinted: Bool = true) throws -> Data {
        guard prettyPrinted else {
            let encoder = JSONEncoder()
            let formatter = ISO8601DateFormatter()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
            return try encoder.encode(self)
        }
        return try exportJSON()
    }

    func jsonString(prettyPrinted: Bool = true) throws -> String {
        let data = try jsonData(prettyPrinted: prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }

    func csvData() -> Data {
        Data(csvString().utf8)
    }

    func csvString() -> String {
        ProfilingCSVExporter().export(session: self)
    }
}
