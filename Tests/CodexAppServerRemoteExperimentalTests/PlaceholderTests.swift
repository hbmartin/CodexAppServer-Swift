import Testing
import CodexAppServerRemoteExperimental

@Test func pairingCodeParsesQR() throws { #expect(try WHAMPairingCode(qrPayload: "codex://pair?code=123456").value == "123456") }
