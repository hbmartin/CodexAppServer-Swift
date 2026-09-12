#if os(macOS)
import Testing
import CodexAppServerHost
import CodexAppServerKit

@Test func cliVersionOrdering() { #expect(CodexCLIVersion(major: 0, minor: 146, patch: 0) < CodexCLIVersion(major: 0, minor: 147, patch: 0)) }

@Test func sshAliasUsesBatchModeAndHostCheckingDefaults() throws {
    let args = try CodexSSHArguments.build(host: .alias("studio"), remoteArguments: ["codex", "app-server", "proxy"])
    #expect(args.starts(with: ["-o", "BatchMode=yes"]))
    #expect(args.contains("studio"))
    #expect(!args.contains(where: { $0.contains("StrictHostKeyChecking=no") }))
}

@Test func structuredSSHRejectsUnsafeOptions() {
    #expect(throws: CodexError.self) {
        try CodexSSHArguments.build(host: .structured(hostname: "host", user: nil, port: nil, identityFile: nil, options: ["ProxyCommand": "bad"]), remoteArguments: [])
    }
}
#endif
