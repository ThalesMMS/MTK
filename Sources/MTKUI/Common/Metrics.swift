import Foundation

public protocol MetricsProtocol: Sendable {
    func incrementCounter(_ name: String, by amount: Int)
    func trackTiming(_ category: String, interval: TimeInterval, name: String?)
}

public struct MetricTiming: Sendable, Equatable {
    public let name: String?
    public let interval: TimeInterval

    public init(name: String?, interval: TimeInterval) {
        self.name = name
        self.interval = interval
    }
}

public final class Metrics: @unchecked Sendable, MetricsProtocol {
    public static let shared = Metrics()

    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var timingsByCategory: [String: [MetricTiming]] = [:]
    private let maxTimingsPerCategory = 256

    private init() {}

    public func incrementCounter(_ name: String, by amount: Int = 1) {
        lock.lock()
        counters[name, default: 0] += amount
        lock.unlock()
    }

    public func trackTiming(_ category: String, interval: TimeInterval, name: String?) {
        lock.lock()
        var timings = timingsByCategory[category, default: []]
        timings.append(MetricTiming(name: name, interval: interval))
        if timings.count > maxTimingsPerCategory {
            timings.removeFirst(timings.count - maxTimingsPerCategory)
        }
        timingsByCategory[category] = timings
        lock.unlock()
    }

    @_spi(Testing)
    public func timings(for category: String) -> [MetricTiming] {
        lock.lock()
        defer { lock.unlock() }
        return timingsByCategory[category, default: []]
    }
}
