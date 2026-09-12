import Testing
import CodexAppServerObservation

@MainActor @Test func observationModelStartsDisconnected() { #expect(CodexConnectionModel().state == .disconnected) }
