import Foundation

public protocol MetricsProtocol: Sendable {
    func incrementCounter(_ name: String, by amount: Int)
    func trackTiming(_ category: String, interval: TimeInterval, name: String?)
}

public final class Metrics: @unchecked Sendable, MetricsProtocol {
    public static let shared = Metrics()

    private let lock = NSLock()
    private var counters: [String: Int] = [:]

    private init() {}

    public func incrementCounter(_ name: String, by amount: Int = 1) {
        lock.lock()
        counters[name, default: 0] += amount
        lock.unlock()
    }

    public func trackTiming(_ category: String, interval: TimeInterval, name: String?) {
        _ = (category, interval, name)
    }
}
