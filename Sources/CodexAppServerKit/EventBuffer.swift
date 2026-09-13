import Foundation

/// Synchronous producers and an asynchronous consumer share one bounded queue.
/// Every mutable field is protected by `lock`; callbacks never run under that lock.
final class CodexEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: CodexBufferingPolicy
    private let maximumCoalescedBytes: Int
    private let onTermination: @Sendable () -> Void
    private var queue: [CodexEvent] = []
    private var waiter: CheckedContinuation<CodexEvent?, Error>?
    private var ended = false
    private var failure: Error?

    init(policy: CodexBufferingPolicy, maximumCoalescedBytes: Int, onTermination: @escaping @Sendable () -> Void) {
        self.policy = policy
        self.maximumCoalescedBytes = maximumCoalescedBytes
        self.onTermination = onTermination
    }

    func yield(_ event: CodexEvent) -> Bool {
        var receiver: CheckedContinuation<CodexEvent?, Error>?
        var terminated = false
        let accepted = lock.withLock {
            guard !ended else { return false }
            if let waiting = waiter { receiver = waiting; waiter = nil; return true }
            let capacity: Int
            switch policy {
            case .unbounded: queue.append(event); return true
            case .boundedFailing(let count), .boundedCoalescingDeltas(let count): capacity = max(1, count)
            }
            if queue.count < capacity { queue.append(event); return true }
            if case .boundedCoalescingDeltas = policy,
               let previous = queue.last,
               let merged = Self.merge(previous, event, maximumBytes: maximumCoalescedBytes) {
                queue[queue.count - 1] = merged
                return true
            }
            // Never discard incremental content or reorder events to make room.
            ended = true
            failure = CodexSubscriptionError.bufferOverflow
            terminated = true
            return false
        }
        receiver?.resume(returning: event)
        if terminated { onTermination() }
        return accepted
    }

    func next() async throws -> CodexEvent? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if !queue.isEmpty { continuation.resume(returning: queue.removeFirst()) }
                    else if ended {
                        if let failure { continuation.resume(throwing: failure) }
                        else { continuation.resume(returning: nil) }
                    } else if waiter != nil {
                        continuation.resume(throwing: CodexError.invalidConfiguration("A subscription supports one event iterator"))
                    } else { waiter = continuation }
                }
            }
        } onCancel: {
            self.finish(throwing: CancellationError())
        }
    }

    func finish(throwing error: Error? = nil) {
        var receiver: CheckedContinuation<CodexEvent?, Error>?
        let changed = lock.withLock {
            guard !ended else { return false }
            ended = true; failure = error
            receiver = waiter; waiter = nil
            return true
        }
        if let error { receiver?.resume(throwing: error) }
        else { receiver?.resume(returning: nil) }
        if changed { onTermination() }
    }

    private static func merge(_ previous: CodexEvent, _ next: CodexEvent, maximumBytes: Int) -> CodexEvent? {
        guard case .itemDelta(let thread, let item, let method, let oldRaw) = previous,
              case .itemDelta(let nextThread, let nextItem, let nextMethod, let newRaw) = next,
              thread == nextThread, let item, item == nextItem, method == nextMethod,
              var old = oldRaw.objectValue, var new = newRaw.objectValue,
              let prefix = old.removeValue(forKey: "delta")?.stringValue,
              let suffix = new.removeValue(forKey: "delta")?.stringValue,
              old == new else { return nil }
        // Comparing all other fields also preserves turn IDs and reasoning segment indices.
        guard prefix.utf8.count + suffix.utf8.count <= maximumBytes else { return nil }
        old["delta"] = .string(prefix + suffix)
        return .itemDelta(threadID: thread, itemID: item, method: method, delta: .object(old))
    }
}

/// The stream owns this lifetime token; the client only owns its buffer.
final class CodexEventStreamLifetime: Sendable {
    let buffer: CodexEventBuffer
    init(buffer: CodexEventBuffer) { self.buffer = buffer }
    deinit { buffer.finish() }
}
