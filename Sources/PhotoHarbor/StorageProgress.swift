import Foundation

/// Tracks each in-flight job independently. Once a job stalls, the batch
/// drains its in-flight work without admitting more filesystem operations.
final class StorageProgress: @unchecked Sendable {
    private struct Job {
        var label: String
        var lastProgress: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private let timeout: Duration
    private var jobs: [UUID: Job] = [:]
    private var stalledJob: String?

    init(timeout: Duration) { self.timeout = timeout }

    func begin(_ label: String, now: ContinuousClock.Instant = .now) throws -> UUID {
        try lock.withLock {
            try checkLocked(now)
            let id = UUID()
            jobs[id] = Job(label: label, lastProgress: now)
            return id
        }
    }

    func check(now: ContinuousClock.Instant = .now) throws {
        try lock.withLock { try checkLocked(now) }
    }

    func advance(_ id: UUID, label: String? = nil, now: ContinuousClock.Instant = .now) throws {
        try lock.withLock {
            try checkLocked(now)
            jobs[id]?.lastProgress = now
            if let label { jobs[id]?.label = label }
        }
    }

    func finish(_ id: UUID) {
        lock.withLock {
            // Capture late replies even when they arrive between watchdog ticks.
            _ = stalledLocked(.now)
            jobs[id] = nil
        }
    }

    func stalled(now: ContinuousClock.Instant = .now) -> String? {
        lock.withLock { stalledLocked(now) }
    }

    private func checkLocked(_ now: ContinuousClock.Instant) throws {
        if let label = stalledLocked(now) {
            throw LibraryError.message("「\(label)」等待超时，已停止安排后续操作。")
        }
    }

    private func stalledLocked(_ now: ContinuousClock.Instant) -> String? {
        if stalledJob == nil {
            stalledJob = jobs.values.min(by: { $0.lastProgress < $1.lastProgress })
                .flatMap { $0.lastProgress.duration(to: now) >= timeout ? $0.label : nil }
        }
        return stalledJob
    }
}
