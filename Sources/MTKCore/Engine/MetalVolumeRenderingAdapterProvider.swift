//
//  MetalVolumeRenderingAdapterProvider.swift
//  MTK
//
//  Lazy 3D renderer capability provider for volume/projection routes.
//

import Foundation
@preconcurrency import Metal
import OSLog

package actor MetalVolumeRenderingAdapterProvider {
    package typealias Factory = @Sendable (any MTLDevice, any MTLCommandQueue) throws -> MetalVolumeRenderingAdapter

    private enum State {
        case unresolved
        case available(MetalVolumeRenderingAdapter)
        case unavailable(reason: String)
    }

    package static let defaultFactory: Factory = { device, commandQueue in
        try MetalVolumeRenderingAdapter(device: device, commandQueue: commandQueue)
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let factory: Factory
    private var state: State = .unresolved
    private var didLogUnavailable = false
    private let logger = os.Logger(subsystem: "com.mtk.volumerendering",
                                   category: "MetalVolumeRenderingAdapterProvider")

    package init(device: any MTLDevice,
                 commandQueue: any MTLCommandQueue,
                 factory: @escaping Factory = MetalVolumeRenderingAdapterProvider.defaultFactory) {
        self.device = device
        self.commandQueue = commandQueue
        self.factory = factory
    }

    package func adapter() throws -> MetalVolumeRenderingAdapter {
        switch state {
        case .available(let adapter):
            return adapter
        case .unavailable(let reason):
            throw MTKRenderingEngine.EngineError.volumeRendererUnavailable(reason: reason)
        case .unresolved:
            do {
                let adapter = try factory(device, commandQueue)
                state = .available(adapter)
                return adapter
            } catch {
                let reason = Self.reason(for: error)
                state = .unavailable(reason: reason)
                logUnavailableOnce(reason: reason)
                throw MTKRenderingEngine.EngineError.volumeRendererUnavailable(reason: reason)
            }
        }
    }

    private func logUnavailableOnce(reason: String) {
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        logger.error("Volume renderer unavailable reason=\(reason, privacy: .public)")
    }

    private static func reason(for error: any Swift.Error) -> String {
        let description = error.localizedDescription
        if let localizedError = error as? LocalizedError,
           let failureReason = localizedError.failureReason,
           !failureReason.isEmpty {
            return "\(description): \(failureReason)"
        }
        return description
    }
}
