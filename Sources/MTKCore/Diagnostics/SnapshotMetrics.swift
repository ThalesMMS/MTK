//
//  SnapshotMetrics.swift
//  MTK
//
//  Metrics for explicit GPU-to-CPU snapshot readback operations.
//

import Foundation

@preconcurrency import Metal

/// Timing and texture details for one explicit snapshot/export readback.
///
/// Snapshot metrics are intentionally separate from render-frame timing because
/// readback is an export cost, not part of the interactive presentation path.
public struct SnapshotMetrics: Sendable, Equatable {
    public let label: String
    public let readbackDuration: TimeInterval
    public let byteCount: Int
    public let textureWidth: Int
    public let textureHeight: Int
    public let pixelFormat: MTLPixelFormat

    public init(label: String,
                readbackDuration: TimeInterval,
                byteCount: Int,
                textureWidth: Int,
                textureHeight: Int,
                pixelFormat: MTLPixelFormat) {
        self.label = label
        self.readbackDuration = max(0, readbackDuration)
        self.byteCount = byteCount
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.pixelFormat = pixelFormat
    }

    public var readbackMilliseconds: Double {
        readbackDuration * 1000.0
    }

    var formattedSummary: String {
        "readback=\(String(format: "%.3f", readbackMilliseconds)) ms | bytes=\(byteCount) | texture=\(textureWidth)x\(textureHeight) \(pixelFormat)"
    }
}
