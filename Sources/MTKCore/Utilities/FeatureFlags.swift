//
//  FeatureFlags.swift
//  MTK
//
//  Captures GPU capabilities required by the volume renderer so callers can
//  specialize code paths (argument buffers, threadgroups, heaps) per device.
//
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
import Metal

public struct FeatureFlags: OptionSet, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    // Metal capabilities
    public static let argumentBuffers = FeatureFlags(rawValue: 1 << 0)
    public static let nonUniformThreadgroups = FeatureFlags(rawValue: 1 << 1)
    public static let heapAllocations = FeatureFlags(rawValue: 1 << 2)
    public static let diagnosticLogging = FeatureFlags(rawValue: 1 << 3)

    // Rendering features (added from MTK-Demo)
    public static let adaptiveRendering = FeatureFlags(rawValue: 1 << 4)
    public static let toneMapping = FeatureFlags(rawValue: 1 << 5)
    public static let clipping = FeatureFlags(rawValue: 1 << 6)
    public static let mprMode = FeatureFlags(rawValue: 1 << 7)

    /// All available feature flags
    public static let all: FeatureFlags = [
        .argumentBuffers, .nonUniformThreadgroups, .heapAllocations, .diagnosticLogging,
        .adaptiveRendering, .toneMapping, .clipping, .mprMode
    ]

    public static func evaluate(for device: any MTLDevice) -> FeatureFlags {
        var flags: FeatureFlags = []

        // Evaluate Metal capabilities
        if device.supportsAdvancedArgumentBuffers {
            flags.insert(.argumentBuffers)
        }

        if device.supportsNonUniformThreadgroups {
            flags.insert(.nonUniformThreadgroups)
        }

        if device.supportsPrivateHeaps {
            flags.insert(.heapAllocations)
        }

        // Rendering features are enabled by default
        flags.insert(.adaptiveRendering)
        flags.insert(.toneMapping)
        flags.insert(.clipping)
        flags.insert(.mprMode)

        return flags
    }

    public var description: String {
        var components: [String] = []
        if contains(.argumentBuffers) { components.append("argumentBuffers") }
        if contains(.nonUniformThreadgroups) { components.append("nonUniformThreadgroups") }
        if contains(.heapAllocations) { components.append("heapAllocations") }
        if contains(.diagnosticLogging) { components.append("diagnosticLogging") }
        if contains(.adaptiveRendering) { components.append("adaptiveRendering") }
        if contains(.toneMapping) { components.append("toneMapping") }
        if contains(.clipping) { components.append("clipping") }
        if contains(.mprMode) { components.append("mprMode") }
        if components.isEmpty { components.append("none") }
        return "[" + components.joined(separator: ", ") + "]"
    }
}

public extension MTLDevice {
    func evaluatedFeatureFlags() -> FeatureFlags {
        FeatureFlags.evaluate(for: self)
    }
}

private extension MTLDevice {
    var supportsAdvancedArgumentBuffers: Bool {
        if #available(iOS 13.0, macOS 11.0, tvOS 13.0, *) {
            if supportsAnyFamily([.apple4, .apple5, .apple6, .apple7, .apple8, .apple9, .apple10, .common3, .mac2]) {
                return true
            }
        } else {
            return argumentBuffersSupport == .tier2
        }

        return argumentBuffersSupport == .tier2
    }

    var supportsNonUniformThreadgroups: Bool {
        if #available(iOS 13.0, macOS 11.0, tvOS 13.0, *) {
            if supportsAnyFamily([.apple4, .apple5, .apple6, .apple7, .apple8, .apple9, .apple10, .common3, .mac2]) {
                return true
            }
        }

        return false
    }

    var supportsPrivateHeaps: Bool {
        if #available(iOS 13.0, macOS 11.0, tvOS 13.0, *) {
            if supportsAnyFamily([.apple4, .apple5, .apple6, .apple7, .apple8, .apple9, .apple10, .common3, .mac2]) {
                return true
            }
        }

        return false
    }

    @available(iOS 13.0, macOS 11.0, tvOS 13.0, *)
    func supportsAnyFamily(_ families: [MTLGPUFamily]) -> Bool {
        families.contains { supportsFamily($0) }
    }
}
