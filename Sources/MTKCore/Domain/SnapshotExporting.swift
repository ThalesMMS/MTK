//
//  SnapshotExporting.swift
//  MTK
//
//  Explicit GPU-to-CPU snapshot/export boundary.
//

import CoreGraphics
import Foundation

@preconcurrency import Metal

/// Explicit snapshot/export service for rendered Metal frames.
///
/// Implementations may perform GPU-to-CPU readback and image encoding. Keep this
/// boundary out of the interactive display loop; onscreen presentation should use
/// ``VolumeRenderFrame/texture`` directly through a Metal-native surface.
public protocol SnapshotExporting: Sendable {
    /// Converts a completed render frame into a CPU-backed `CGImage`.
    ///
    /// - Important: This is an explicit GPU→CPU readback boundary.
    ///   Do not use this for interactive on-screen presentation. Interactive
    ///   rendering must remain GPU-resident as `MTLTexture` and be presented via
    ///   `MTKView`/`CAMetalLayer` (e.g. `MetalViewportSurface`).
    func makeCGImage(from frame: VolumeRenderFrame) async throws -> CGImage

    /// Writes a completed render frame as a PNG image.
    ///
    /// - Important: This is an explicit GPU→CPU readback + encoding boundary.
    ///   Keep it out of interactive rendering loops.
    ///
    /// Future export formats such as TIFF or DICOM Secondary Capture should be
    /// added as new explicit export operations instead of changing interactive
    /// presentation APIs.
    func writePNG(from frame: VolumeRenderFrame, to url: URL) async throws
}

/// Errors produced by explicit snapshot/export operations.
public enum SnapshotExportError: Error, Equatable, LocalizedError {
    /// The frame texture uses a pixel format that the snapshot exporter does not
    /// yet support.
    case unsupportedPixelFormat(MTLPixelFormat)

    /// CPU readback could not complete.
    case readbackFailed(String)

    /// CoreGraphics could not construct an image from the readback buffer.
    case imageCreationFailed

    /// ImageIO could not create a PNG destination.
    case pngDestinationCreationFailed(URL)

    /// ImageIO or the filesystem failed while writing the encoded image.
    case fileWriteFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format):
            return "Unsupported snapshot pixel format: \(format)"
        case .readbackFailed:
            return "Snapshot readback failed"
        case .imageCreationFailed:
            return "Snapshot image creation failed"
        case .pngDestinationCreationFailed:
            return "PNG destination creation failed"
        case .fileWriteFailed:
            return "PNG file write failed"
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsupportedPixelFormat:
            return "TextureSnapshotExporter currently supports bgra8Unorm and rgba8Unorm frames."
        case .readbackFailed(let description):
            return description
        case .imageCreationFailed:
            return "The readback buffer could not be wrapped in a valid CGImage."
        case .pngDestinationCreationFailed(let url):
            return "ImageIO could not create a PNG destination at \(url.path)."
        case .fileWriteFailed(let url, let description):
            return "Could not write PNG to \(url.path): \(description)"
        }
    }
}
