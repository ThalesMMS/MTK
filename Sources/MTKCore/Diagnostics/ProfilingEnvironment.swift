//
//  ProfilingEnvironment.swift
//  MTK
//
//  Device and process context for clinical profiling sessions.
//

import Foundation
@preconcurrency import Metal
#if canImport(Darwin)
import Darwin
#endif

public struct ProfilingThreadgroupDimensions: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct ProfilingEnvironment: Codable, Equatable, Sendable {
    public var deviceName: String
    public var osVersion: String
    public var gpuFamily: String
    public var maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions
    public var recommendedMaxWorkingSetSize: UInt64
    public var appVersion: String
    public var buildNumber: String
    public var architecture: String
    public var modelIdentifier: String
    public var buildConfiguration: String
    public var benchmarkMode: String
    public var fixtureID: String
    public var tier: String
    public var commandLineStartupIncluded: Bool

    public init(deviceName: String,
                osVersion: String,
                gpuFamily: String,
                maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions,
                recommendedMaxWorkingSetSize: UInt64,
                appVersion: String,
                buildNumber: String,
                architecture: String? = nil,
                modelIdentifier: String = "unknown",
                buildConfiguration: String? = nil,
                benchmarkMode: String = "unspecified",
                fixtureID: String = "unspecified",
                tier: String = "unspecified",
                commandLineStartupIncluded: Bool = false) {
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.gpuFamily = gpuFamily
        self.maxThreadsPerThreadgroupDimensions = maxThreadsPerThreadgroupDimensions
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.architecture = architecture ?? Self.currentArchitecture
        self.modelIdentifier = modelIdentifier
        self.buildConfiguration = buildConfiguration ?? Self.currentBuildConfiguration
        self.benchmarkMode = benchmarkMode
        self.fixtureID = fixtureID
        self.tier = tier
        self.commandLineStartupIncluded = commandLineStartupIncluded
    }

    public static func current(device: any MTLDevice,
                               bundle: Bundle = .main) -> ProfilingEnvironment {
        let maxThreads = device.maxThreadsPerThreadgroup
        return ProfilingEnvironment(
            deviceName: device.name,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            gpuFamily: Self.gpuFamilyDescription(for: device),
            maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions(
                width: maxThreads.width,
                height: maxThreads.height,
                depth: maxThreads.depth
            ),
            recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            modelIdentifier: Self.hardwareModelIdentifier(fallback: device.name)
        )
    }

    public static let unknown = ProfilingEnvironment(
        deviceName: "unknown",
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        gpuFamily: "unknown",
        maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions(width: 0, height: 0, depth: 0),
        recommendedMaxWorkingSetSize: 0,
        appVersion: "unknown",
        buildNumber: "unknown"
    )

    private enum CodingKeys: String, CodingKey {
        case deviceName
        case osVersion
        case gpuFamily
        case maxThreadsPerThreadgroupDimensions
        case recommendedMaxWorkingSetSize
        case appVersion
        case buildNumber
        case architecture
        case modelIdentifier
        case buildConfiguration
        case benchmarkMode
        case fixtureID
        case tier
        case commandLineStartupIncluded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        gpuFamily = try container.decode(String.self, forKey: .gpuFamily)
        maxThreadsPerThreadgroupDimensions = try container.decode(
            ProfilingThreadgroupDimensions.self,
            forKey: .maxThreadsPerThreadgroupDimensions
        )
        recommendedMaxWorkingSetSize = try container.decode(UInt64.self, forKey: .recommendedMaxWorkingSetSize)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture) ?? "unknown"
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier) ?? "unknown"
        buildConfiguration = try container.decodeIfPresent(String.self, forKey: .buildConfiguration) ?? "unknown"
        benchmarkMode = try container.decodeIfPresent(String.self, forKey: .benchmarkMode) ?? "unspecified"
        fixtureID = try container.decodeIfPresent(String.self, forKey: .fixtureID) ?? "unspecified"
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unspecified"
        commandLineStartupIncluded = try container.decodeIfPresent(
            Bool.self,
            forKey: .commandLineStartupIncluded
        ) ?? false
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static var currentBuildConfiguration: String {
#if DEBUG
        "debug"
#else
        "release"
#endif
    }

    private static func hardwareModelIdentifier(fallback: String) -> String {
#if canImport(Darwin)
        for key in ["hw.model", "hw.machine"] {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { continue }
            let identifier = String(cString: value)
            if !identifier.isEmpty { return identifier }
        }
#endif
        return fallback
    }

    private static func gpuFamilyDescription(for device: any MTLDevice) -> String {
        if device.supportsFamily(.apple10) { return "apple10" }
        if device.supportsFamily(.apple9) { return "apple9" }
        if device.supportsFamily(.apple8) { return "apple8" }
        if device.supportsFamily(.apple7) { return "apple7" }
        if device.supportsFamily(.apple6) { return "apple6" }
        if device.supportsFamily(.apple5) { return "apple5" }
        if device.supportsFamily(.apple4) { return "apple4" }
        if device.supportsFamily(.apple3) { return "apple3" }
        if device.supportsFamily(.apple2) { return "apple2" }
        if device.supportsFamily(.apple1) { return "apple1" }
#if os(macOS)
        if device.supportsFamily(.mac2) { return "mac2" }
        if #unavailable(macOS 13.0),
           let legacyMac1Family = Self.legacyMac1Family,
           device.supportsFamily(legacyMac1Family) {
            return "mac1"
        }
#endif
        if device.supportsFamily(.common3) { return "common3" }
        if device.supportsFamily(.common2) { return "common2" }
        if device.supportsFamily(.common1) { return "common1" }
        return "unknown"
    }

#if os(macOS)
    // 2001 is MTLGPUFamily.mac1; use the raw value to avoid deprecated-symbol warnings.
    private static let legacyMac1Family = MTLGPUFamily(rawValue: 2001)
#endif
}
