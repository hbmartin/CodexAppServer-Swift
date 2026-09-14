import Combine
import Foundation
import Observation
import CodexAppServerKit

@MainActor @Observable
public final class CodexConnectionModel {
    public private(set) var state: CodexConnectionState = .disconnected
    @ObservationIgnored public let publisher = CurrentValueSubject<CodexConnectionState, Never>(.disconnected)
    private var task: Task<Void, Never>?
    public init() {}
    public func observe(_ client: CodexClient) async {
        task?.cancel(); state = await client.connectionState(); publisher.send(state)
        let subscription = await client.subscribe()
        task = Task { @MainActor [weak self] in
            do { for try await event in subscription.events { if case .connection(let value) = event { self?.state = value; self?.publisher.send(value) } } } catch {}
        }
    }
    public func stopObserving() { task?.cancel(); task = nil }
}

@MainActor @Observable
public final class CodexConversationCollectionModel {
    public private(set) var conversations: [CodexThread] = []
    @ObservationIgnored public let publisher = CurrentValueSubject<[CodexThread], Never>([])
    public init() {}
    public func refresh(using client: CodexClient, query: CodexThreadQuery = .init()) async throws {
        conversations = try await client.listThreads(query).items; publisher.send(conversations)
    }
}

@MainActor @Observable
public final class CodexConversationDetailModel {
    public let threadID: String
    public private(set) var thread: CodexThread?
    public private(set) var turns: [CodexTurn] = []
    public private(set) var items: [CodexItem] = []
    @ObservationIgnored public let publisher = PassthroughSubject<CodexThreadState, Never>()
    private var task: Task<Void, Never>?
    private var subscription: CodexSubscription?
    private var observationGeneration = UUID()
    public init(threadID: String) { self.threadID = threadID }
    public func observe(_ client: CodexClient) async throws {
        stopObserving()
        let generation = observationGeneration
        // Subscribe before requesting history so live changes cannot fall into a gap.
        let subscription = await client.events(for: threadID, policy: .boundedCoalescingDeltas(1_024))
        guard observationGeneration == generation else { subscription.cancel(); return }
        self.subscription = subscription
        do {
            try Task.checkCancellation()
            _ = try await client.subscribeThread(id: threadID)
            guard observationGeneration == generation else { return }
            try Task.checkCancellation()
            let snapshot = await client.state(for: threadID)
            guard observationGeneration == generation else { return }
            try Task.checkCancellation()
            if let snapshot { apply(snapshot) }
        } catch {
            subscription.cancel()
            if observationGeneration == generation { self.subscription = nil }
            throw error
        }
        // Publishing a snapshot can synchronously stop or replace observation.
        guard observationGeneration == generation else { return }
        task = Task { @MainActor [weak self] in
            defer { subscription.cancel() }
            do {
                for try await _ in subscription.events {
                    guard let self, observationGeneration == generation, !Task.isCancelled else { return }
                    let snapshot = await client.state(for: threadID)
                    guard observationGeneration == generation, !Task.isCancelled else { return }
                    if let snapshot { apply(snapshot) }
                }
            } catch {}
        }
    }
    private func apply(_ snapshot: CodexThreadState) {
        thread = snapshot.thread
        turns = snapshot.turnOrder.compactMap { snapshot.turns[$0] }
        items = snapshot.itemOrder.compactMap { snapshot.items[$0] }
        publisher.send(snapshot)
    }
    public func stopObserving() {
        observationGeneration = UUID()
        subscription?.cancel(); subscription = nil
        task?.cancel(); task = nil
    }
}

@MainActor @Observable
public final class CodexStreamedItemModel {
    public private(set) var item: CodexItem?
    public private(set) var deltas: [JSONValue] = []
    @ObservationIgnored public let publisher = PassthroughSubject<CodexEvent, Never>()
    public init() {}
    public func consume(_ event: CodexEvent) {
        switch event {
        case .itemStarted(_, let value), .itemCompleted(_, let value): item = value; if case .itemCompleted = event { deltas.removeAll() }
        case .itemDelta(_, let id, _, let delta) where item == nil || item?.id == id: deltas.append(delta)
        default: break
        }
        publisher.send(event)
    }
}

@MainActor @Observable
public final class CodexPendingInteractionModel {
    public private(set) var pending: [CodexPendingInteraction] = []
    @ObservationIgnored public let publisher = CurrentValueSubject<[CodexPendingInteraction], Never>([])
    private var task: Task<Void, Never>?
    public init() {}
    public func observe(_ client: CodexClient) async {
        let subscription = await client.subscribe()
        task?.cancel(); task = Task { @MainActor [weak self] in
            do {
                for try await event in subscription.events {
                    guard let self else { return }
                    switch event {
                    case .serverRequest(let interaction): pending.append(interaction)
                    case .serverRequestResolved(let raw): if let id = raw["requestId"] { pending.removeAll { $0.requestID == id } }
                    case .connection(.disconnected), .connection(.failed), .connection(.reconnecting), .connection(.connecting): pending.removeAll()
                    default: break
                    }
                    publisher.send(pending)
                }
            } catch {}
        }
    }
    public func stopObserving() { task?.cancel(); task = nil }
}

@MainActor
public final class CodexCombinePublishers {
    public let connection = PassthroughSubject<CodexConnectionState, Never>()
    public let threads = PassthroughSubject<[CodexThread], Never>()
    public let events = PassthroughSubject<CodexEvent, Never>()
    public let interactions = PassthroughSubject<CodexPendingInteraction, Never>()
    private var task: Task<Void, Never>?
    private var knownThreads: [String: CodexThread] = [:]
    public init() {}
    public func observe(_ client: CodexClient) async {
        let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1_024))
        task?.cancel(); task = Task { @MainActor [weak self] in
            do {
                for try await event in subscription.events {
                    guard let self else { return }; events.send(event)
                    if case .connection(let value) = event { connection.send(value) }
                    if case .serverRequest(let value) = event { interactions.send(value) }
                    if case .notification(let method, let params) = event, method.hasPrefix("thread/"),
                       let raw = params["thread"], let thread = try? CodexThread(raw: raw) {
                        knownThreads[thread.id] = thread; threads.send(Array(knownThreads.values))
                    }
                }
            } catch {}
        }
    }
    /// Replaces the published set. Duplicate IDs keep the last occurrence rather than trapping —
    /// a server may legitimately repeat a thread across pages. Order follows each ID's first occurrence.
    public func publishThreads(_ values: [CodexThread]) {
        knownThreads = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen: Set<String> = []
        threads.send(values.compactMap { thread in
            guard seen.insert(thread.id).inserted else { return nil }
            return knownThreads[thread.id]
        })
    }
    public func stopObserving() { task?.cancel(); task = nil }
}
