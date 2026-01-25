//  ShaderLibraryLoader.swift
//  MTK
//  Guarded loader for Bundle.module Metal libraries with diagnostics.
//  Thales Matheus Mendonça Santos — October 2025

import Foundation
#if canImport(Metal)
import Metal
#endif

public enum ShaderLibraryLoader {
#if canImport(Metal)
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
