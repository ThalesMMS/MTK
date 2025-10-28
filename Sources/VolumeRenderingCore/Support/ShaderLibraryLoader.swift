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
        if #available(iOS 14, macOS 11, *) {
            if let bundled = try? device.makeDefaultLibrary(bundle: .module) {
                diagnostics("[VolumeRenderingCore] Loaded Bundle.module metallib")
                return bundled
            } else {
                diagnostics("[VolumeRenderingCore] Bundle.module metallib unavailable; trying fallbacks")
            }
        }

        if let main = try? device.makeDefaultLibrary() {
            diagnostics("[VolumeRenderingCore] Loaded main bundle default library")
            return main
        }

        if let url = Bundle.module.url(forResource: "VolumeRendering", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            diagnostics("[VolumeRenderingCore] Loaded VolumeRendering.metallib fallback")
            return lib
        }

        diagnostics("[VolumeRenderingCore] Unable to load Metal library; CPU fallbacks may activate")
        return nil
    }
#else
    public static func makeDefaultLibrary(on device: Any, diagnostics: (String) -> Void = { _ in }) -> Any? {
        diagnostics("[VolumeRenderingCore] Metal unavailable on this platform")
        return nil
    }
#endif
}

