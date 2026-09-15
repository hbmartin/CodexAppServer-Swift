import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerTestSupport

@Test func testGateRemembersAnEarlyRelease() async {
    let gate = CodexTestGate()
    await gate.release()
    await gate.wait()
    await gate.wait()
    #expect(await gate.isWaiting() == false)
}

@Test func testGateReleasesAllWaitersAndResetsWaitingState() async throws {
    let gate = CodexTestGate()
    async let first: Void = gate.wait()
    async let second: Void = gate.wait()
    try await gate.waitForWaiters(2)
    await gate.release()
    _ = await (first, second)
    #expect(await gate.isWaiting() == false)
}

@Test func testGateWaiterTimeoutReportsExpectedAndActualCounts() async {
    let gate = CodexTestGate()
    await #expect(throws: CodexTestGateError.timedOut(expectedWaiters: 1, actualWaiters: 0)) {
        try await gate.waitForWaiters(1, timeout: .zero)
    }
}

@Test func scriptedTransportEchoesThreadIDsAndHonorsOverrides() async throws {
    let transport = CodexScriptedTransport.scripted()
    let client = try await CodexClient.connectedTestClient(transport)
    #expect(try await client.resumeThread(id: "one").id == "one")
    #expect(try await client.readThread(id: "two").id == "two")
    let first = await transport.requestID(method: "thread/read")
    await transport.setResults(["thread/read": ["thread": ["id": "configured"]]])
    #expect(try await client.readThread(id: "three").id == "configured")
    let latest = await transport.messages().last?["id"]
    #expect(await transport.requestID(method: "thread/read") == latest)
    #expect(first != latest)
    await client.close()
}
