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
    public init(threadID: String) { self.threadID = threadID }
    public func observe(_ client: CodexClient) async throws {
        thread = try await client.subscribeThread(id: threadID)
        let subscription = await client.events(for: threadID, policy: .boundedCoalescingDeltas(1_024))
        task?.cancel(); task = Task { @MainActor [weak self] in
            do {
                for try await event in subscription.events {
                    guard let self else { return }
                    switch event {
                    case .itemStarted(_, let item), .itemCompleted(_, let item): if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
                    case .turnStarted(_, let turn), .turnCompleted(_, let turn): if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn } else { turns.append(turn) }
                    default: break
                    }
                    if let state = await client.state(for: threadID) { publisher.send(state) }
                }
            } catch {}
        }
    }
    public func stopObserving() { task?.cancel(); task = nil }
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
                    case .serverRequestResolved(let raw): if let id = raw["requestId"]?.stringValue { pending.removeAll { $0.id == id } }
                    case .connection(.disconnected), .connection(.failed), .connection(.reconnecting): pending.removeAll()
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
                    if case .notification(let method, let params) = event, method.hasPrefix("thread/"), let raw = params["thread"], let id = raw["id"]?.stringValue {
                        knownThreads[id] = .init(raw: raw); threads.send(Array(knownThreads.values))
                    }
                }
            } catch {}
        }
    }
    public func publishThreads(_ values: [CodexThread]) { knownThreads = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }); threads.send(values) }
    public func stopObserving() { task?.cancel(); task = nil }
}
