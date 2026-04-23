//
//  ProfilingEnvironment.swift
//  MTK
//
//  Device and process context for clinical profiling sessions.
//

import Foundation
@preconcurrency import Metal

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

    public init(deviceName: String,
                osVersion: String,
                gpuFamily: String,
                maxThreadsPerThreadgroupDimensions: ProfilingThreadgroupDimensions,
                recommendedMaxWorkingSetSize: UInt64,
                appVersion: String,
                buildNumber: String) {
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.gpuFamily = gpuFamily
        self.maxThreadsPerThreadgroupDimensions = maxThreadsPerThreadgroupDimensions
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
        self.appVersion = appVersion
        self.buildNumber = buildNumber
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
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
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
