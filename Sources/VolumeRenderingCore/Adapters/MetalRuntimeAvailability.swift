//
//  MetalRuntimeAvailability.swift
//  MetalVolumetrics
//
//  Lightweight bridge exposing Metal runtime guard details to the app target
//  without requiring it to depend directly on the Support module. This keeps
//  the dual-backend wiring contained within the adapters layer.
//

import Foundation
import Support

public enum MetalRuntimeAvailability {
    @inlinable
    public static func isAvailable() -> Bool {
        MetalRuntimeGuard.isAvailable()
    }

    @inlinable
    public static func status() -> MetalRuntimeGuard.Status {
        MetalRuntimeGuard.status()
    }

    @inlinable
    public static func ensureAvailability() throws {
        try MetalRuntimeGuard.ensureAvailability()
    }
}
