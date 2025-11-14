//
//  Logger.swift
//  MTK
//
//  Comprehensive logging infrastructure with configurable levels and file output.
//  Migrated from MTK-Demo and enhanced for reuse across all MTK consumers.
//  Thales Matheus Mendonça Santos — November 2025
//

import Foundation

/// Comprehensive logger with level filtering, file output, and thread-safe operation.
///
/// This logger provides advanced logging capabilities beyond standard OSLog:
/// - Configurable minimum log level filtering
/// - Automatic file output to Library/Logs directory
/// - Console output control
/// - ISO8601 timestamped entries
/// - Source location tracking (file, line, function)
/// - Category-based organization
/// - Thread-safe async logging
///
/// ## Usage
///
/// ```swift
/// // Use shared instance with default configuration
/// MTKCore.Logger.log("Rendering started", level: .info)
///
/// // Configure logging behavior
/// MTKCore.Logger.configure(minimumLevel: .debug, logToConsole: true)
///
/// // Log with category
/// MTKCore.Logger.log("Texture created", level: .debug, category: "Metal")
///
/// // Create scoped loggers
/// let transferLogger = MTKCore.Logger(subsystem: "com.mtk.volumerendering", category: "TransferFunction")
/// transferLogger.error("Failed to build texture")
/// ```
public final class Logger {

    /// Log severity levels in ascending order of importance.
    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case debug = 0
        case info  = 1
        case warn  = 2
        case error = 3

        /// Human-readable tag for log output
        public var tag: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO"
            case .warn:  return "WARN"
            case .error: return "ERROR"
            }
        }

        public static func < (lhs: Logger.Level, rhs: Logger.Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Logger configuration options.
    public struct Configuration: Sendable {
        /// Minimum log level to record (messages below this level are ignored)
        public var minimumLevel: Level

        /// Whether to print log messages to console (stdout)
        public var logToConsole: Bool

        /// Default configuration varies by build type
        public static var `default`: Configuration {
            #if DEBUG
            return Configuration(minimumLevel: .debug, logToConsole: true)
            #else
            return Configuration(minimumLevel: .info, logToConsole: true)
            #endif
        }

        public init(minimumLevel: Level, logToConsole: Bool) {
            self.minimumLevel = minimumLevel
            self.logToConsole = logToConsole
        }
    }

    /// Shared logger instance configured with default settings
    public static let shared = Logger()

    private static let backend = Backend(configuration: .default)

    private let contextualCategory: String?

    /// Create a scoped logger that automatically applies subsystem/category labels to each message.
    /// - Parameters:
    ///   - subsystem: Optional subsystem identifier
    ///   - category: Optional category identifier
    public init(subsystem: String? = nil, category: String? = nil) {
        if let subsystem, let category {
            self.contextualCategory = subsystem.isEmpty ? category : "\(subsystem).\(category)"
        } else {
            self.contextualCategory = subsystem ?? category
        }
    }

    // MARK: - Configuration

    /// Reconfigure the shared logger instance.
    public static func configure(minimumLevel: Level? = nil, logToConsole: Bool? = nil) {
        backend.configure(minimumLevel: minimumLevel, logToConsole: logToConsole)
    }

    // MARK: - Static Logging API

    /// Log a message with specified level and metadata.
    public static func log(_ message: String,
                           level: Level = .info,
                           category: String? = nil,
                           writeToFile: Bool = true,
                           file: String = #fileID,
                           line: Int = #line,
                           function: String = #function) {
        backend.enqueueLog(message,
                           level: level,
                           category: category,
                           writeToFile: writeToFile,
                           file: file,
                           line: line,
                           function: function)
    }

    /// Log a debug message.
    public static func debug(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .debug, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Log an info message.
    public static func info(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .info, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Log a warning message.
    public static func warn(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .warn, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Backwards compatible alias for warn(_:).
    public static func warning(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        warn(message, category: category, file: file, line: line, function: function)
    }

    /// Backwards compatible alias for severe/fault-level messages.
    public static func fault(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        error(message, category: category, file: file, line: line, function: function)
    }

    /// Log an error message.
    public static func error(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .error, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Log a message only to file (no console output).
    public static func logOnlyToFile(_ message: String,
                                      level: Level = .info,
                                      category: String? = nil) {
        log(message, level: level, category: category, writeToFile: true)
    }

    // MARK: - Instance Logging API

    /// Log a message using the scoped logger configuration.
    public func log(_ message: String,
                    level: Level = .info,
                    category: String? = nil,
                    writeToFile: Bool = true,
                    file: String = #fileID,
                    line: Int = #line,
                    function: String = #function) {
        Logger.backend.enqueueLog(message,
                                  level: level,
                                  category: category ?? contextualCategory,
                                  writeToFile: writeToFile,
                                  file: file,
                                  line: line,
                                  function: function)
    }

    /// Log a debug message using the scoped logger configuration.
    public func debug(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .debug, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Log an info message using the scoped logger configuration.
    public func info(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .info, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Log a warning message using the scoped logger configuration.
    public func warn(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .warn, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Backwards compatible alias for warn(_:).
    public func warning(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        warn(message, category: category, file: file, line: line, function: function)
    }

    /// Backwards compatible alias for severe/fault-level messages.
    public func fault(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        error(message, category: category, file: file, line: line, function: function)
    }

    /// Log an error message using the scoped logger configuration.
    public func error(_ message: String, category: String? = nil, file: String = #fileID, line: Int = #line, function: String = #function) {
        log(message, level: .error, category: category, writeToFile: true, file: file, line: line, function: function)
    }

    /// Get the path to the current log file.
    public static var logFilePath: String {
        backend.logFilePath
    }

    /// Get the path to the logs directory.
    public static var logDirectoryPath: String {
        backend.logDirectoryPath
    }

    // MARK: - Shared Timestamp Formatter

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Logger {
    /// Backend responsible for coordinating asynchronous logging work.
    final class Backend {
        private var minimumLevel: Level
        private var logToConsole: Bool

        private let queue = DispatchQueue(label: "com.mtk.core.logger", qos: .utility)
        private let logDirectory: URL
        private let logFileURL: URL
        private var fileHandle: FileHandle?

        init(configuration: Configuration) {
            self.minimumLevel = configuration.minimumLevel
            self.logToConsole = configuration.logToConsole

            let fm = FileManager.default
            if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
                logDirectory = library.appendingPathComponent("Logs", isDirectory: true)
            } else {
                logDirectory = fm.temporaryDirectory.appendingPathComponent("Logs", isDirectory: true)
            }

            if !fm.fileExists(atPath: logDirectory.path) {
                try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            let filename = "MTK-\(formatter.string(from: Date())).log"
            logFileURL = logDirectory.appendingPathComponent(filename)

            if !fm.fileExists(atPath: logFileURL.path) {
                fm.createFile(atPath: logFileURL.path, contents: nil)
            }

            fileHandle = FileHandle(forWritingAtPath: logFileURL.path)

            let bootstrapMessage = "MTK Logger initialized → \(logFileURL.lastPathComponent)"
            write(message: bootstrapMessage, level: .info, includeConsole: configuration.logToConsole)
        }

        deinit {
            fileHandle?.closeFile()
        }

        func configure(minimumLevel: Level?, logToConsole: Bool?) {
            queue.async {
                if let min = minimumLevel {
                    self.minimumLevel = min
                }
                if let console = logToConsole {
                    self.logToConsole = console
                }
            }
        }

        func enqueueLog(_ message: String,
                        level: Level,
                        category: String?,
                        writeToFile: Bool,
                        file: String,
                        line: Int,
                        function: String) {
            queue.async {
                guard level >= self.minimumLevel else { return }

                let timestamp = Logger.timestampFormatter.string(from: Date())
                let categoryTag = category.map { "[\($0)] " } ?? ""
                let caller = "\(file)#L\(line)"
                let payload = "[\(timestamp)][\(level.tag)] \(categoryTag)\(message) (\(function) @ \(caller))"

                if self.logToConsole {
                    print(payload)
                }

                if writeToFile {
                    self.write(message: payload, level: level, includeConsole: false)
                }
            }
        }

        var logFilePath: String {
            logFileURL.path
        }

        var logDirectoryPath: String {
            logDirectory.path
        }

        private func write(message: String, level _: Level, includeConsole: Bool) {
            let line = "\(message)\n"
            if includeConsole {
                print(line, terminator: "")
            }

            guard let data = line.data(using: .utf8) else { return }

            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                do {
                    try data.write(to: logFileURL)
                    fileHandle = FileHandle(forWritingAtPath: logFileURL.path)
                    fileHandle?.seekToEndOfFile()
                } catch {
                    print("MTK Logger failed writing to file: \(error)")
                }
            }
        }
    }
}
