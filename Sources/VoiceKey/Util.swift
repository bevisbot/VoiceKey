import Foundation

struct TimeoutError: Error, LocalizedError {
    var errorDescription: String? { "操作超时" }
}

/// 给任意异步操作加"总时长上限"。超时即抛 TimeoutError(并取消该操作),
/// 用于防止本地转写等无限挂起。
func withTimeout<T: Sendable>(_ seconds: Double,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
