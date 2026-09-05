import Foundation
#if os(macOS)
import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, ["help", "--help", "-h"].contains(first) {
    print("""
    Usage: gitinuum [COMMAND [ARGUMENTS...]]

    With no arguments, opens Gitinuum.
    Commands are forwarded to Gitinuum's bundled git-sync tool.
    Use `gitinuum --sync-help` to list sync commands.
    """)
    exit(0)
}

guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.mxcl.git-sync") else {
    FileHandle.standardError.write(Data("gitinuum: Install and open Gitinuum.app first.\n".utf8))
    exit(1)
}

let executable = arguments.isEmpty ? "/usr/bin/open" : app.appendingPathComponent("Contents/Resources/git-sync").path
let forwarded = arguments.isEmpty ? [app.path] : (arguments == ["--sync-help"] ? ["--help"] : arguments)
let argv = ([executable] + forwarded).map { strdup($0) } + [nil]
argv.withUnsafeBufferPointer { buffer in
    _ = execv(executable, buffer.baseAddress!)
}
perror("gitinuum")
exit(1)
#else
FileHandle.standardError.write(Data("gitinuum: The Gitinuum app requires macOS. Use git-sync on this platform.\n".utf8))
exit(1)
#endif
