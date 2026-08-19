import Foundation

/// Compatibility replacement for `@TaskLocal` in environments where macro expansion fails.
///
/// This preserves scoped push/pop semantics and is sufficient for single-task usage paths.
final class ScopedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stack: [Value] = []
    private let defaultValue: @Sendable () -> Value

    init(default defaultValue: @escaping @Sendable () -> Value) {
        self.defaultValue = defaultValue
    }

    var current: Value {
        lock.withLock {
            stack.last ?? defaultValue()
        }
    }

    func withValue<R>(_ value: Value, operation: () throws -> R) rethrows -> R {
        lock.withLock {
            stack.append(value)
        }
        defer {
            lock.withLock {
                _ = stack.popLast()
            }
        }
        return try operation()
    }

    func withValue<R>(_ value: Value, operation: () async throws -> R) async rethrows -> R {
        lock.withLock {
            stack.append(value)
        }
        defer {
            lock.withLock {
                _ = stack.popLast()
            }
        }
        return try await operation()
    }
}
