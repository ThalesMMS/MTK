import Foundation
import MTKCore
import os.log

public protocol LoggerProtocol: Sendable {
    func debug(_ message: String, error: (any Error)?)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String, error: (any Error)?)
}

public final class Logger: @unchecked Sendable, LoggerProtocol {
    private let logger: os.Logger
    private let fileCategory: String
    // Environment-backed startup toggles. Set before concurrent logging begins.
    nonisolated(unsafe) public static var interactionLoggingEnabled =
        ProcessInfo.processInfo.environment["MTK_INTERACTION_LOGGING"] == "1"
    nonisolated(unsafe) public static var mprInteractionLoggingEnabled =
        ProcessInfo.processInfo.environment["MTK_MPR_INTERACTION_LOGGING"] == "1"

    public init(subsystem: String = "com.mtk.ui", category: String) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
        self.fileCategory = "\(subsystem).\(category)"
    }

    public func debug(_ message: String, error: (any Error)? = nil) {
        let resolvedMessage: String
        if let error {
            resolvedMessage = "\(message) error=\(String(describing: error))"
        } else {
            resolvedMessage = message
        }
        logger.debug("\(resolvedMessage)")
        if mirrorsToMTKLog(resolvedMessage) {
            MTKCore.Logger.debug(resolvedMessage, category: fileCategory)
        }
    }

    public func info(_ message: String) {
        logger.info("\(message)")
        if mirrorsToMTKLog(message) {
            MTKCore.Logger.info(message, category: fileCategory)
        }
    }

    public func warning(_ message: String) {
        logger.warning("\(message)")
        if mirrorsToMTKLog(message) {
            MTKCore.Logger.warning(message, category: fileCategory)
        }
    }

    public func error(_ message: String, error: (any Error)? = nil) {
        let resolvedMessage: String
        if let error {
            resolvedMessage = "\(message) error=\(String(describing: error))"
        } else {
            resolvedMessage = message
        }
        logger.error("\(resolvedMessage)")
        if mirrorsToMTKLog(resolvedMessage) {
            MTKCore.Logger.error(resolvedMessage, category: fileCategory)
        }
    }

    private func mirrorsToMTKLog(_ message: String) -> Bool {
        if message.contains("[MTKPerf]") {
            return MTKCore.Logger.performanceLoggingEnabled
        }
        if message.contains("[MTKMPRInteraction]") {
            return Logger.mprInteractionLoggingEnabled
        }
        guard Logger.interactionLoggingEnabled else { return false }
        return message.contains("[MTK3DInteraction]")
            || message.contains("[MTKClinicalVolumeInteraction]")
    }
}

public extension Logger {
    convenience init(category: String) {
        self.init(subsystem: "com.mtk.ui", category: category)
    }

    func debug(_ message: String) {
        debug(message, error: nil)
    }
}
