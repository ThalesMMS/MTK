//
//  VolumeRendererProvider.swift
//  MTKUI
//
//  Lazy 3D renderer capability provider for VolumeViewportController.
//

import Foundation
import Metal
import MTKCore

@MainActor
final class VolumeRendererProvider {
    typealias Factory = (any MTLDevice, any MTLCommandQueue) throws -> MetalVolumeRenderingAdapter

    private enum State {
        case unresolved
        case available(MetalVolumeRenderingAdapter)
        case unavailable(reason: String)
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let factory: Factory
    private var state: State = .unresolved
    private var didLogUnavailable = false
    private let logger = Logger(category: "Volumetric.VolumeRendererProvider")

    init(device: any MTLDevice,
         commandQueue: any MTLCommandQueue,
         factory: Factory? = nil) {
        self.device = device
        self.commandQueue = commandQueue
        self.factory = factory ?? { device, commandQueue in
            try MetalVolumeRenderingAdapter(device: device, commandQueue: commandQueue)
        }
    }

    func renderer() throws -> MetalVolumeRenderingAdapter {
        switch state {
        case .available(let adapter):
            return adapter
        case .unavailable(let reason):
            throw VolumeViewportController.Error.volumeRendererUnavailable(reason: reason)
        case .unresolved:
            do {
                let renderer = try factory(device, commandQueue)
                state = .available(renderer)
                return renderer
            } catch {
                let reason = Self.reason(for: error)
                state = .unavailable(reason: reason)
                logUnavailableOnce(error: error, reason: reason)
                throw VolumeViewportController.Error.volumeRendererUnavailable(reason: reason)
            }
        }
    }

    private func logUnavailableOnce(error: any Swift.Error,
                                    reason: String) {
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        logger.error("Volume renderer unavailable: \(reason)", error: error)
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
