//
//  MetalRuntimeAvailability.swift
//  MTK
//
//  Lightweight bridge exposing Metal runtime guard details to the app target
//  without requiring it to depend directly on the Support module. This keeps
//  the dual-backend wiring contained within the adapters layer.
//

import Foundation

/// Public adapter for Metal runtime availability checks.
///
/// `MetalRuntimeAvailability` wraps `MetalRuntimeGuard` to expose runtime capability detection
/// without requiring clients to import the internal Support module. Use this to gate Metal-dependent
/// features and fall back gracefully on unsupported platforms (e.g., iOS Simulator, non-Apple GPUs).
///
/// ## Usage
///
/// Check availability before creating Metal controllers:
/// ```swift
/// guard MetalRuntimeAvailability.isAvailable() else {
///     // Fall back to CPU-based rendering or display error
///     return
/// }
/// let controller = VolumetricSceneController()
/// ```
///
/// Or enforce availability and handle errors:
/// ```swift
/// do {
///     try MetalRuntimeAvailability.ensureAvailability()
///     // Proceed with Metal setup
/// } catch {
///     print("Metal unavailable: \(error)")
/// }
/// ```
///
/// - Note: All methods are inlinable for zero-overhead forwarding to `MetalRuntimeGuard`.
public enum MetalRuntimeAvailability {
    /// Returns `true` if Metal is available on the current device.
    ///
    /// Use this for non-throwing availability checks before initializing Metal resources.
    ///
    /// - Returns: `true` if a Metal device can be created, `false` otherwise.
    @inlinable
    public static func isAvailable() -> Bool {
        MetalRuntimeGuard.isAvailable()
    }

    /// Returns the detailed Metal runtime status.
    ///
    /// Provides diagnostic information about why Metal may be unavailable (e.g., simulator, no GPU).
    ///
    /// - Returns: A `MetalRuntimeGuard.Status` describing the current runtime state.
    @inlinable
    public static func status() -> MetalRuntimeGuard.Status {
        MetalRuntimeGuard.status()
    }

    /// Throws an error if Metal is unavailable.
    ///
    /// Use this when Metal is a hard requirement and you want to surface the unavailability as an error.
    ///
    /// - Throws: `MetalRuntimeGuard.UnavailableError` if no Metal device is detected.
    @inlinable
    public static func ensureAvailability() throws {
        try MetalRuntimeGuard.ensureAvailability()
    }
}
