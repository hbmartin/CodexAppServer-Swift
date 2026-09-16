import CryptoKit
import DequeModule
import Foundation
import CodexAppServerKit

actor CodexRemoteConnection: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>

    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let diagnosticContinuation: AsyncStream<CodexTransportDiagnostic>.Continuation
    private let environmentID: String
    private let credential: CodexRemoteCredential
    private let authorization: CodexRemoteClientAuthorization
    private let authorizationProvider: any CodexRemoteClientAuthorizationProvider
    private let configuration: CodexRemoteConfiguration
    private var streamID = UUID().uuidString.lowercased()
    private var nextOutboundSequence: Int64 = 1
    private var lastInboundSequence: Int64?
    private var pendingRequestIDs: Deque<JSONValue> = []
    private var inboundAssembly: InboundAssembly?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var outboundQueue: Deque<Outbound> = []
    private var waitingOutbound: Deque<Outbound> = []
    private var inFlight: Outbound?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closed = false

    private enum OutboundPayload: Sendable {
        case message(Data)
        case ping
        case close
    }

    private struct Outbound: Sendable {
        let id: UUID
        let payload: OutboundPayload
        let continuation: CheckedContinuation<Void, Error>?
    }

    private struct InboundAssembly: Sendable {
        let sequence: Int64
        let segmentCount: Int
        let messageSize: Int
        var chunks: [Data?]
        var nextSegment: Int
    }

    init(
        environmentID: String,
        credential: CodexRemoteCredential,
        authorization: CodexRemoteClientAuthorization,
        authorizationProvider: any CodexRemoteClientAuthorizationProvider,
        configuration: CodexRemoteConfiguration
    ) {
        self.environmentID = environmentID
        self.credential = credential
        self.authorization = authorization
        self.authorizationProvider = authorizationProvider
        self.configuration = configuration
        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        incomingFrames = frames.stream
        frameContinuation = frames.continuation
        let diagnosticValues = AsyncStream<CodexTransportDiagnostic>.makeStream()
        diagnostics = diagnosticValues.stream
        diagnosticContinuation = diagnosticValues.continuation
    }

    func start() async throws {
        guard socket == nil, !closed else { throw CodexRemoteError.closed }
        guard !authorization.isExpired() else { throw CodexRemoteError.authorizationExpired }
        try validateSegmentConfiguration()

        let url = try webSocketURL()
        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        request.setValue("Bearer \(credential.accessToken.unsafeRawValue)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Bearer \(authorization.sessionToken.unsafeRawValue)", forHTTPHeaderField: "x-codex-client-session-token")
        request.setValue(authorization.clientID, forHTTPHeaderField: "x-codex-client-id")
        request.setValue("3", forHTTPHeaderField: "x-codex-protocol-version")

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = wireMessageLimit
        self.session = session
        self.socket = socket
        socket.resume()

        do {
            if authorization.requiresDeviceKeyProof {
                let challengeMessage = try await receiveChallenge(from: socket)
                let challenge = try decodeMessage(challengeMessage)
                try validate(challenge: challenge, socketURL: url)
                let response: JSONValue
                do { response = try await authorizationProvider.response(to: challenge, using: authorization) }
                catch is CancellationError { throw CancellationError() }
                catch { throw CodexRemoteError.deviceChallengeRejected(error.localizedDescription) }
                guard response.objectValue != nil else {
                    throw CodexRemoteError.deviceChallengeRejected("authorization provider returned a non-object proof")
                }
                try await socket.send(.string(String(decoding: try response.encoded(), as: UTF8.self)))
            }
        } catch {
            socket.cancel(with: .policyViolation, reason: nil)
            session.invalidateAndCancel()
            self.socket = nil
            self.session = nil
            throw error
        }

        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        pingTask = Task { [weak self] in await self?.pingLoop() }
    }

    func send(frame: Data) async throws {
        guard !closing, !closed, socket != nil else { throw CodexRemoteError.closed }
        guard frame.count <= configuration.maximumFrameBytes else {
            throw CodexError.frameTooLarge(actual: frame.count, limit: configuration.maximumFrameBytes)
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(id: id, payload: .message(frame), continuation: continuation))
            }
        }, onCancel: { [weak self] in Task { await self?.cancelOutbound(id: id) } })
    }

    func close() async {
        guard !closed else { return }
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        closing = true
        guard socket != nil else {
            finish(nil)
            return
        }
        let id = UUID()
        do {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(id: id, payload: .close, continuation: continuation))
            }
        } catch {
            if !closed {
                diagnosticContinuation.yield(.init(level: .warning, message: "Could not send Remote Control close envelope: \(error.localizedDescription)"))
            }
        }
        if !closed { finish(nil) }
    }

    private func enqueue(_ outbound: Outbound) {
        if outboundQueue.count < configuration.maximumOutboundFrames { outboundQueue.append(outbound) }
        else { waitingOutbound.append(outbound) }
        startWriterIfNeeded()
    }

    private func startWriterIfNeeded() {
        guard writerTask == nil, !outboundQueue.isEmpty, !closed else { return }
        writerTask = Task { [weak self] in await self?.writeLoop() }
    }

    private func writeLoop() async {
        while !closed, let socket, let next = outboundQueue.popFirst() {
            inFlight = next
            promoteWaiting()
            do {
                let sequence = try takeOutboundSequence()
                switch next.payload {
                case .message(let frame):
                    let payload = try JSONValue.decode(frame)
                    guard payload.objectValue != nil else {
                        throw CodexRemoteError.malformedEnvelope("outbound app-server message is not an object")
                    }
                    if let id = requestID(in: payload) { pendingRequestIDs.append(id) }
                    for message in try wireMessages(payload: payload, sourceData: frame, sequence: sequence) {
                        try await socket.send(.string(String(decoding: message, as: UTF8.self)))
                    }
                case .ping:
                    let envelope: JSONValue = [
                        "type": "ping",
                        "client_id": .string(authorization.clientID),
                        "stream_id": .string(streamID),
                        "env_id": .string(environmentID),
                        "seq_id": .number(Decimal(sequence)),
                        "state": "foreground",
                        "skip_history": true,
                    ]
                    try await socket.send(.string(String(decoding: try envelope.encoded(), as: UTF8.self)))
                case .close:
                    let envelope: JSONValue = [
                        "type": "client_closed",
                        "client_id": .string(authorization.clientID),
                        "stream_id": .string(streamID),
                        "env_id": .string(environmentID),
                        "seq_id": .number(Decimal(sequence)),
                    ]
                    try await socket.send(.string(String(decoding: try envelope.encoded(), as: UTF8.self)))
                }
                if inFlight?.id == next.id {
                    next.continuation?.resume()
                    inFlight = nil
                }
            } catch is CancellationError {
                if inFlight?.id == next.id {
                    next.continuation?.resume(throwing: CancellationError())
                    inFlight = nil
                }
            } catch {
                if case .close = next.payload {
                    if inFlight?.id == next.id {
                        next.continuation?.resume()
                        inFlight = nil
                    }
                    diagnosticContinuation.yield(.init(level: .warning, message: "Could not send Remote Control close envelope: \(error.localizedDescription)"))
                    finish(nil)
                    return
                }
                if inFlight?.id == next.id {
                    next.continuation?.resume(throwing: error)
                    inFlight = nil
                }
                if closing {
                    diagnosticContinuation.yield(.init(level: .warning, message: "Could not send Remote Control close envelope: \(error.localizedDescription)"))
                }
                finish(error)
                return
            }
        }
        writerTask = nil
        if !outboundQueue.isEmpty { startWriterIfNeeded() }
    }

    private func wireMessages(payload: JSONValue, sourceData: Data, sequence: Int64) throws -> [Data] {
        let base: JSONValue = [
            "type": "client_message",
            "client_id": .string(authorization.clientID),
            "stream_id": .string(streamID),
            "env_id": .string(environmentID),
            "skip_history": false,
            "message": payload,
            "seq_id": .number(Decimal(sequence)),
        ]
        let unsegmented = try base.encoded()
        if unsegmented.count <= configuration.maximumSegmentBytes { return [unsegmented] }

        let capacity = try outboundChunkCapacity(sourceCount: sourceData.count, sequence: sequence)
        let count = ceilingDivision(sourceData.count, by: capacity)
        var messages: [Data] = []
        messages.reserveCapacity(count)
        for index in 0..<count {
            let lower = index * capacity
            let upper = min(lower + capacity, sourceData.count)
            let chunk = sourceData.subdata(in: lower..<upper)
            let encoded = try clientChunkEnvelope(
                sequence: sequence,
                segment: index,
                count: count,
                messageSize: sourceData.count,
                chunk: chunk.base64EncodedString()
            ).encoded()
            guard encoded.count <= configuration.maximumSegmentBytes else {
                throw CodexRemoteError.invalidConfiguration("encoded Remote Control chunk exceeds maximumSegmentBytes")
            }
            messages.append(encoded)
        }
        return messages
    }

    private func validateSegmentConfiguration() throws {
        _ = try outboundChunkCapacity(sourceCount: configuration.maximumFrameBytes, sequence: Int64.max - 1)
        guard inboundChunkCapacity(messageSize: configuration.maximumFrameBytes) != nil else {
            throw CodexRemoteError.invalidConfiguration("maximumSegmentBytes cannot fit Remote Control chunk metadata")
        }
    }

    private func outboundChunkCapacity(sourceCount: Int, sequence: Int64) throws -> Int {
        var capacity = configuration.maximumSegmentBytes
        var previousCount = 0
        while true {
            let count = ceilingDivision(sourceCount, by: capacity)
            let metadata = try clientChunkEnvelope(
                sequence: sequence,
                segment: max(0, count - 1),
                count: count,
                messageSize: sourceCount,
                chunk: ""
            ).encoded().count
            guard metadata < configuration.maximumSegmentBytes else {
                throw CodexRemoteError.invalidConfiguration("maximumSegmentBytes cannot fit Remote Control chunk metadata")
            }
            let availableBase64Bytes = configuration.maximumSegmentBytes - metadata
            let derivedCapacity = (availableBase64Bytes / 4) * 3
            guard derivedCapacity > 0 else {
                throw CodexRemoteError.invalidConfiguration("maximumSegmentBytes cannot fit a Remote Control chunk payload")
            }
            let nextCapacity = min(capacity, derivedCapacity)
            if nextCapacity == capacity, count == previousCount { return capacity }
            previousCount = count
            capacity = nextCapacity
        }
    }

    private func inboundChunkCapacity(messageSize: Int) -> Int? {
        var capacity = configuration.maximumSegmentBytes
        var previousCount = 0
        while true {
            let count = ceilingDivision(messageSize, by: capacity)
            let envelope: JSONValue = [
                "type": "server_message_chunk",
                "client_id": .string(authorization.clientID),
                "stream_id": .string(streamID),
                "env_id": .string(environmentID),
                "cursor": .null,
                "seq_id": .number(Decimal(Int64.max)),
                "segment_id": .number(Decimal(max(0, count - 1))),
                "segment_count": .number(Decimal(count)),
                "message_size_bytes": .number(Decimal(messageSize)),
                "message_chunk_base64": .string(""),
            ]
            guard let metadata = try? envelope.encoded().count,
                  metadata < configuration.maximumSegmentBytes else { return nil }
            let availableBase64Bytes = configuration.maximumSegmentBytes - metadata
            let derivedCapacity = (availableBase64Bytes / 4) * 3
            guard derivedCapacity > 0 else { return nil }
            let nextCapacity = min(capacity, derivedCapacity)
            if nextCapacity == capacity, count == previousCount { return capacity }
            previousCount = count
            capacity = nextCapacity
        }
    }

    private func clientChunkEnvelope(
        sequence: Int64,
        segment: Int,
        count: Int,
        messageSize: Int,
        chunk: String
    ) -> JSONValue {
        [
            "type": "client_message_chunk",
            "client_id": .string(authorization.clientID),
            "stream_id": .string(streamID),
            "env_id": .string(environmentID),
            "skip_history": false,
            "seq_id": .number(Decimal(sequence)),
            "segment_id": .number(Decimal(segment)),
            "segment_count": .number(Decimal(count)),
            "message_size_bytes": .number(Decimal(messageSize)),
            "message_chunk_base64": .string(chunk),
        ]
    }

    private func ceilingDivision(_ value: Int, by divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }

    private func promoteWaiting() {
        while outboundQueue.count < configuration.maximumOutboundFrames, let next = waitingOutbound.popFirst() {
            outboundQueue.append(next)
        }
    }

    private func cancelOutbound(id: UUID) {
        if let index = waitingOutbound.firstIndex(where: { $0.id == id }) {
            let item = waitingOutbound.remove(at: index)
            item.continuation?.resume(throwing: CancellationError())
            return
        }
        if let index = outboundQueue.firstIndex(where: { $0.id == id }) {
            let item = outboundQueue.remove(at: index)
            item.continuation?.resume(throwing: CancellationError())
            promoteWaiting()
            return
        }
        if inFlight?.id == id {
            inFlight?.continuation?.resume(throwing: CancellationError())
            inFlight = nil
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, !closed {
                let envelope = try decodeMessage(await socket.receive())
                try await handle(envelope: envelope)
            }
        } catch is CancellationError {
        } catch {
            if !closed { finish(error) }
        }
    }

    private func handle(envelope: JSONValue) async throws {
        guard envelope.objectValue != nil else { throw CodexRemoteError.malformedEnvelope("envelope is not an object") }
        guard let type = envelope["type"]?.stringValue else { throw CodexRemoteError.malformedEnvelope("missing type") }
        guard envelope["client_id"]?.stringValue == authorization.clientID else {
            throw CodexRemoteError.malformedEnvelope("client_id does not match the enrolled client")
        }

        if type == "ack" { return }

        guard envelope["env_id"]?.stringValue == environmentID else {
            throw CodexRemoteError.hostMismatch(expected: environmentID, received: envelope["env_id"]?.stringValue)
        }
        guard envelope["stream_id"]?.stringValue == streamID else {
            throw CodexRemoteError.malformedEnvelope("stream_id does not match the active stream")
        }
        guard let sequence = envelope["seq_id"]?.int64Value, sequence >= 0 else {
            throw CodexRemoteError.invalidSequence(envelope["seq_id"])
        }

        switch type {
        case "server_message":
            guard try accept(sequence: sequence) else { return }
            guard var payload = envelope["message"] else { throw CodexRemoteError.malformedEnvelope("server_message has no message") }
            payload = translateRemoteError(payload)
            try yield(payload: payload)
        case "server_message_chunk":
            if let payload = try acceptChunk(envelope, sequence: sequence) {
                try yield(payload: translateRemoteError(payload))
            }
        case "pong":
            guard try accept(sequence: sequence) else { return }
            if envelope["status"]?.stringValue == "unknown" {
                throw CodexRemoteError.malformedEnvelope("the remote stream is no longer known to the service")
            }
        default:
            throw CodexRemoteError.malformedEnvelope("unsupported envelope type \(type)")
        }
    }

    private func accept(sequence: Int64) throws -> Bool {
        if let assembly = inboundAssembly {
            throw CodexRemoteError.sequenceGap(expected: assembly.sequence, received: sequence)
        }
        if let previous = lastInboundSequence {
            if sequence <= previous {
                diagnosticContinuation.yield(.init(level: .warning, message: "Suppressed duplicate or stale Remote Control sequence \(sequence)"))
                return false
            }
            guard sequence == previous + 1 else {
                throw CodexRemoteError.sequenceGap(expected: previous + 1, received: sequence)
            }
        }
        lastInboundSequence = sequence
        return true
    }

    private func acceptChunk(_ envelope: JSONValue, sequence: Int64) throws -> JSONValue? {
        guard let segment = envelope["segment_id"]?.intValue,
              let count = envelope["segment_count"]?.intValue,
              let size = envelope["message_size_bytes"]?.intValue,
              let encoded = envelope["message_chunk_base64"]?.stringValue,
              count > 0, count <= maximumInboundSegmentCount,
              segment >= 0, segment < count,
              size > 0, size <= configuration.maximumFrameBytes,
              let chunk = Data(base64Encoded: encoded) else {
            throw CodexRemoteError.malformedEnvelope("invalid server message chunk metadata")
        }

        if let previous = lastInboundSequence {
            if sequence <= previous {
                diagnosticContinuation.yield(.init(level: .warning, message: "Suppressed duplicate or stale Remote Control sequence \(sequence)"))
                return nil
            }
            guard sequence == previous + 1 else {
                throw CodexRemoteError.sequenceGap(expected: previous + 1, received: sequence)
            }
        }

        if inboundAssembly == nil {
            guard segment == 0 else { throw CodexRemoteError.malformedEnvelope("segmented message did not start at segment zero") }
            inboundAssembly = .init(sequence: sequence, segmentCount: count, messageSize: size, chunks: Array(repeating: nil, count: count), nextSegment: 0)
        }
        guard var assembly = inboundAssembly,
              assembly.sequence == sequence,
              assembly.segmentCount == count,
              assembly.messageSize == size else {
            throw CodexRemoteError.malformedEnvelope("segmented message metadata changed before completion")
        }
        if segment < assembly.nextSegment {
            diagnosticContinuation.yield(.init(level: .warning, message: "Suppressed duplicate Remote Control segment \(segment) for sequence \(sequence)"))
            return nil
        }
        guard segment == assembly.nextSegment else {
            throw CodexRemoteError.malformedEnvelope("segmented message has a segment gap")
        }
        assembly.chunks[segment] = chunk
        assembly.nextSegment += 1
        inboundAssembly = assembly
        guard assembly.nextSegment == count else { return nil }

        var data = Data(capacity: size)
        for chunk in assembly.chunks {
            guard let chunk else { throw CodexRemoteError.malformedEnvelope("segmented message is incomplete") }
            data.append(chunk)
            guard data.count <= size else { throw CodexRemoteError.malformedEnvelope("segmented message exceeds its declared size") }
        }
        guard data.count == size else { throw CodexRemoteError.malformedEnvelope("segmented message size does not match its declaration") }
        inboundAssembly = nil
        lastInboundSequence = sequence
        let payload: JSONValue
        do { payload = try .decode(data) }
        catch { throw CodexRemoteError.malformedEnvelope("reassembled message is not valid JSON") }
        guard payload.objectValue != nil else { throw CodexRemoteError.malformedEnvelope("reassembled message is not an object") }
        return payload
    }

    private func translateRemoteError(_ payload: JSONValue) -> JSONValue {
        guard payload["type"]?.stringValue == "error" else {
            if let id = responseID(in: payload), let index = pendingRequestIDs.firstIndex(of: id) {
                pendingRequestIDs.remove(at: index)
            }
            return payload
        }

        let id: JSONValue
        switch payload["id"] {
        case .string, .number: id = payload["id"]!
        default:
            diagnosticContinuation.yield(.init(level: .warning, message: "Received an unmatched Remote Control error without a string or numeric id"))
            return payload
        }
        if let index = pendingRequestIDs.firstIndex(of: id) {
            pendingRequestIDs.remove(at: index)
        } else {
            diagnosticContinuation.yield(.init(level: .warning, message: "Received an unmatched Remote Control error for id \(id)"))
        }

        let details: JSONValue
        if let nested = payload["error"], nested.objectValue != nil {
            details = nested
        } else if var flat = payload.objectValue {
            flat.removeValue(forKey: "type")
            flat.removeValue(forKey: "id")
            details = .object(flat)
        } else {
            details = ["message": "Remote Control request failed"]
        }
        return ["id": id, "error": details]
    }

    private func yield(payload: JSONValue) throws {
        let frame = try payload.encoded()
        guard frame.count <= configuration.maximumFrameBytes else {
            throw CodexError.frameTooLarge(actual: frame.count, limit: configuration.maximumFrameBytes)
        }
        frameContinuation.yield(frame)
    }

    private func requestID(in payload: JSONValue) -> JSONValue? {
        guard payload["method"]?.stringValue != nil else { return nil }
        switch payload["id"] {
        case .string, .number: return payload["id"]
        default: return nil
        }
    }

    private func responseID(in payload: JSONValue) -> JSONValue? {
        guard payload["result"] != nil || payload["error"] != nil else { return nil }
        switch payload["id"] {
        case .string, .number: return payload["id"]
        default: return nil
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled, !closing, !closed {
            do { try await Task.sleep(for: configuration.pingInterval) }
            catch { return }
            guard !Task.isCancelled, !closing, !closed else { return }
            if outboundQueue.count < configuration.maximumOutboundFrames {
                enqueue(.init(id: UUID(), payload: .ping, continuation: nil))
            } else {
                diagnosticContinuation.yield(.init(level: .warning, message: "Skipped Remote Control ping while the outbound queue was full"))
            }
        }
    }

    private func takeOutboundSequence() throws -> Int64 {
        guard nextOutboundSequence < Int64.max else {
            throw CodexRemoteError.invalidSequence(.number(Decimal(nextOutboundSequence)))
        }
        defer { nextOutboundSequence += 1 }
        return nextOutboundSequence
    }

    private func receiveChallenge(from socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let timeout = configuration.requestTimeout
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                socket.cancel(with: .policyViolation, reason: nil)
                throw CodexRemoteError.deviceChallengeRejected("timed out")
            }
            guard let first = try await group.next() else { throw CodexRemoteError.deviceChallengeRejected("connection closed") }
            group.cancelAll()
            return first
        }
    }

    private func decodeMessage(_ message: URLSessionWebSocketTask.Message) throws -> JSONValue {
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw CodexRemoteError.malformedEnvelope("unsupported WebSocket message")
        }
        guard data.count <= wireMessageLimit else {
            throw CodexError.frameTooLarge(actual: data.count, limit: wireMessageLimit)
        }
        do { return try .decode(data) }
        catch { throw CodexRemoteError.malformedEnvelope("invalid JSON") }
    }

    private func validate(challenge: JSONValue, socketURL: URL) throws {
        guard challenge["type"]?.stringValue == "device_key_challenge" else {
            throw CodexRemoteError.deviceChallengeRejected("the first WebSocket message was not a device-key challenge")
        }
        guard challenge["purpose"]?.stringValue == "remote_control_client_websocket",
              challenge["audience"]?.stringValue == "remote_control_client_websocket" else {
            throw CodexRemoteError.deviceChallengeRejected("purpose or audience does not match Remote Control")
        }
        guard challenge["clientId"]?.stringValue == authorization.clientID else {
            throw CodexRemoteError.deviceChallengeRejected("client ID does not match the authorization")
        }
        guard let accountUserID = authorization.accountUserID,
              challenge["accountUserId"]?.stringValue == accountUserID else {
            throw CodexRemoteError.deviceChallengeRejected("account user ID does not match the authorization")
        }
        guard let expiresAt = authorization.expiresAt else {
            throw CodexRemoteError.deviceChallengeRejected("authorization has no expiration to bind")
        }
        let expiration = Int64(floor(expiresAt.timeIntervalSince1970))
        guard challenge["tokenExpiresAt"]?.int64Value == expiration,
              let challengeScopes = challenge["scopes"]?.arrayValue,
              challengeScopes.count == authorization.scopes.count,
              challengeScopes.compactMap(\.stringValue) == authorization.scopes else {
            throw CodexRemoteError.deviceChallengeRejected("token expiration or scopes do not match the authorization")
        }

        let digest = SHA256.hash(data: Data(authorization.sessionToken.unsafeRawValue.utf8))
        let tokenHash = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard challenge["tokenSha256Base64url"]?.stringValue == tokenHash else {
            throw CodexRemoteError.deviceChallengeRejected("session token hash does not match the authorization")
        }

        guard var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false), let host = components.host else {
            throw CodexRemoteError.deviceChallengeRejected("could not validate the WebSocket target")
        }
        let scheme = components.scheme == "wss" ? "https" : "http"
        let port = components.port.map { ":\($0)" } ?? ""
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let originHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        let origin = "\(scheme)://\(originHost)\(port)"
        components.query = nil
        components.fragment = nil
        guard challenge["targetOrigin"]?.stringValue == origin,
              challenge["targetPath"]?.stringValue == components.percentEncodedPath else {
            throw CodexRemoteError.deviceChallengeRejected("challenge target does not match the WebSocket URL")
        }
    }

    private func webSocketURL() throws -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw CodexRemoteError.invalidConfiguration("could not parse remote base URL")
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, CodexRemotePath.socket].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw CodexRemoteError.invalidConfiguration("could not construct controller WebSocket URL")
        }
        return url
    }

    private var wireMessageLimit: Int { max(256 * 1_024, configuration.maximumSegmentBytes * 2) }

    private var maximumInboundSegmentCount: Int {
        guard let capacity = inboundChunkCapacity(messageSize: configuration.maximumFrameBytes) else { return 0 }
        return ceilingDivision(configuration.maximumFrameBytes, by: capacity)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        writerTask?.cancel()
        writerTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        let failure = error ?? CodexRemoteError.closed
        if let inFlight {
            inFlight.continuation?.resume(throwing: failure)
            self.inFlight = nil
        }
        for item in outboundQueue { item.continuation?.resume(throwing: failure) }
        for item in waitingOutbound { item.continuation?.resume(throwing: failure) }
        outboundQueue.removeAll()
        waitingOutbound.removeAll()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if let error { frameContinuation.finish(throwing: error) }
        else { frameContinuation.finish() }
        diagnosticContinuation.finish()
    }
}
