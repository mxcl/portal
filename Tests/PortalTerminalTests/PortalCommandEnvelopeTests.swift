#if os(macOS)
import Foundation
import Darwin
import Testing
@testable import PortalTerminal

@Suite("Portal command envelope")
struct PortalCommandEnvelopeTests {
    @Test("bash acknowledges its line editor bootstrap before full shell setup")
    @MainActor func bashInitialization() throws {
        var master: Int32 = -1, slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-i"]
        process.environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "__READY_PROMPT__"]
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        let setup = """
        export PORTAL=1
        export TERM=xterm-256color
        export TERM_PROGRAM=Gitinuum
        export TERM_PROGRAM_VERSION='0.1.0'
        export LC_TERMINAL=Gitinuum
        export LC_TERMINAL_VERSION='0.1.0'
        export __CFBundleIdentifier='dev.mxcl.git-sync'
        \(TerminalViewController.remoteCodeFunctionScript)
        \(PortalCommandEnvelope.inputSetupScript)
        PROMPT=''
        RPROMPT=''
        setopt no_prompt_cr 2>/dev/null || true
        printf '\\033]133;R;%s\\a' "$(pwd | base64)"

        """
        var bytes = [UInt8](repeating: 0, count: 65536)
        // Wait for bash's first prompt before submitting setup to its real line editor.
        var output = ""
        var deadline = Date().addingTimeInterval(3)
        while !output.contains("__READY_PROMPT__") && Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, 10) > 0 ? read(master, &bytes, bytes.count) : 0
            if count > 0 { output += String(decoding: bytes.prefix(count), as: UTF8.self) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(output.contains("__READY_PROMPT__"))
        deadline = Date().addingTimeInterval(3)
        let input = Array(PortalCommandEnvelope.shellBootstrapScript.utf8)
        let writeFD = master
        Thread.detachNewThread {
            var offset = 0
            let writeDeadline = Date().addingTimeInterval(3)
            while offset < input.count && Date() < writeDeadline {
                let written = input.withUnsafeBytes { write(writeFD, $0.baseAddress!.advanced(by: offset), input.count - offset) }
                if written > 0 { offset += written }
                else { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
        output = ""
        while !output.contains("\u{1B}]133;R;") && Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, 10) > 0 ? read(master, &bytes, bytes.count) : 0
            if count > 0 { output += String(decoding: bytes.prefix(count), as: UTF8.self) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(output.contains("\u{1B}]133;R;"))
        output = ""
        let payload = Array(setup.utf8)
        Thread.detachNewThread {
            _ = payload.withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
        }
        deadline = Date().addingTimeInterval(3)
        while !output.contains("\u{1B}]133;R;") && Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, 10) > 0 ? read(master, &bytes, bytes.count) : 0
            if count > 0 { output += String(decoding: bytes.prefix(count), as: UTF8.self) }
        }
        #expect(output.contains("\u{1B}]133;R;"))
    }

    @Test("quotes commands and emits lifecycle markers")
    func envelope() {
        let script = PortalCommandEnvelope.shellScript(for: "printf '%s' hello")

        #expect(script.hasPrefix("\u{15}"))
        #expect(script.contains("__portal_cmd='printf '\\''%s'\\'' hello'"))
        #expect(script.contains(Data("printf '%s' hello".utf8).base64EncodedString()))
        #expect(script.contains("133;C"))
        #expect(script.contains("133;P"))
        #expect(script.contains("dd bs=65536 count=1"))
        #expect(script.contains("133;I"))
        #expect(script.contains("133;D"))
        #expect(script.hasSuffix("\n"))
    }

    @Test("can exit the shell with the command status after lifecycle markers")
    func exitingEnvelope() {
        let script = PortalCommandEnvelope.shellScript(
            for: "./example.cmd",
            exitsShellAfterCompletion: true
        )

        #expect(script.hasSuffix("printf '\\033]133;D;%s\\a' \"$__portal_status\"; exit \"$__portal_status\"\n"))
    }
}

#endif
