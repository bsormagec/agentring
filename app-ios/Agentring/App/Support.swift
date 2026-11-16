import Foundation
import os

/// Loggers (`os.Logger` is spelled out: LiveKit also exports a `Logger`).
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.agentring.app"
    static let app = os.Logger(subsystem: subsystem, category: "app")
    static let calls = os.Logger(subsystem: subsystem, category: "calls")
    static let push = os.Logger(subsystem: subsystem, category: "push")
    static let relay = os.Logger(subsystem: subsystem, category: "relay")
}

/// Runs `block` on the main actor, always asynchronously and in FIFO order (system
/// callbacks arrive on other queues, and a delegate callback must not re-enter).
func onMain(_ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { block() }
    }
}

/// Milliseconds since the epoch, the relay's time unit.
func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

struct DeadlineExceeded: Error, LocalizedError {
    var errorDescription: String? { "Timed out" }
}

/// Returns `operation`'s result, or throws `DeadlineExceeded` after `seconds` (and
/// cancels the operation). Unlike a task group, it doesn't wait for an operation that
/// ignores cancellation.
func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = OnceGate()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.claim() {
                work.cancel()
                continuation.resume(throwing: DeadlineExceeded())
            }
        }
    }
}

/// True for the first caller only.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
