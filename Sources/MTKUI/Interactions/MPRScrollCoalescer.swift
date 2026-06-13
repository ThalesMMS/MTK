//
//  MPRScrollCoalescer.swift
//  MTKUI
//
//  Per-axis scroll-wheel step accumulator. Scroll events can arrive faster
//  than a slice render completes; queueing one Task per event builds an
//  unbounded MainActor backlog. The coalescer banks incoming steps and a
//  single drain task delivers the accumulated total per apply, so fast
//  scrolls collapse into few applies without losing any steps.
//

#if canImport(SwiftUI) && (os(iOS) || os(macOS))
import Foundation

@MainActor
public final class MPRScrollCoalescer {
    private var pendingSteps = 0
    private var drainTask: Task<Void, Never>?
    private let apply: @MainActor (Int) async -> Void

    public init(apply: @escaping @MainActor (Int) async -> Void) {
        self.apply = apply
    }

    public func add(steps: Int) {
        guard steps != 0 else { return }
        pendingSteps += steps
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while !Task.isCancelled {
                let take = pendingSteps
                pendingSteps = 0
                guard take != 0 else { break }
                await apply(take)
            }
            // A cancelled task must not clear a successor installed by add().
            if !Task.isCancelled {
                drainTask = nil
            }
        }
    }

    public func cancel() {
        drainTask?.cancel()
        drainTask = nil
        pendingSteps = 0
    }

    var pendingStepsForTesting: Int { pendingSteps }

    var isDrainingForTesting: Bool { drainTask != nil }
}
#endif
