//
//  MetalRuntimeGuard.swift
//  MTK
//
//  Provides runtime inspection utilities to confirm that the host GPU supports
//  the features required by the Metal volumetric rendering stack. Mirrors the
//  behaviour of the legacy runtime guard by exposing cached availability
//  checks, override hooks for tests and structured logging describing detected
//  capabilities.
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

public enum MetalRuntimeGuard {
    public struct Status: Equatable {
        public enum MissingFeature: Equatable {
            case forcedUnavailable
            case metalUnavailable
            case commandQueueUnavailable
            case texture3DUnsupported
            case unsupportedGPUFamily
        }

        public let isAvailable: Bool
        public let deviceName: String?
        public let supportsMetalPerformanceShaders: Bool
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

    public enum Error: Swift.Error {
        case unavailable(Status)
    }

    private static let logger = Logger(subsystem: "com.mtk.volumerendering",
                                       category: "MetalRuntimeGuard")
    private static let lock = NSLock()
    private static var cachedStatus: Status?
    private static var overrideProvider: MetalRuntimeAvailabilityProviding?
    private static let defaultProvider = DefaultProvider()

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

    public static func isAvailable(using provider: MetalRuntimeAvailabilityProviding? = nil) -> Bool {
        status(using: provider).isAvailable
    }

    public static func ensureAvailability(using provider: MetalRuntimeAvailabilityProviding? = nil) throws {
        let status = status(using: provider)
        guard status.isAvailable else {
            throw Error.unavailable(status)
        }
    }

    public static func setOverrideProvider(_ provider: MetalRuntimeAvailabilityProviding?) {
        lock.lock()
        overrideProvider = provider
        cachedStatus = nil
        lock.unlock()
    }

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
                logger.warning("Metal Performance Shaders unavailable; falling back to shader implementations")
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

            // Fallback to an allocation probe for environments (e.g., simulators or
            // future GPU families) where family reporting might be incomplete.
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
