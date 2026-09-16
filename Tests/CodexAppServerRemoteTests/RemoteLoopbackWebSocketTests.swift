#if os(macOS)
import Darwin
import Foundation
import Testing
import CodexAppServerKit
@testable import CodexAppServerRemote

private struct LoopbackCredentials: CodexRemoteCredentialProvider {
    func credential() async throws -> CodexRemoteCredential {
        try .init(accountID: "account", accessToken: .init("account-token"))
    }
}

private struct LoopbackAuthorization: CodexRemoteClientAuthorizationProvider {
    func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        try .init(accountID: "account", clientID: "client-1", sessionToken: .init("session-token"), requiresDeviceKeyProof: false)
    }
}

private struct ChallengedLoopbackAuthorization: CodexRemoteClientAuthorizationProvider {
    let expiresAt: Date
    func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        try .init(
            accountID: "account",
            accountUserID: "account-user-1",
            clientID: "client-1",
            sessionToken: .init("session-token"),
            expiresAt: expiresAt,
            requiresDeviceKeyProof: true
        )
    }
    func response(to challenge: JSONValue, using authorization: CodexRemoteClientAuthorization) async throws -> JSONValue {
        guard challenge["nonce"] == "nonce-1", challenge["sessionId"] == "session-1" else {
            throw CodexRemoteError.deviceChallengeRejected("test challenge did not match")
        }
        return [
            "type": "device_key_proof",
            "keyId": "key-1",
            "signatureDerBase64": "signature",
            "signedPayloadBase64": "payload",
            "algorithm": "ES256",
        ]
    }
}

@Test func remoteLoopbackWebSocketUsesCurrentEnvelopesSegmentsDuplicatesAndFreshStreams() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let port = try availableLoopbackPort()
    let report = directory.appendingPathComponent("report.json")
    let script = directory.appendingPathComponent("remote-ws.py")
    try remoteWebSocketServerSource.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let process = Process()
    process.executableURL = script
    process.arguments = [String(port), report.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await waitForLoopbackListener(port: port)

    let configuration = try CodexRemoteConfiguration(
        baseURL: URL(string: "http://127.0.0.1:\(port)/backend-api")!,
        pingInterval: .seconds(60),
        maximumFrameBytes: 2_100,
        maximumSegmentBytes: 512,
        maximumOutboundFrames: 1
    )
    let controller = CodexRemoteController(
        credentials: LoopbackCredentials(),
        authorizationProvider: LoopbackAuthorization(),
        configuration: configuration
    )
    let factory = await controller.transportFactory(environmentID: "env-1")

    let first = try await factory.makeTransport()
    try await first.start()
    try await first.send(frame: try JSONValue.object(["client": 1]).encoded())
    try await first.send(frame: try JSONValue.object(["client": 2, "blob": .string(String(repeating: "x", count: 2_000))]).encoded())
    var firstFrames = first.incomingFrames.makeAsyncIterator()
    let firstData = try #require(try await firstFrames.next())
    #expect(try JSONValue.decode(firstData)["server"] == 1)
    let segmentedData = try #require(try await firstFrames.next())
    let segmented = try JSONValue.decode(segmentedData)
    #expect(segmented["server"] == 2)
    #expect(try segmented.encoded().count == 2_100)
    var firstDiagnostics = first.diagnostics.makeAsyncIterator()
    #expect(await firstDiagnostics.next()?.message.contains("duplicate") == true)
    await first.close()

    let second = try await factory.makeTransport()
    try await second.start()
    try await second.send(frame: try JSONValue.object(["client": 3]).encoded())
    var secondFrames = second.incomingFrames.makeAsyncIterator()
    let secondData = try #require(try await secondFrames.next())
    #expect(try JSONValue.decode(secondData)["server"] == 3)
    var secondDiagnostics = second.diagnostics.makeAsyncIterator()
    #expect(await secondDiagnostics.next()?.message.contains("duplicate") == true)
    let finalSend = Task {
        try await second.send(frame: try JSONValue.object(["client": 4, "blob": .string(String(repeating: "z", count: 2_000))]).encoded())
    }
    try await Task.sleep(for: .milliseconds(10))
    let concurrentClose = Task { await second.close() }
    let secondClose = Task { await second.close() }
    try await finalSend.value
    await concurrentClose.value
    await secondClose.value

    for _ in 0..<500 where !FileManager.default.fileExists(atPath: report.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let raw = try JSONValue.decode(Data(contentsOf: report))
    #expect(raw["outbound_sequences"] == [1, 2, 1])
    #expect(raw["outbound_payloads"]?[0] == ["client": 1])
    #expect(raw["outbound_payloads"]?[1]?["client"] == 2)
    #expect(raw["outbound_payloads"]?[1]?["blob"]?.stringValue?.count == 2_000)
    #expect(raw["outbound_payloads"]?[2] == ["client": 3])
    let chunkCountValues = try #require(raw["chunk_counts"]?.arrayValue)
    let chunkCounts = chunkCountValues.compactMap(\.intValue)
    #expect(chunkCounts.count == 3)
    #expect(chunkCounts[0] == 1)
    #expect(chunkCounts[1] > 1)
    #expect(chunkCounts[2] == 1)
    let wireFrameSizeValues = try #require(raw["wire_frame_sizes"]?.arrayValue)
    let wireFrameSizes = wireFrameSizeValues.compactMap(\.intValue)
    #expect(!wireFrameSizes.isEmpty)
    #expect(wireFrameSizes.allSatisfy { $0 <= 512 })
    #expect(raw["authorization"] == ["Bearer account-token", "Bearer account-token"])
    #expect(raw["account_ids"] == ["account", "account"])
    #expect(raw["session_tokens"] == ["Bearer session-token", "Bearer session-token"])
    #expect(raw["client_ids"] == ["client-1", "client-1"])
    #expect(raw["protocol_versions"] == ["3", "3"])
    #expect(raw["paths"] == ["/backend-api/codex/remote/control/client", "/backend-api/codex/remote/control/client"])
    let streamValues = try #require(raw["stream_ids"]?.arrayValue)
    let streamIDs = streamValues.compactMap(\.stringValue)
    #expect(streamIDs.count == 2)
    #expect(streamIDs[0] != streamIDs[1])
    let wireFrames = try #require(raw["wire_frames"]?.arrayValue)
    for streamID in streamIDs {
        let streamFrames = wireFrames.filter { $0["stream_id"]?.stringValue == streamID }
        #expect(streamFrames.last?["type"] == "client_closed")
        let closeSequence = try #require(streamFrames.last?["seq_id"]?.intValue)
        #expect(streamFrames.dropLast().allSatisfy { ($0["seq_id"]?.intValue ?? closeSequence) < closeSequence })
    }
}

@Test func remoteLoopbackWebSocketValidatesAndAnswersDeviceKeyChallengeBeforeAppTraffic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let port = try availableLoopbackPort()
    let report = directory.appendingPathComponent("challenge-report.json")
    let script = directory.appendingPathComponent("remote-challenge-ws.py")
    try remoteChallengeServerSource.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let expiration = Int64(Date.now.timeIntervalSince1970) + 3_600
    let process = Process()
    process.executableURL = script
    process.arguments = [String(port), report.path, String(expiration)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await waitForLoopbackListener(port: port)

    let configuration = try CodexRemoteConfiguration(baseURL: URL(string: "http://127.0.0.1:\(port)/backend-api")!)
    let controller = CodexRemoteController(
        credentials: LoopbackCredentials(),
        authorizationProvider: ChallengedLoopbackAuthorization(expiresAt: Date(timeIntervalSince1970: TimeInterval(expiration))),
        configuration: configuration
    )
    let transport = try await controller.transportFactory(environmentID: "env-1").makeTransport()
    try await transport.start()
    try await transport.send(frame: try JSONValue.object(["client": "after-proof"]).encoded())
    var frames = transport.incomingFrames.makeAsyncIterator()
    let data = try #require(try await frames.next())
    #expect(try JSONValue.decode(data) == ["server": "accepted"])
    await transport.close()

    for _ in 0..<500 where !FileManager.default.fileExists(atPath: report.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let raw = try JSONValue.decode(Data(contentsOf: report))
    #expect(raw["proof"]?["type"] == "device_key_proof")
    #expect(raw["proof"]?["keyId"] == "key-1")
    #expect(raw["message"] == ["client": "after-proof"])
}

@Test func remoteErrorsCorrelateByIDAndUnmatchedErrorsDoNotConsumePendingRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let port = try availableLoopbackPort()
    let script = directory.appendingPathComponent("remote-errors-ws.py")
    try remoteErrorServerSource.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let process = Process()
    process.executableURL = script
    process.arguments = [String(port)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await waitForLoopbackListener(port: port)

    let configuration = try CodexRemoteConfiguration(
        baseURL: URL(string: "http://127.0.0.1:\(port)/backend-api")!,
        pingInterval: .seconds(60)
    )
    let controller = CodexRemoteController(
        credentials: LoopbackCredentials(),
        authorizationProvider: LoopbackAuthorization(),
        configuration: configuration
    )
    let transport = try await controller.transportFactory(environmentID: "env-1").makeTransport()
    try await transport.start()
    try await transport.send(frame: try JSONValue.object(["id": "first", "method": "first/request", "params": [:]]).encoded())
    try await transport.send(frame: try JSONValue.object(["id": 2, "method": "second/request", "params": [:]]).encoded())

    var frames = transport.incomingFrames.makeAsyncIterator()
    let secondError = try JSONValue.decode(try #require(try await frames.next()))
    #expect(secondError["id"] == 2)
    #expect(secondError["error"]?["code"] == -32_002)
    #expect(secondError["error"]?["data"]?["order"] == 2)
    let firstResult = try JSONValue.decode(try #require(try await frames.next()))
    #expect(firstResult == ["id": "first", "result": ["ok": true]])
    let unmatched = try JSONValue.decode(try #require(try await frames.next()))
    #expect(unmatched["id"] == 999)
    #expect(unmatched["error"]?["code"] == -32_099)
    let missingID = try JSONValue.decode(try #require(try await frames.next()))
    #expect(missingID["type"] == "error")
    #expect(missingID["id"] == nil)

    var diagnostics = transport.diagnostics.makeAsyncIterator()
    #expect(await diagnostics.next()?.message.contains("unmatched") == true)
    #expect(await diagnostics.next()?.message.contains("without a string or numeric id") == true)
    await transport.close()
}

private func availableLoopbackPort() throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CodexError.transportClosed("could not allocate test socket") }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw CodexError.transportClosed("could not bind test socket") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard read == 0 else { throw CodexError.transportClosed("could not inspect test socket") }
    return Int(UInt16(bigEndian: address.sin_port))
}

private func waitForLoopbackListener(port: Int) async throws {
    for _ in 0..<200 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = UInt16(port).bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Darwin.close(descriptor)
        if result == 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexError.transportClosed("test WebSocket server did not listen")
}

private let remoteWebSocketServerSource = #"""
#!/usr/bin/python3
import base64, hashlib, json, os, socket, struct, sys, tempfile

port = int(sys.argv[1])
report_path = sys.argv[2]
report = {"outbound_sequences": [], "outbound_payloads": [], "chunk_counts": [], "wire_frame_sizes": [], "wire_frames": [], "authorization": [], "account_ids": [], "session_tokens": [], "client_ids": [], "protocol_versions": [], "paths": [], "stream_ids": []}

def recv_exact(connection, count):
    output = b""
    while len(output) < count:
        value = connection.recv(count - len(output))
        if not value: raise EOFError()
        output += value
    return output

def receive_frame(connection):
    first, second = recv_exact(connection, 2)
    length = second & 0x7f
    if length == 126: length = struct.unpack("!H", recv_exact(connection, 2))[0]
    elif length == 127: length = struct.unpack("!Q", recv_exact(connection, 8))[0]
    mask = recv_exact(connection, 4) if second & 0x80 else None
    payload = recv_exact(connection, length)
    if mask: payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return first & 0x0f, payload

def send_frame(connection, payload, opcode=1):
    payload = payload if isinstance(payload, bytes) else payload.encode()
    header = bytes([0x80 | opcode])
    if len(payload) < 126: header += bytes([len(payload)])
    elif len(payload) < 65536: header += bytes([126]) + struct.pack("!H", len(payload))
    else: header += bytes([127]) + struct.pack("!Q", len(payload))
    connection.sendall(header + payload)

def handshake(connection):
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = connection.recv(4096)
        if not chunk: raise EOFError()
        request += chunk
    lines = request.decode().split("\r\n")
    path = lines[0].split(" ")[1]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
    return path, headers

def receive_text(connection):
    while True:
        opcode, payload = receive_frame(connection)
        if opcode == 1:
            report["wire_frame_sizes"].append(len(payload))
            value = json.loads(payload)
            report["wire_frames"].append({"type": value.get("type"), "seq_id": value.get("seq_id"), "stream_id": value.get("stream_id")})
            return value
        if opcode == 8: return None
        if opcode == 9: send_frame(connection, payload, 10)

def receive_logical(connection):
    first = receive_text(connection)
    if first["type"] == "client_message": return first, first["message"], 1
    assert first["type"] == "client_message_chunk"
    chunks = [first]
    for _ in range(1, first["segment_count"]): chunks.append(receive_text(connection))
    assert [item["segment_id"] for item in chunks] == list(range(first["segment_count"]))
    data = b"".join(base64.b64decode(item["message_chunk_base64"]) for item in chunks)
    assert len(data) == first["message_size_bytes"]
    return first, json.loads(data), len(chunks)

def send_envelope(connection, sequence, stream_id, payload):
    send_frame(connection, json.dumps({"type": "server_message", "client_id": "client-1", "seq_id": sequence, "stream_id": stream_id, "env_id": "env-1", "cursor": None, "message": payload}, separators=(",", ":")))

def send_segmented(connection, sequence, stream_id, payload):
    data = json.dumps(payload, separators=(",", ":")).encode()
    chunks = [data[index:index + 195] for index in range(0, len(data), 195)]
    for index, chunk in enumerate(chunks):
        send_frame(connection, json.dumps({"type": "server_message_chunk", "client_id": "client-1", "seq_id": sequence, "stream_id": stream_id, "env_id": "env-1", "cursor": None, "segment_id": index, "segment_count": len(chunks), "message_size_bytes": len(data), "message_chunk_base64": base64.b64encode(chunk).decode()}, separators=(",", ":")))

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(4)

for connection_index in range(2):
    while True:
        connection, _ = listener.accept()
        try:
            path, headers = handshake(connection)
            break
        except Exception:
            connection.close()
    report["paths"].append(path)
    report["authorization"].append(headers.get("authorization"))
    report["account_ids"].append(headers.get("chatgpt-account-id"))
    report["session_tokens"].append(headers.get("x-codex-client-session-token"))
    report["client_ids"].append(headers.get("x-codex-client-id"))
    report["protocol_versions"].append(headers.get("x-codex-protocol-version"))
    expected = 2 if connection_index == 0 else 1
    stream_id = None
    for _ in range(expected):
        envelope, payload, chunks = receive_logical(connection)
        stream_id = envelope["stream_id"]
        report["outbound_sequences"].append(envelope["seq_id"])
        report["outbound_payloads"].append(payload)
        report["chunk_counts"].append(chunks)
    report["stream_ids"].append(stream_id)
    if connection_index == 0:
        send_envelope(connection, 1, stream_id, {"server": 1})
        send_envelope(connection, 1, stream_id, {"server": "duplicate"})
        maximum_payload = {"server": 2, "blob": ""}
        empty_size = len(json.dumps(maximum_payload, separators=(",", ":")).encode())
        maximum_payload["blob"] = "y" * (2100 - empty_size)
        assert len(json.dumps(maximum_payload, separators=(",", ":")).encode()) == 2100
        send_segmented(connection, 2, stream_id, maximum_payload)
    else:
        send_envelope(connection, 1, stream_id, {"server": 3})
        send_envelope(connection, 1, stream_id, {"server": "duplicate"})
    try:
        while True:
            frame = receive_text(connection)
            if frame is None or frame.get("type") == "client_closed": break
    except Exception:
        pass
    connection.close()

listener.close()
descriptor, temporary_path = tempfile.mkstemp(dir=os.path.dirname(report_path) or ".", prefix=".remote-report-")
try:
    with os.fdopen(descriptor, "w") as output: json.dump(report, output)
    os.replace(temporary_path, report_path)
except Exception:
    try: os.unlink(temporary_path)
    except FileNotFoundError: pass
    raise
"""#

private let remoteChallengeServerSource = #"""
#!/usr/bin/python3
import base64, hashlib, json, os, socket, struct, sys, tempfile

port = int(sys.argv[1])
report_path = sys.argv[2]
expiration = int(sys.argv[3])

def recv_exact(connection, count):
    output = b""
    while len(output) < count:
        value = connection.recv(count - len(output))
        if not value: raise EOFError()
        output += value
    return output

def receive_frame(connection):
    first, second = recv_exact(connection, 2)
    length = second & 0x7f
    if length == 126: length = struct.unpack("!H", recv_exact(connection, 2))[0]
    elif length == 127: length = struct.unpack("!Q", recv_exact(connection, 8))[0]
    mask = recv_exact(connection, 4) if second & 0x80 else None
    payload = recv_exact(connection, length)
    if mask: payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return first & 0x0f, payload

def receive_text(connection):
    while True:
        opcode, payload = receive_frame(connection)
        if opcode == 1: return json.loads(payload)
        if opcode == 8: return None
        if opcode == 9: send_frame(connection, payload, 10)

def send_frame(connection, payload, opcode=1):
    payload = payload if isinstance(payload, bytes) else payload.encode()
    header = bytes([0x80 | opcode])
    if len(payload) < 126: header += bytes([len(payload)])
    elif len(payload) < 65536: header += bytes([126]) + struct.pack("!H", len(payload))
    else: header += bytes([127]) + struct.pack("!Q", len(payload))
    connection.sendall(header + payload)

def handshake(connection):
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = connection.recv(4096)
        if not chunk: raise EOFError()
        request += chunk
    lines = request.decode().split("\r\n")
    path = lines[0].split(" ")[1]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
    return path, headers

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(4)
while True:
    connection, _ = listener.accept()
    try:
        path, headers = handshake(connection)
        break
    except Exception:
        connection.close()

token = headers["x-codex-client-session-token"].split(" ", 1)[1]
token_hash = base64.urlsafe_b64encode(hashlib.sha256(token.encode()).digest()).decode().rstrip("=")
challenge = {
    "type": "device_key_challenge", "nonce": "nonce-1",
    "purpose": "remote_control_client_websocket", "audience": "remote_control_client_websocket",
    "sessionId": "session-1", "targetOrigin": "http://127.0.0.1:%d" % port,
    "targetPath": path, "accountUserId": "account-user-1", "clientId": "client-1",
    "tokenSha256Base64url": token_hash, "tokenExpiresAt": expiration,
    "scopes": ["remote_control_controller_websocket"]
}
send_frame(connection, json.dumps(challenge, separators=(",", ":")))
proof = receive_text(connection)
envelope = receive_text(connection)
stream_id = envelope["stream_id"]
send_frame(connection, json.dumps({"type": "server_message", "client_id": "client-1", "seq_id": 0, "stream_id": stream_id, "env_id": "env-1", "cursor": None, "message": {"server": "accepted"}}, separators=(",", ":")))
try:
    while True:
        value = receive_text(connection)
        if value is None or value.get("type") == "client_closed": break
except Exception:
    pass
connection.close()
listener.close()
descriptor, temporary_path = tempfile.mkstemp(dir=os.path.dirname(report_path) or ".", prefix=".remote-report-")
try:
    with os.fdopen(descriptor, "w") as output: json.dump({"proof": proof, "message": envelope["message"]}, output)
    os.replace(temporary_path, report_path)
except Exception:
    try: os.unlink(temporary_path)
    except FileNotFoundError: pass
    raise
"""#

private let remoteErrorServerSource = #"""
#!/usr/bin/python3
import base64, hashlib, json, socket, struct, sys

port = int(sys.argv[1])

def recv_exact(connection, count):
    output = b""
    while len(output) < count:
        value = connection.recv(count - len(output))
        if not value: raise EOFError()
        output += value
    return output

def receive_frame(connection):
    first, second = recv_exact(connection, 2)
    length = second & 0x7f
    if length == 126: length = struct.unpack("!H", recv_exact(connection, 2))[0]
    elif length == 127: length = struct.unpack("!Q", recv_exact(connection, 8))[0]
    mask = recv_exact(connection, 4) if second & 0x80 else None
    payload = recv_exact(connection, length)
    if mask: payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return first & 0x0f, payload

def receive_text(connection):
    while True:
        opcode, payload = receive_frame(connection)
        if opcode == 1: return json.loads(payload)
        if opcode == 8: return None
        if opcode == 9: send_frame(connection, payload, 10)

def send_frame(connection, payload, opcode=1):
    payload = payload if isinstance(payload, bytes) else payload.encode()
    header = bytes([0x80 | opcode])
    if len(payload) < 126: header += bytes([len(payload)])
    elif len(payload) < 65536: header += bytes([126]) + struct.pack("!H", len(payload))
    else: header += bytes([127]) + struct.pack("!Q", len(payload))
    connection.sendall(header + payload)

def handshake(connection):
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = connection.recv(4096)
        if not chunk: raise EOFError()
        request += chunk
    headers = {}
    for line in request.decode().split("\r\n")[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())

def send_message(connection, sequence, stream_id, payload):
    envelope = {"type":"server_message", "client_id":"client-1", "seq_id":sequence, "stream_id":stream_id, "env_id":"env-1", "cursor":None, "message":payload}
    send_frame(connection, json.dumps(envelope, separators=(",", ":")))

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(4)
while True:
    connection, _ = listener.accept()
    try:
        handshake(connection)
        break
    except Exception:
        connection.close()

first = receive_text(connection)
second = receive_text(connection)
assert first["message"]["id"] == "first"
assert second["message"]["id"] == 2
stream_id = first["stream_id"]
send_message(connection, 1, stream_id, {"type":"error", "id":2, "error":{"code":-32002, "message":"second failed", "data":{"order":2}}})
send_message(connection, 2, stream_id, {"id":"first", "result":{"ok":True}})
send_message(connection, 3, stream_id, {"type":"error", "id":999, "code":-32099, "message":"unknown"})
send_message(connection, 4, stream_id, {"type":"error", "code":-32100, "message":"missing id"})
try:
    while True:
        value = receive_text(connection)
        if value is None or value.get("type") == "client_closed": break
except Exception:
    pass
connection.close()
listener.close()
"""#
#endif
