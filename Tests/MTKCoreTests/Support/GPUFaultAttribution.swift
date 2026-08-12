import Foundation
import XCTest

/// Tells our GPU failures apart from somebody else's.
///
/// When any process on the machine causes a GPU error, the driver's recovery discards
/// every command buffer that merely happened to be in flight — ours included. It calls
/// them innocent victims, and it means it: the buffer never ran. A test that reports that
/// as its own failure is reporting the load on the machine, not the code under test.
enum GPUFaultAttribution {
    /// The marker the driver leaves on a discarded buffer. Copied from a real failure
    /// under six concurrent runs of this suite:
    ///
    ///     Error Domain=MTLCommandBufferErrorDomain Code=1 "Discarded (victim of GPU
    ///     error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"
    ///     UserInfo={..., NSUnderlyingError={Error Domain=IOGPUCommandQueueErrorDomain
    ///     Code=5 "(null)"}}
    ///
    /// It survives being wrapped: `VolumeRaycastPassError.commandBufferExecutionFailed`
    /// keeps only a description, and the marker is inside it.
    private static let innocentVictimMarker = "kIOGPUCommandBufferCallbackErrorInnocentVictim"

    private static let underlyingDiscardDomain = "IOGPUCommandQueueErrorDomain"
    private static let underlyingDiscardCode = 5

    static func isInnocentVictimDiscard(_ error: any Error) -> Bool {
        if let commandBufferError = error as? RaycasterTestHelpers.CommandBufferError,
           case .didNotComplete = commandBufferError {
            return true
        }
        if "\(error)".contains(innocentVictimMarker) {
            return true
        }
        let nsError = error as NSError
        if nsError.localizedDescription.contains(innocentVictimMarker) {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return underlying.domain == underlyingDiscardDomain && underlying.code == underlyingDiscardCode
    }

    /// Rethrows `error`, unless another process's GPU fault caused it — then the test is
    /// skipped, because there is nothing left to measure and nothing of ours to blame.
    static func rethrowUnlessDiscarded(_ error: any Error,
                                       while activity: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws -> Never {
        guard isInnocentVictimDiscard(error) else {
            throw error
        }
        throw XCTSkip("\(activity): the driver discarded our command buffer as the innocent victim of another process's GPU error",
                      file: file,
                      line: line)
    }
}
