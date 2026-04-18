//  ShaderLibraryLoader.swift
//  MTK
//  Fail-fast loader for the required Bundle.module Metal library.
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
#if canImport(Metal)
import Metal
#endif

/// Loader for MTKCore's required bundled Metal shader library.
///
/// `ShaderLibraryLoader` loads the precompiled `MTK.metallib` artifact from
/// `Bundle.module`. The artifact is produced by `MTKShaderPlugin` and is required
/// for Metal-backed rendering.
///
/// ## Failure Semantics
///
/// Missing or invalid shader artifacts are reported through ``LoaderError`` so
/// callers can distinguish packaging failures from Metal library loading errors.
///
/// ## Usage
///
/// Load a library for volumetric rendering pipelines:
/// ```swift
/// let library = try ShaderLibraryLoader.loadLibrary(for: device)
/// let function = library.makeFunction(name: "volume_raycaster")
/// ```
public enum ShaderLibraryLoader {
    /// Errors reported when the required `MTK.metallib` artifact cannot be loaded.
    public enum LoaderError: LocalizedError {
        /// `MTK.metallib` is not present in `Bundle.module`.
        case metallibNotBundled

        /// `MTK.metallib` was found in `Bundle.module` but Metal could not load it.
        case metallibLoadFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .metallibNotBundled:
                return "Required shader artifact MTK.metallib was not found in Bundle.module."
            case .metallibLoadFailed:
                return "Required shader artifact MTK.metallib from Bundle.module could not be loaded."
            }
        }

        public var failureReason: String? {
            switch self {
            case .metallibNotBundled:
                return "ShaderLibraryLoader expects MTK.metallib to be packaged in MTKCore's Bundle.module resources."
            case .metallibLoadFailed(let underlying):
                return "MTK.metallib was found in MTKCore's Bundle.module resources, but Metal rejected it for the supplied device: \(underlying.localizedDescription)"
            }
        }
    }

#if canImport(Metal)
    /// Loads the required `MTK.metallib` artifact from `Bundle.module`.
    ///
    /// - Parameter device: The `MTLDevice` used to load the library.
    /// - Returns: The loaded `MTLLibrary`.
    /// - Throws: ``LoaderError/metallibNotBundled`` when `MTK.metallib` is not
    ///   present in `Bundle.module`, or ``LoaderError/metallibLoadFailed(underlying:)``
    ///   when Metal rejects the bundled artifact.
    public static func loadLibrary(for device: MTLDevice) throws -> MTLLibrary {
        try loadLibrary(for: device, in: .module)
    }

    static func loadLibrary(for device: MTLDevice, in bundle: Bundle) throws -> MTLLibrary {
        guard let url = bundle.url(forResource: "MTK", withExtension: "metallib") else {
            throw LoaderError.metallibNotBundled
        }

        do {
            return try device.makeLibrary(URL: url)
        } catch {
            throw LoaderError.metallibLoadFailed(underlying: error)
        }
    }
#endif
}
