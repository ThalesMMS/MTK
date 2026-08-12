import Foundation
import XCTest

@testable import MTKCore

/// The strings and error shapes here are copied verbatim from a run of this suite with
/// six concurrent processes on one device. They are the whole basis for telling another
/// process's GPU fault from our own, so they are pinned rather than remembered.
final class GPUFaultAttributionTests: XCTestCase {
    private static let discardDescription =
        "Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"

    private static func discardError() -> NSError {
        NSError(domain: "MTLCommandBufferErrorDomain",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: discardDescription,
                    NSUnderlyingErrorKey: NSError(domain: "IOGPUCommandQueueErrorDomain",
                                                  code: 5,
                                                  userInfo: nil)
                ])
    }

    func testRecognisesTheDriversDiscardError() {
        XCTAssertTrue(GPUFaultAttribution.isInnocentVictimDiscard(Self.discardError()))
    }

    /// `VolumeRaycastPass` keeps only a description of the underlying error, so the
    /// attribution has to survive the wrapping.
    func testRecognisesTheDiscardAfterVolumeRaycastPassWrapsIt() {
        let wrapped = VolumeRaycastPassError.commandBufferExecutionFailed(
            underlyingDescription: "MTLCommandBufferStatus(rawValue: 5): \(Self.discardDescription)"
        )
        XCTAssertTrue(GPUFaultAttribution.isInnocentVictimDiscard(wrapped))
    }

    func testRecognisesTheDiscardFromItsUnderlyingErrorAlone() {
        let withoutMarker = NSError(domain: "MTLCommandBufferErrorDomain",
                                    code: 1,
                                    userInfo: [
                                        NSUnderlyingErrorKey: NSError(domain: "IOGPUCommandQueueErrorDomain",
                                                                      code: 5,
                                                                      userInfo: nil)
                                    ])
        XCTAssertTrue(GPUFaultAttribution.isInnocentVictimDiscard(withoutMarker))
    }

    func test_didNotCompleteWithoutAnNSError_isTreatedAsDiscarded() {
        XCTAssertTrue(
            GPUFaultAttribution.isInnocentVictimDiscard(
                RaycasterTestHelpers.CommandBufferError.didNotComplete(status: 5)
            )
        )
    }

    func testDoesNotBlameTheDriverForOurOwnFailures() {
        let ourFault = NSError(domain: "MTLCommandBufferErrorDomain",
                               code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "Caused GPU Timeout Error"])
        XCTAssertFalse(GPUFaultAttribution.isInnocentVictimDiscard(ourFault))
        XCTAssertFalse(GPUFaultAttribution.isInnocentVictimDiscard(
            VolumeRaycastPassError.commandBufferCreationFailed
        ))
    }

    func testRethrowsWhatIsOursAndSkipsWhatIsNot() {
        XCTAssertThrowsError(
            try GPUFaultAttribution.rethrowUnlessDiscarded(VolumeRaycastPassError.commandBufferCreationFailed,
                                                           while: "test")
        ) { error in
            XCTAssertNil(error as? XCTSkip, "our own failure must not be turned into a skip")
        }

        XCTAssertThrowsError(
            try GPUFaultAttribution.rethrowUnlessDiscarded(Self.discardError(), while: "test")
        ) { error in
            XCTAssertNotNil(error as? XCTSkip, "another process's GPU fault must become a skip")
        }
    }
}
