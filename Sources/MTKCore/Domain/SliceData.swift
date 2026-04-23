//
//  SliceData.swift
//  MTK
//
//  Async DICOM slice stream primitives.
//

import Foundation

public struct SliceData: Sendable, Equatable {
    public let index: Int
    public let rawBytes: Data
    public let slope: Double
    public let intercept: Double
    public let isSigned: Bool

    public init(index: Int,
                rawBytes: Data,
                slope: Double,
                intercept: Double,
                isSigned: Bool) {
        self.index = index
        self.rawBytes = rawBytes
        self.slope = slope
        self.intercept = intercept
        self.isSigned = isSigned
    }
}

public typealias DicomStreamingSliceHandler = @Sendable (
    _ sliceIndex: Int,
    _ rawData: Data,
    _ slope: Double,
    _ intercept: Double,
    _ isSigned: Bool
) -> Void

public final class DicomSliceStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = SliceData
    public typealias AsyncIterator = AsyncThrowingStream<SliceData, any Error>.Iterator

    private let state: State
    private let stream: AsyncThrowingStream<SliceData, any Error>

    public init(bufferingPolicy: AsyncThrowingStream<SliceData, any Error>.Continuation.BufferingPolicy = .unbounded) {
        let state = State()
        self.state = state
        self.stream = AsyncThrowingStream(SliceData.self, bufferingPolicy: bufferingPolicy) { continuation in
            state.set(continuation: continuation)
            continuation.onTermination = { @Sendable termination in
                state.markTerminated(termination)
            }
        }
    }

    public var sliceHandler: DicomStreamingSliceHandler {
        { [weak self] sliceIndex, rawData, slope, intercept, isSigned in
            self?.yield(
                SliceData(index: sliceIndex,
                          rawBytes: rawData,
                          slope: slope,
                          intercept: intercept,
                          isSigned: isSigned)
            )
        }
    }

    public var isCancelled: Bool {
        state.isCancelled
    }

    public func yield(_ slice: SliceData) {
        state.yield(slice)
    }

    public func finish() {
        state.finish()
    }

    public func finish(throwing error: any Error) {
        state.finish(throwing: error)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<SliceData, any Error>.Continuation?
    private var terminated = false
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(continuation: AsyncThrowingStream<SliceData, any Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ slice: SliceData) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminated, !cancelled, let continuation else {
            return
        }
        continuation.yield(slice)
    }

    func finish() {
        finish(throwing: nil)
    }

    func finish(throwing error: (any Error)?) {
        lock.lock()
        guard !terminated else {
            lock.unlock()
            return
        }
        terminated = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    func markTerminated(_ termination: AsyncThrowingStream<SliceData, any Error>.Continuation.Termination) {
        lock.lock()
        terminated = true
        if case .cancelled = termination {
            cancelled = true
        }
        continuation = nil
        lock.unlock()
    }
}
