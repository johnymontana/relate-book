/// Keeps the CPU-heavy tests (the Core ML embedder tests and the perf
/// suite) from running at the same time: Swift Testing runs suites in
/// parallel, and the perf budget is wall-clock engine time.
actor HeavyTestGate {
    static let shared = HeavyTestGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    static func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await shared.acquire()
        do {
            let value = try await body()
            await shared.release()
            return value
        } catch {
            await shared.release()
            throw error
        }
    }
}
