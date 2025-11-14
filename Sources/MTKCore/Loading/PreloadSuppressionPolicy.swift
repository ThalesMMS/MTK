//
//  PreloadSuppressionPolicy.swift
//  MTK - Medical Toolkit
//
//  Manages preload suppression policies for volumetric rendering datasets.
//  Determines when volumetric dataset loading should be suppressed based on device
//  capabilities, performance heuristics, and resource availability.
//
//  Migrated from: Isis DICOM Viewer/VolumetricSessionState.swift
//  Migration date: 2025-11-10
//

import Foundation

#if os(iOS)
import UIKit
#endif

// MARK: - PreloadSuppressionReason

/// Represents why a volumetric dataset load was suppressed.
///
/// Only `.notAttempted` originates from heuristics that skip preload work and can
/// therefore be overridden by an explicit user action. All other reasons should
/// reflect hard failures or incompatibilities and must not be bypassed automatically.
public enum PreloadSuppressionReason: String, Sendable, Codable, Hashable {
    /// Load was not attempted due to heuristic-based suppression (user-overridable)
    case notAttempted = "not_attempted"

    /// Load suppressed due to insufficient device memory
    case insufficientMemory = "insufficient_memory"

    /// Load suppressed due to low battery mode being active
    case lowBatteryMode = "low_battery_mode"

    /// Load suppressed due to thermal throttling conditions
    case thermalThrottling = "thermal_throttling"

    /// Load suppressed due to incompatible or unsupported device hardware
    case incompatibleDevice = "incompatible_device"

    /// Indicates if this reason can be overridden by user action
    public var isUserOverridable: Bool {
        self == .notAttempted
    }
}

// MARK: - DeviceCapabilities

/// Describes the capabilities and performance class of the current device.
public struct DeviceCapabilities: Sendable, Codable, Hashable {
    /// Whether Metal rendering is supported on this device
    public let isMetalSupported: Bool

    /// Estimated available system memory in bytes
    public let estimatedMemory: UInt64

    /// Whether thermal monitoring is available
    public let thermalMonitoringAvailable: Bool

    /// Performance classification of the device
    public let performanceClass: PerformanceClass

    /// Maximum recommended volume dimensions for this device
    public let maxRecommendedVolumeDimension: Int

    public init(
        isMetalSupported: Bool,
        estimatedMemory: UInt64,
        thermalMonitoringAvailable: Bool,
        performanceClass: PerformanceClass,
        maxRecommendedVolumeDimension: Int
    ) {
        self.isMetalSupported = isMetalSupported
        self.estimatedMemory = estimatedMemory
        self.thermalMonitoringAvailable = thermalMonitoringAvailable
        self.performanceClass = performanceClass
        self.maxRecommendedVolumeDimension = maxRecommendedVolumeDimension
    }
}

// MARK: - PerformanceClass

/// Classifies device performance tiers for volumetric rendering
public enum PerformanceClass: String, Sendable, Codable, Hashable {
    /// Low-end devices with limited resources
    case low

    /// Mid-range devices with moderate resources
    case medium

    /// High-end devices with substantial resources
    case high

    /// Premium devices with maximum available resources
    case premium

    /// Minimum recommended GPU memory for volumetric rendering (in bytes)
    public var minimumGPUMemory: UInt64 {
        switch self {
        case .low: return 256 * 1024 * 1024      // 256 MB
        case .medium: return 512 * 1024 * 1024   // 512 MB
        case .high: return 1024 * 1024 * 1024    // 1 GB
        case .premium: return 2048 * 1024 * 1024 // 2 GB
        }
    }

    /// Recommended sampling step for quality rendering
    public var recommendedSamplingStep: Float {
        switch self {
        case .low: return 192
        case .medium: return 320
        case .high: return 512
        case .premium: return 768
        }
    }
}

// MARK: - PreloadSuppressionPolicy

/// Manages the policy for suppressing volumetric dataset preloading based on device
/// capabilities and system resource availability.
///
/// This struct provides decision-making methods to determine whether volumetric
/// dataset loading should be suppressed to maintain system stability and performance.
public struct PreloadSuppressionPolicy: Sendable {
    /// Minimum memory threshold required for volumetric rendering (bytes)
    /// Default: 256 MB
    public static let minimumRequiredMemory: UInt64 = 256 * 1024 * 1024

    /// Memory warning threshold as percentage of total available memory (0-100)
    /// Default: 15% - suppress preload if available memory falls below this threshold
    public static let memoryWarningThresholdPercent: Double = 15.0

    /// Maximum safe volume dimensions for different performance classes
    public static let volumeDimensionThresholds: [PerformanceClass: Int] = [
        .low: 256,
        .medium: 512,
        .high: 1024,
        .premium: 2048
    ]

    private init() {
        // Prevent instantiation; use static methods instead
    }
}

// MARK: - Device Capability Detection

extension PreloadSuppressionPolicy {
    /// Detects and returns the current device's capabilities.
    ///
    /// - Returns: A `DeviceCapabilities` struct describing the current device
    public static func detectDeviceCapabilities() -> DeviceCapabilities {
        let performanceClass = detectPerformanceClass()
        let estimatedMemory = estimateAvailableMemory()
        let thermalSupport = isThermalMonitoringAvailable()

        let maxDimension = volumeDimensionThresholds[performanceClass] ?? 512

        return DeviceCapabilities(
            isMetalSupported: isMetalBackendAvailable(),
            estimatedMemory: estimatedMemory,
            thermalMonitoringAvailable: thermalSupport,
            performanceClass: performanceClass,
            maxRecommendedVolumeDimension: maxDimension
        )
    }

    /// Determines the performance class of the current device based on available resources.
    ///
    /// - Returns: The detected `PerformanceClass`
    public static func detectPerformanceClass() -> PerformanceClass {
        let memoryBytes = estimateAvailableMemory()
        let systemMemoryGB = Double(memoryBytes) / (1024 * 1024 * 1024)

        // Classification based on system memory availability
        if systemMemoryGB >= 6.0 {
            return .premium
        } else if systemMemoryGB >= 3.0 {
            return .high
        } else if systemMemoryGB >= 1.5 {
            return .medium
        } else {
            return .low
        }
    }

    /// Estimates the currently available system memory in bytes.
    ///
    /// - Returns: Available memory in bytes
    public static func estimateAvailableMemory() -> UInt64 {
        var taskInfo = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size)/4

        let kerr = withUnsafeMutablePointer(to: &taskInfo) {
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_BASIC_INFO),
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) { $0 },
                &count
            )
        }

        guard kerr == KERN_SUCCESS else {
            // Fallback to ProcessInfo if task_info fails
            return ProcessInfo.processInfo.physicalMemory
        }

        return UInt64(taskInfo.resident_size)
    }

    /// Determines whether Metal rendering backend is available on this device.
    ///
    /// - Returns: `true` if Metal is supported, `false` otherwise
    public static func isMetalBackendAvailable() -> Bool {
        #if os(macOS)
        // Metal is available on all modern macOS versions
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 10
        #elseif os(iOS) || os(tvOS)
        // Metal is available on all A7 and later chips
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 8
        #else
        return false
        #endif
    }

    /// Checks whether thermal monitoring/management is available on this device.
    ///
    /// - Returns: `true` if thermal monitoring is available, `false` otherwise
    public static func isThermalMonitoringAvailable() -> Bool {
        #if os(iOS) || os(tvOS)
        // ProcessInfo.thermalState available on iOS 11.2+
        if #available(iOS 11.2, tvOS 11.2, *) {
            return true
        }
        #elseif os(macOS)
        // macOS thermal monitoring available on 10.10.3+
        if #available(macOS 10.10.3, *) {
            return true
        }
        #endif
        return false
    }

    /// Checks if the device is currently in low battery mode.
    ///
    /// - Returns: `true` if low battery mode is enabled, `false` otherwise
    public static func isLowBatteryModeActive() -> Bool {
        #if os(iOS)
        if #available(iOS 9.0, *) {
            return UIDevice.current.batteryState == .unplugged &&
                   UIDevice.current.batteryLevel < 0.20
        }
        #endif
        return false
    }

    /// Checks if the device is experiencing thermal throttling.
    ///
    /// - Returns: `true` if thermal throttling is active, `false` otherwise
    public static func isThermalThrottlingActive() -> Bool {
        #if os(iOS) || os(tvOS)
        if #available(iOS 11.2, tvOS 11.2, *) {
            return ProcessInfo.processInfo.thermalState == .critical
        }
        #endif
        return false
    }
}

// MARK: - Suppression Decision Logic

extension PreloadSuppressionPolicy {
    /// Determines whether volumetric dataset preload should be suppressed based on
    /// current system state and device capabilities.
    ///
    /// This method evaluates multiple factors including memory availability, battery
    /// state, and thermal conditions to decide if preloading should be suppressed.
    ///
    /// - Parameters:
    ///   - capabilities: The device capabilities to evaluate
    ///   - volumeDataSize: Size of the volume data to load (in bytes)
    /// - Returns: A `PreloadSuppressionReason` if loading should be suppressed,
    ///           or `nil` if loading is allowed
    public static func shouldSuppressPreload(
        with capabilities: DeviceCapabilities,
        volumeDataSize: UInt64
    ) -> PreloadSuppressionReason? {
        // Check Metal support first - this is a hard requirement
        guard capabilities.isMetalSupported else {
            return .incompatibleDevice
        }

        // Check thermal state
        if isThermalThrottlingActive() {
            return .thermalThrottling
        }

        // Check battery state
        if isLowBatteryModeActive() {
            return .lowBatteryMode
        }

        // Check memory availability
        if shouldSuppressForMemory(
            available: capabilities.estimatedMemory,
            required: volumeDataSize
        ) {
            return .insufficientMemory
        }

        return nil
    }

    /// Evaluates whether volumetric rendering can be enabled based on device capabilities.
    ///
    /// - Parameters:
    ///   - capabilities: The device capabilities to evaluate
    /// - Returns: `true` if volumetric rendering can be enabled, `false` otherwise
    public static func canEnableVolumetric(with capabilities: DeviceCapabilities) -> Bool {
        guard capabilities.isMetalSupported else {
            return false
        }

        guard !isThermalThrottlingActive() else {
            return false
        }

        return capabilities.estimatedMemory >= minimumRequiredMemory
    }

    /// Determines whether memory constraints should suppress preload.
    ///
    /// - Parameters:
    ///   - available: Available system memory in bytes
    ///   - required: Required memory for volumetric data in bytes
    /// - Returns: `true` if preload should be suppressed due to memory constraints
    public static func shouldSuppressForMemory(available: UInt64, required: UInt64) -> Bool {
        // Require 3x the data size as free memory (for processing overhead)
        let requiredWithOverhead = required * 3

        // Also check if available memory falls below warning threshold
        let systemMemory = ProcessInfo.processInfo.physicalMemory
        let warningThreshold = Double(systemMemory) * (memoryWarningThresholdPercent / 100.0)

        return available < requiredWithOverhead || Double(available) < warningThreshold
    }

    /// Evaluates whether a specific volume dimension is reasonable for the device.
    ///
    /// - Parameters:
    ///   - dimension: The maximum dimension of the volume (width, height, or depth)
    ///   - capabilities: The device capabilities
    /// - Returns: `true` if the dimension is acceptable, `false` if it exceeds limits
    public static func isVolumeDimensionAcceptable(
        dimension: Int,
        for capabilities: DeviceCapabilities
    ) -> Bool {
        return dimension <= capabilities.maxRecommendedVolumeDimension
    }

    /// Gets memory status information including available and threshold values.
    ///
    /// - Returns: A tuple containing available memory and warning threshold in bytes
    public static func getDeviceMemoryStatus() -> (available: UInt64, threshold: UInt64) {
        let available = estimateAvailableMemory()
        let physicalMemory = UInt64(ProcessInfo.processInfo.physicalMemory)
        let threshold = UInt64(Double(physicalMemory) * (memoryWarningThresholdPercent / 100.0))

        return (available, threshold)
    }
}

// MARK: - Helper Extensions

extension PreloadSuppressionReason {
    /// User-friendly description of the suppression reason.
    public var description: String {
        switch self {
        case .notAttempted:
            return "Preload was not attempted"
        case .insufficientMemory:
            return "Insufficient device memory available"
        case .lowBatteryMode:
            return "Device is in low battery mode"
        case .thermalThrottling:
            return "Device is experiencing thermal throttling"
        case .incompatibleDevice:
            return "Device hardware is not compatible with volumetric rendering"
        }
    }
}
