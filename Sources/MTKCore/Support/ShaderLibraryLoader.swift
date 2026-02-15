//  ShaderLibraryLoader.swift
//  MTK
//  Guarded loader for Bundle.module Metal libraries with diagnostics.
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
#if canImport(Metal)
import Metal
#endif

/// Loader for MTKCore's bundled Metal shader libraries with multi-tier fallback strategy.
///
/// `ShaderLibraryLoader` attempts to load precompiled Metal libraries from `Bundle.module`,
/// falling back to runtime compilation in DEBUG builds when the bundled `.metallib` is unavailable.
/// This enables development workflows (Xcode, SwiftPM) to function without manual shader compilation
/// while ensuring release builds enforce the presence of precompiled shaders.
///
/// ## Loading Strategy
///
/// The loader tries sources in order:
/// 1. **Bundled metallib**: `VolumeRendering.metallib` in `Bundle.module` (compiled by `MTKShaderPlugin`)
/// 2. **Module default library** (DEBUG only): Shaders compiled from source by SwiftPM/Xcode
/// 3. **Main bundle default library** (DEBUG only): Fallback to app's default Metal library
/// 4. **Runtime compilation** (DEBUG only): Concatenates all `.metal` sources and compiles on-the-fly
///
/// In release builds, only step 1 succeeds; missing libraries cause immediate failure.
///
/// ## Usage
///
/// Load a library for volumetric rendering pipelines:
/// ```swift
/// guard let library = ShaderLibraryLoader.makeDefaultLibrary(on: device) { message in
///     print(message)
/// } else {
///     fatalError("Failed to load Metal shaders")
/// }
/// let function = library.makeFunction(name: "volume_raycaster")
/// ```
///
/// - Note: The `diagnostics` closure receives log messages during fallback attempts.
/// - Important: Requires Metal-capable device. On non-Metal platforms (macOS without GPU, iOS Simulator pre-Apple Silicon), returns `nil`.
public enum ShaderLibraryLoader {
#if canImport(Metal)
    /// Loads the MTKCore Metal library using a multi-tier fallback strategy.
    ///
    /// Attempts to load the bundled `VolumeRendering.metallib` first, then falls back to module/main bundle
    /// libraries or runtime compilation in DEBUG builds. Returns `nil` if all strategies fail.
    ///
    /// - Parameters:
    ///   - device: The Metal device to compile/load the library for.
    ///   - diagnostics: Closure receiving diagnostic messages during fallback attempts. Defaults to no-op.
    ///
    /// - Returns: A configured `MTLLibrary`, or `nil` if no shader sources could be loaded.
    ///
    /// - Note: In release builds, only the bundled `.metallib` is loaded. Missing libraries cause `nil` return with diagnostic error.
    /// - Important: Diagnostics are essential for debugging shader loading failures; capture them in test/debug builds.
    public static func makeDefaultLibrary(on device: MTLDevice,
                                          diagnostics: (String) -> Void = { _ in }) -> MTLLibrary? {
        if let library = loadBundledMetallib(on: device, diagnostics: diagnostics) {
            return library
        }

#if DEBUG
        if let bundleLibrary = loadModuleDefaultLibrary(on: device, diagnostics: diagnostics) {
            return bundleLibrary
        }

        if let main = device.makeDefaultLibrary() {
            diagnostics("[MTKCore] Loaded main bundle default library")
            return main
        }

        if let runtimeLib = runtimeLibrary(on: device, diagnostics: diagnostics) {
            return runtimeLib
        }

        diagnostics("[MTKCore] Unable to load Metal library; CPU fallbacks may activate")
        return nil
#else
        diagnostics("[MTKCore] ERROR: Release build is missing MTK.metallib in Bundle.module")
        return nil
#endif
    }
#else
    /// Platform fallback for non-Metal environments.
    ///
    /// Always returns `nil` and logs a diagnostic message on platforms without Metal support.
    ///
    /// - Parameters:
    ///   - device: Placeholder device parameter (unused).
    ///   - diagnostics: Closure receiving a diagnostic message. Defaults to no-op.
    ///
    /// - Returns: Always `nil`.
    public static func makeDefaultLibrary(on device: Any, diagnostics: (String) -> Void = { _ in }) -> Any? {
        diagnostics("[MTKCore] Metal unavailable on this platform")
        return nil
    }
#endif
}

#if canImport(Metal)
private extension ShaderLibraryLoader {
    static func loadBundledMetallib(on device: MTLDevice,
                                    diagnostics: (String) -> Void) -> MTLLibrary? {
        guard let url = Bundle.module.url(forResource: "VolumeRendering", withExtension: "metallib") else {
            return nil
        }

        do {
            let library = try device.makeLibrary(URL: url)
            diagnostics("[MTKCore] Loaded MTK.metallib from Bundle.module")
            return library
        } catch {
            diagnostics("[MTKCore] Failed to load MTK.metallib: \(error)")
            return nil
        }
    }

    static func loadModuleDefaultLibrary(on device: MTLDevice,
                                         diagnostics: (String) -> Void) -> MTLLibrary? {
        if #available(iOS 14, macOS 11, *) {
            if let bundled = try? device.makeDefaultLibrary(bundle: .module) {
                diagnostics("[MTKCore] Compiled shaders from Bundle.module sources")
                return bundled
            }
        }
        return nil
    }

    static func runtimeLibrary(on device: MTLDevice,
                               diagnostics: (String) -> Void) -> MTLLibrary? {
        guard let source = concatenatedShaderSources() else {
            diagnostics("[MTKCore] No shader source files available for runtime compilation")
            return nil
        }
        let options = MTLCompileOptions()
        if #available(iOS 16, macOS 13, *) {
            options.languageVersion = .version3_0
        }
        do {
            let lib = try device.makeLibrary(source: source, options: options)
            diagnostics("[MTKCore] Compiled shaders at runtime as a fallback")
            return lib
        } catch {
            diagnostics("[MTKCore] Runtime shader compilation failed: \(error)")
            return nil
        }
    }

    static func concatenatedShaderSources() -> String? {
        var urls = Bundle.module.urls(forResourcesWithExtension: "metal",
                                      subdirectory: "Shaders") ?? []
        if let rootVolumeShader = Bundle.module.url(forResource: "VolumeRendering",
                                                    withExtension: "metal") {
            urls.append(rootVolumeShader)
        }
        guard !urls.isEmpty else { return nil }
        let joined = urls.compactMap { try? String(contentsOf: $0) }
        guard !joined.isEmpty else { return nil }
        return joined.joined(separator: "\n\n")
    }
}
#endif
