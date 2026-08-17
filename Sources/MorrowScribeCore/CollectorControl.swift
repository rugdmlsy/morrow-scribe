import Foundation

public final class CollectorControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var deadline: Date?

    public init() {}

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public func setDeadline(_ date: Date?) {
        lock.lock()
        deadline = date
        lock.unlock()
    }

    public var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped || deadline.map { Date() >= $0 } == true
    }
}
