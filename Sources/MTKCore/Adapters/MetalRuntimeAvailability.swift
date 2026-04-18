//
//  MetalRuntimeAvailability.swift
//  MTK
//
//  Lightweight bridge exposing Metal runtime requirement details to the app
//  target without requiring it to depend directly on the Support module. This
//  keeps Metal capability checks contained within the adapters layer.
//

import Foundation

/// Public adapter for enforcing the Metal runtime requirement.
///
/// `MetalRuntimeAvailability` wraps `MetalRuntimeGuard` to expose runtime capability detection
/// without requiring clients to import the internal Support module. MTK rendering is Metal-only:
/// clients should use these checks to enforce that requirement before constructing rendering
/// objects and to surface explicit unavailable states when the host cannot satisfy the runtime
/// contract.
///
/// ## Usage
///
/// Prefer the throwing check for initialization paths that require Metal:
/// ```swift
/// do {
///     try MetalRuntimeAvailability.ensureAvailability()
///     let controller = VolumetricSceneController()
/// } catch {
///     // Surface the unsupported runtime state to the user.
///     print("Metal runtime requirement not satisfied: \(error)")
/// }
/// ```
///
/// Use the non-throwing check for UI gating before Metal objects are created:
/// ```swift
/// if MetalRuntimeAvailability.isAvailable() {
///     // Enable Metal-only rendering controls.
/// } else {
///     // Present an explicit unsupported-runtime state.
/// }
/// ```
///
/// - Note: All methods are inlinable for zero-overhead forwarding to `MetalRuntimeGuard`.
public enum MetalRuntimeAvailability {
    /// Returns `true` when the current device satisfies the Metal requirement.
    ///
    /// Use this for non-throwing requirement checks before initializing Metal resources.
    ///
    /// - Returns: `true` if a Metal device can be created, `false` otherwise.
    @inlinable
    public static func isAvailable() -> Bool {
        MetalRuntimeGuard.isAvailable()
    }

    /// Returns the detailed Metal runtime requirement status.
    ///
    /// Provides diagnostic information for explicit unsupported-runtime presentation when Metal
    /// or a required capability is unavailable.
    ///
    /// - Returns: A `MetalRuntimeGuard.Status` describing the current runtime state.
    @inlinable
    public static func status() -> MetalRuntimeGuard.Status {
        MetalRuntimeGuard.status()
    }

    /// Throws an error when the current device does not satisfy the Metal requirement.
    ///
    /// Use this when Metal is a hard requirement and you want to surface the unavailability as an error.
    ///
    /// - Throws: `MetalRuntimeGuard.Error.unavailable` when the Metal runtime requirement is not satisfied.
    @inlinable
    public static func ensureAvailability() throws {
        try MetalRuntimeGuard.ensureAvailability()
    }
}
