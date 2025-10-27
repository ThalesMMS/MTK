import Foundation
import os.log

public protocol LoggerProtocol: Sendable {
    func debug(_ message: String, error: (any Error)?)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String, error: (any Error)?)
}

public final class Logger: @unchecked Sendable, LoggerProtocol {
    private let logger: os.Logger

    public init(subsystem: String = "com.isis.dicomviewer", category: String) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, error: (any Error)? = nil) {
        if let error {
            logger.debug("\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String, error: (any Error)? = nil) {
        if let error {
            logger.error("\(message, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
}

public extension Logger {
    convenience init(category: String) {
        self.init(subsystem: "com.isis.dicomviewer", category: category)
    }

    func debug(_ message: String) {
        debug(message, error: nil)
    }
}
