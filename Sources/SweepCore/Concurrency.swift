import Foundation

#if !canImport(ObjectiveC)
/// Linux has no autorelease pools (only used for test runs there); just run the body.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// A value guarded by a lock, safe to share between threads.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// Lets a long scan be stopped from the UI.
public final class CancelToken: @unchecked Sendable {
    private let flag = Locked(false)
    public init() {}
    public var isCancelled: Bool { flag.current }
    public func cancel() { flag.withLock { $0 = true } }
}

/// Runs blocking file-system work off the Swift concurrency thread pool.
public enum Background {
    public static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Maps in parallel, keeping the input order.
    public static func map<T, R>(_ input: [T], _ transform: @escaping @Sendable (T) -> R) async -> [R] {
        if input.isEmpty { return [] }
        return await run {
            let output = Locked([R?](repeating: nil, count: input.count))
            DispatchQueue.concurrentPerform(iterations: input.count) { index in
                // GCD worker threads don't drain autorelease pools per block; do it per item.
                let result = autoreleasepool { transform(input[index]) }
                output.withLock { $0[index] = result }
            }
            return output.current.map { $0! }
        }
    }
}

/// Computes each expensive shared lookup (installed apps, Homebrew state, the home-folder walk) once per scan.
public actor Memo {
    private var tasks: [String: Any] = [:]

    public init() {}

    public func value<T: Sendable>(_ key: String, _ make: @escaping @Sendable () async -> T) async -> T {
        if let task = tasks[key] as? Task<T, Never> {
            return await task.value
        }
        let task = Task<T, Never>.detached { await make() }
        tasks[key] = task
        return await task.value
    }
}
