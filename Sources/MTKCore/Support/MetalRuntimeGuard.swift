//
//  MetalRuntimeGuard.swift
//  MTK
//
//  Provides runtime inspection utilities to confirm that the host GPU supports
//  the features required by the Metal volumetric rendering stack. Exposes
//  cached requirement checks, override hooks for tests, and structured logging
//  describing detected capabilities and unsatisfied requirements.
//
//  Thales Matheus Mendonça Santos — October 2025
//

import Foundation
import Metal
import OSLog
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

public protocol MetalRuntimeAvailabilityProviding: AnyObject {
    func status() -> MetalRuntimeGuard.Status
}

/// Validates the Metal runtime contract required by MTK rendering components.
///
/// Use `ensureAvailability(using:)` in initialization paths that require Metal,
/// `status(using:)` when a caller needs detailed capability information, and
/// `isAvailable(using:)` for non-throwing UI checks before Metal objects are
/// created.
public enum MetalRuntimeGuard {
    /// Snapshot of the current Metal runtime requirement status.
    ///
    /// `missingFeatures` identifies required capabilities that are not present.
    /// `supportsMetalPerformanceShaders` reports optional acceleration support
    /// and does not determine whether the core Metal rendering requirement is
    /// satisfied.
    public struct Status: Equatable {
        /// Required Metal runtime feature that is absent or intentionally disabled.
        public enum MissingFeature: Equatable {
            /// Availability was intentionally forced off, typically by tests.
            case forcedUnavailable
            /// No default Metal device can be created.
            case metalUnavailable
            /// A command queue could not be created for the Metal device.
            case commandQueueUnavailable
            /// Required 3D texture allocation or family support is unavailable.
            case texture3DUnsupported
            /// The device does not report one of the required GPU families.
            case unsupportedGPUFamily
        }

        /// `true` when all required Metal runtime capabilities are present.
        public let isAvailable: Bool
        /// Name of the detected Metal device, when one exists.
        public let deviceName: String?
        /// `true` when optional Metal Performance Shaders acceleration is available.
        public let supportsMetalPerformanceShaders: Bool
        /// Required Metal features that prevent the runtime contract from being satisfied.
        public let missingFeatures: [MissingFeature]

        public init(isAvailable: Bool,
                    deviceName: String?,
                    supportsMetalPerformanceShaders: Bool,
                    missingFeatures: [MissingFeature]) {
            self.isAvailable = isAvailable
            self.deviceName = deviceName
            self.supportsMetalPerformanceShaders = supportsMetalPerformanceShaders
            self.missingFeatures = missingFeatures
        }
    }

    /// Requirement validation error thrown when Metal rendering cannot be initialized.
    public enum Error: Swift.Error {
        case unavailable(Status)
    }

    private static let logger = Logger(subsystem: "com.mtk.volumerendering",
                                       category: "MetalRuntimeGuard")
    private static let lock = NSLock()
    private static var cachedStatus: Status?
    private static var overrideProvider: MetalRuntimeAvailabilityProviding?
    private static let defaultProvider = DefaultProvider()

    /// Returns the current Metal runtime requirement status.
    ///
    /// The result is logged when it changes and includes both required capability
    /// failures and optional acceleration availability.
    public static func status(using provider: MetalRuntimeAvailabilityProviding? = nil) -> Status {
        lock.lock()
        defer { lock.unlock() }

        let provider = provider ?? overrideProvider ?? defaultProvider
        let status = provider.status()
        if cachedStatus != status {
            log(status)
            cachedStatus = status
        }
        return status
    }

    /// Returns whether all required Metal runtime capabilities are present.
    public static func isAvailable(using provider: MetalRuntimeAvailabilityProviding? = nil) -> Bool {
        status(using: provider).isAvailable
    }

    /// Throws when the Metal runtime requirement is not satisfied.
    ///
    /// Call this before constructing Metal-only controllers, renderers, or
    /// textures in paths that cannot continue without Metal.
    public static func ensureAvailability(using provider: MetalRuntimeAvailabilityProviding? = nil) throws {
        let status = status(using: provider)
        guard status.isAvailable else {
            throw Error.unavailable(status)
        }
    }

    /// Installs a requirement status provider for tests or controlled runtime probes.
    public static func setOverrideProvider(_ provider: MetalRuntimeAvailabilityProviding?) {
        lock.lock()
        overrideProvider = provider
        cachedStatus = nil
        lock.unlock()
    }

    /// Clears the cached status so the next check logs and evaluates fresh state.
    public static func resetCachedStatus() {
        lock.lock()
        cachedStatus = nil
        lock.unlock()
    }
}

private extension MetalRuntimeGuard {
    static func log(_ status: Status) {
        if status.isAvailable {
            if let deviceName = status.deviceName, deviceName.isEmpty == false {
                logger.info("Metal runtime available on device: \(deviceName)")
            } else {
                logger.info("Metal runtime available")
            }
            if status.supportsMetalPerformanceShaders {
                logger.debug("Metal Performance Shaders available")
            } else {
                logger.warning("MPS unavailable; Metal rendering will run without MPS support")
            }
        } else {
            let reasons = status.missingFeatures
                .map { $0.description }
                .joined(separator: ", ")
            logger.error("Metal runtime unavailable: \(reasons)")
        }
    }

    final class DefaultProvider: MetalRuntimeAvailabilityProviding {
        func status() -> Status {
            let processInfo = ProcessInfo.processInfo
            if processInfo.arguments.contains(Overrides.forceUnavailableArgument) {
                return Status(isAvailable: false,
                              deviceName: nil,
                              supportsMetalPerformanceShaders: false,
                              missingFeatures: [.forcedUnavailable])
            }
            if processInfo.arguments.contains(Overrides.forceAvailableArgument) {
                return Status(isAvailable: true,
                              deviceName: Overrides.forcedDeviceName,
                              supportsMetalPerformanceShaders: true,
                              missingFeatures: [])
            }
            if let override = processInfo.environment[Overrides.environmentKey]?.lowercased() {
                switch override {
                case Overrides.EnvironmentValues.available:
                    return Status(isAvailable: true,
                                  deviceName: Overrides.forcedDeviceName,
                                  supportsMetalPerformanceShaders: true,
                                  missingFeatures: [])
                case Overrides.EnvironmentValues.unavailable:
                    return Status(isAvailable: false,
                                  deviceName: nil,
                                  supportsMetalPerformanceShaders: false,
                                  missingFeatures: [.forcedUnavailable])
                default:
                    break
                }
            }

            guard let device = MTLCreateSystemDefaultDevice() else {
                return Status(isAvailable: false,
                              deviceName: nil,
                              supportsMetalPerformanceShaders: false,
                              missingFeatures: [.metalUnavailable])
            }

            var missingFeatures: [Status.MissingFeature] = []
            let supports3DTextures = Self.supports3DTextures(device: device)
            if supports3DTextures == false {
                missingFeatures.append(.texture3DUnsupported)
            }

            if Self.supportsRequiredGPUFamilies(device: device) == false {
                missingFeatures.append(.unsupportedGPUFamily)
            }

            if device.makeCommandQueue() == nil {
                missingFeatures.append(.commandQueueUnavailable)
            }

            #if canImport(MetalPerformanceShaders)
            let supportsMPS = MPSSupportsMTLDevice(device)
            #else
            let supportsMPS = false
            #endif

            return Status(isAvailable: missingFeatures.isEmpty,
                          deviceName: device.name,
                          supportsMetalPerformanceShaders: supportsMPS,
                          missingFeatures: missingFeatures)
        }

        private static func supports3DTextures(device: any MTLDevice) -> Bool {
            #if os(iOS) || os(tvOS)
            if #available(iOS 13.0, tvOS 13.0, *) {
                if device.supportsAnyFamily([
                    .apple3,
                    .apple4,
                    .apple5,
                    .apple6,
                    .apple7,
                    .apple8,
                    .apple9,
                    .apple10,
                    .common3
                ]) {
                    return true
                }
            } else {
                return true
            }
            #elseif os(macOS)
            if #available(macOS 11.0, *) {
                if device.supportsAnyFamily([.mac1, .mac2, .common3]) {
                    return true
                }
            } else {
                return true
            }
            #else
            return true
            #endif

            // Validate support with an allocation probe for environments (e.g., simulators
            // or future GPU families) where family reporting might be incomplete.
            return probe3DTextureAllocation(device: device)
        }

        private static func supportsRequiredGPUFamilies(device: any MTLDevice) -> Bool {
            #if os(iOS) || os(tvOS)
            if #available(iOS 16.0, tvOS 16.0, *) {
                if device.supportsAnyFamily([
                    .apple4,
                    .apple5,
                    .apple6,
                    .apple7,
                    .apple8,
                    .apple9,
                    .apple10,
                    .common3
                ]) {
                    return true
                }
                return probe3DTextureAllocation(device: device)
            }
            return true
            #elseif os(macOS)
            if #available(macOS 12.0, *) {
                if device.supportsAnyFamily([.mac1, .mac2, .common3]) {
                    return true
                }
                return probe3DTextureAllocation(device: device)
            }
            return true
            #else
            return true
            #endif
        }

        private static func probe3DTextureAllocation(device: any MTLDevice) -> Bool {
            // StorageModePolicy.md: capability probes set explicit texture properties.
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .r8Unorm
            descriptor.width = 4
            descriptor.height = 4
            descriptor.depth = 4
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            return device.makeTexture(descriptor: descriptor) != nil
        }
    }
}

private extension MetalRuntimeGuard.Status.MissingFeature {
    var description: String {
        switch self {
        case .forcedUnavailable:
            return "availability forced to unavailable"
        case .metalUnavailable:
            return "Metal device unavailable"
        case .commandQueueUnavailable:
            return "unable to create Metal command queue"
        case .texture3DUnsupported:
            return "3D texture support missing"
        case .unsupportedGPUFamily:
            return "required GPU family unsupported"
        }
    }
}

private extension MTLDevice {
    @available(iOS 13.0, macOS 11.0, tvOS 13.0, *)
    func supportsAnyFamily(_ families: [MTLGPUFamily]) -> Bool {
        families.contains { supportsFamily($0) }
    }
}

private enum Overrides {
    static let forceUnavailableArgument = "--uitest-force-metal-unavailable"
    static let forceAvailableArgument = "--uitest-force-metal-available"
    static let environmentKey = "MTK_FORCE_METAL_AVAILABILITY"
    static let forcedDeviceName = "override"

    enum EnvironmentValues {
        static let available = "available"
        static let unavailable = "unavailable"
    }
}
