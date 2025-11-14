import Foundation

/// Shared Metal resource labels mirroring the macOS target for consistency.
public enum MTL_label {
    static let main_rendering = "main_rendering"
    static let segment = "segment"
    static let export = "export"
    static let calculate_histogram = "calculate_histogram"
    static let applyFilter_gaussian3D = "applyFilter_gaussian3D"
    static let applyFilter_median3D = "applyFilter_median3D"
    static let transfer_Float = "transfer_Float"
    static let other = "other"
    static let renderingCommandBuffer = "cmd.rendering"
    static let renderingEncoder = "enc.rendering"
    static let outputPixelBuffer = "buf.outputPixels"
    static let outputTexture = "tex.output"
    static let argumentBuffer = "buf.argument"
    static let histogramBuffer = "buf.histogram"
    static let blitEncoder = "enc.blit"
    static let volumeTexture = "tex.volume.main"
    static let legacy_rendering = "legacy_rendering"
}
