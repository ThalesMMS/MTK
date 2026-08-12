//
//  HistogramCoverage.swift
//  MTK
//
//  Checks that a GPU histogram accounts for every voxel it was asked about.
//

import Foundation

/// Verifies that a histogram read back from the GPU covers the whole volume.
///
/// The histogram kernels bin every voxel inside the grid and clamp the bin index, so no
/// voxel is ever dropped: the counts of one channel must add up to the voxel count,
/// exactly. Nothing used to check that, which is how a command buffer that completed
/// without an error but produced no counts at all could be read back as a valid — and
/// entirely zero — histogram. Auto-windowing would then pick a window from an empty
/// distribution, and a test would report it as a wrong number rather than as a failed
/// computation.
@_spi(Testing) public enum HistogramCoverage {
    /// Describes a channel whose counts do not add up to the voxel count.
    public struct Shortfall: Equatable {
        /// Index of the first channel found wanting.
        public let channel: Int

        /// Counts the channel actually reported.
        public let counted: Int

        /// Counts it had to report.
        public let expected: Int

        public init(channel: Int, counted: Int, expected: Int) {
            self.channel = channel
            self.counted = counted
            self.expected = expected
        }
    }

    /// Returns the first channel whose counts disagree with the voxel count, or `nil`
    /// when every channel accounts for the whole volume.
    ///
    /// - Parameters:
    ///   - histograms: One array of bin counts per channel, as read back from the GPU.
    ///   - expectedVoxelCount: Number of voxels the dispatch covered — `width * height * depth`.
    ///
    /// The check is skipped for a volume large enough to overflow the kernel's 32-bit
    /// counters, where a total that disagrees would say nothing about the dispatch.
    public static func shortfall(in histograms: [[UInt32]],
                                 expectedVoxelCount: Int) -> Shortfall? {
        guard expectedVoxelCount > 0, expectedVoxelCount <= Int(UInt32.max) else {
            return nil
        }

        for (channel, histogram) in histograms.enumerated() {
            let counted = histogram.reduce(0) { $0 + Int($1) }
            if counted != expectedVoxelCount {
                return Shortfall(channel: channel, counted: counted, expected: expectedVoxelCount)
            }
        }

        return nil
    }

    /// Same check for a histogram whose rows are bins rather than channels, where the
    /// volume is accounted for by the grand total instead of by each row.
    public static func totalShortfall(in bins: [[UInt32]],
                                      expectedVoxelCount: Int) -> Shortfall? {
        guard expectedVoxelCount > 0, expectedVoxelCount <= Int(UInt32.max) else {
            return nil
        }

        let counted = bins.reduce(0) { running, row in
            running + row.reduce(0) { $0 + Int($1) }
        }
        guard counted != expectedVoxelCount else { return nil }
        return Shortfall(channel: 0, counted: counted, expected: expectedVoxelCount)
    }

    /// Number of voxels a dispatch over `width x height x depth` covers.
    public static func voxelCount(width: Int, height: Int, depth: Int) -> Int {
        max(0, width) * max(0, height) * max(1, depth)
    }
}
