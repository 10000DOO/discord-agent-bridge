import Foundation
@testable import DiscordAgentBridge

/// Deterministic turn gate for bridge tests. A fake server calls `submit()` to suspend a turn's
/// completion until the test calls `release()`. Tracks the concurrency high-water (`maxConcurrent`)
/// so a reentrancy bug (two turns in flight on one session) is caught WITHOUT any timing/sleep
/// assertion: correct serialization keeps it at 1.
actor TurnGate {
    enum Outcome: Sendable, Equatable {
        case ok               // finish the turn successfully (fake echoes the turn's own text)
        case fail(String)     // finish with a backend error carrying this message
    }

    private var pending: [CheckedContinuation<Outcome, Never>] = []
    private var waiters: [(need: Int, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var received = 0
    private(set) var maxConcurrent = 0

    /// Fake side: suspend the turn until the test releases it.
    func submit() async -> Outcome {
        await withCheckedContinuation { c in
            pending.append(c)
            received += 1
            maxConcurrent = max(maxConcurrent, pending.count)
            wake()
        }
    }

    /// Test side: suspend until at least `n` turns have reached the fake (no sleep).
    func waitReceived(_ n: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if received >= n { c.resume() } else { waiters.append((n, c)) }
        }
    }

    /// Test side: release the oldest in-flight turn.
    func release(_ outcome: Outcome = .ok) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: outcome)
    }

    private func wake() {
        waiters.removeAll { w in
            if received >= w.need { w.cont.resume(); return true }
            return false
        }
    }
}

/// A `SessionStore` backed by a unique temp file — isolates each bridge test from the shared store
/// and the real state file.
func freshTempStore() -> SessionStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-bridge-store-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("swift-state.json", isDirectory: false)
    return SessionStore(fileURL: url)
}

/// Records clients built by an injected `makeClient` factory: count (respawn) + last (close/isClosed).
final class MadeClients<C>: @unchecked Sendable {
    private let box = LockedBox<[C]>([])
    @discardableResult func record(_ c: C) -> C { box.withLock { $0.append(c) }; return c }
    var count: Int { box.withLock { $0.count } }
    func last() -> C? { box.withLock { $0.last } }
}
