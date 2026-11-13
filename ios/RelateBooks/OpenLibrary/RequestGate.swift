import Foundation

/// A FIFO async lock with an optional minimum spacing between starts (D2,
/// D13). `OpenLibraryClient` uses 1.05 s (Open Library's anonymous rate);
/// `PlaceLocator` uses `.zero`, so geocoder requests are merely serial.
///
/// - `acquire()` waits for the caller's turn, then sleeps until
///   `max(lastStart + minimumInterval, notBefore)` and returns holding the
///   gate. A caller cancelled while queued or while sleeping throws
///   `CancellationError` and never holds the gate (or releases it).
/// - Every continuation is resumed exactly once: `release()` and
///   `cancelWaiter` both remove the waiter from `waiters` before resuming
///   it, so whichever runs second finds nothing to do.
/// - Callers release through `withGate` (a `defer` block cannot `await`).
actor RequestGate {
    private let minimumInterval: Duration
    private let clock: ContinuousClock
    private var isHeld = false
    private var nextID: UInt64 = 0
    private var order: [UInt64] = []
    private var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var lastStart: ContinuousClock.Instant?
    private var notBefore: ContinuousClock.Instant?

    init(minimumInterval: Duration = .zero, clock: ContinuousClock = ContinuousClock()) {
        self.minimumInterval = minimumInterval
        self.clock = clock
    }

    /// Callers currently queued (not holding the gate). Tests.
    var waiterCount: Int { order.count }

    /// Waits for this caller's turn (FIFO), then for the minimum spacing,
    /// and returns holding the gate.
    func acquire() async throws {
        if !isHeld && order.isEmpty {
            isHeld = true
        } else {
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters[id] = continuation
                    order.append(id)
                    if Task.isCancelled { cancelWaiter(id) }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        // Ownership passed to this caller (fast path, or resumed by `release`).
        do {
            try Task.checkCancellation()
            var earliest = lastStart.map { $0 + minimumInterval }
            if let notBefore { earliest = max(earliest ?? notBefore, notBefore) }
            if let earliest, earliest > clock.now { try await clock.sleep(until: earliest) }
        } catch {
            release()
            throw error
        }
        lastStart = clock.now
    }

    /// Releases the gate: ownership passes to the first live waiter, if any.
    func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        isHeld = false
    }

    /// Pushes the next allowed start to at least now + `delay` (a 429/503
    /// with Retry-After, D3).
    func delayNextStart(by delay: Duration) {
        let target = clock.now + delay
        notBefore = max(notBefore ?? target, target)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}

extension RequestGate {
    /// Runs `body` holding the gate, in the caller's isolation (so a
    /// non-Sendable closure from an actor or a struct method is fine), and
    /// releases it on every exit: success, throw or cancellation.
    func withGate<T: Sendable>(isolation: isolated (any Actor)? = #isolation,
                               _ body: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
