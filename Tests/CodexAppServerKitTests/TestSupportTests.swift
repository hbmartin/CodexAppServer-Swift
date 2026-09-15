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

@Test func testGateReleasesAllWaitersAndResetsWaitingState() async {
    let gate = CodexTestGate()
    async let first: Void = gate.wait()
    async let second: Void = gate.wait()
    for _ in 0..<1_000 {
        if await gate.waiterCount() == 2 { break }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await gate.waiterCount() == 2)
    await gate.release()
    _ = await (first, second)
    #expect(await gate.isWaiting() == false)
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
