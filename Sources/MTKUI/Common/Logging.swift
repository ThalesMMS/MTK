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

    public init(subsystem: String = "com.mtk.ui", category: String) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, error: (any Error)? = nil) {
        if let error {
            logger.debug("\(message) error=\(String(describing: error))")
        } else {
            logger.debug("\(message)")
        }
    }

    public func info(_ message: String) {
        logger.info("\(message)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message)")
    }

    public func error(_ message: String, error: (any Error)? = nil) {
        if let error {
            logger.error("\(message) error=\(String(describing: error))")
        } else {
            logger.error("\(message)")
        }
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
