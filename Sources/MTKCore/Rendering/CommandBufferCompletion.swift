//
//  CommandBufferCompletion.swift
//  MTK
//
//  Asks a finished command buffer the only question its output cannot answer.
//

import Metal

/// Tells a command buffer that ran from one that never did.
///
/// A blit, a render pass and most compute dispatches leave nothing behind that the CPU
/// can check: every byte they can produce is a legal pixel or a legal voxel, so the
/// destination looks the same whether it was written or merely allocated. Where a kernel
/// does have an invariant — a histogram covering every voxel, a prefix sum ending at the
/// total — check that instead, because it also catches a dispatch that ran and got the
/// answer wrong. Where it does not, this is what is left.
///
/// `buffer.error` alone is not it. When any process on the machine causes a GPU error,
/// the driver's recovery discards every command buffer that merely happened to be in
/// flight — ours included, as innocent victims — and a discarded buffer never runs. It
/// stops on `.error`, status raw value 5, and it can carry no error object at all:
///
///     MTLCommandBufferStatus(rawValue: 5): Discarded (victim of GPU error/recovery)
///     (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)
///
/// Only `.completed` means the work ran, so that is what gets asked.
enum CommandBufferCompletion {
    /// Why `buffer` did not run, or `nil` when it did.
    ///
    /// Safe to call before the buffer is committed: an uncommitted buffer has not run
    /// either, and says so with its own status.
    static func reasonItDidNotRun(_ buffer: any MTLCommandBuffer) -> String? {
        guard buffer.status != .completed else { return nil }
        if let error = buffer.error {
            return error.localizedDescription
        }
        return "reached status \(buffer.status.rawValue) with no error object"
    }
}
