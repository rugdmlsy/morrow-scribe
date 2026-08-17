import Foundation

public final class CollectorControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
