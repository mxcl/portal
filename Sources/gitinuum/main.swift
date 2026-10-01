import Foundation
#if os(macOS)
import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, ["help", "--help", "-h"].contains(first) {
    print("""
    Usage: gitinuum [REPOSITORY_PATH]

    With no arguments, opens Portal.
    Pass a repository path (or a directory inside it) to select that project.
    Use `gitinuum --sync-help` to list sync commands.
    """)
    exit(0)
}

guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.mxcl.portal") else {
    FileHandle.standardError.write(Data("gitinuum: Install and open Portal.app first.\n".utf8))
    exit(1)
}

let executable: String
let forwarded: [String]
do {
    if arguments == ["--sync-help"] {
        executable = app.appendingPathComponent("Contents/Resources/gitinuumd").path
        forwarded = ["--help"]
    } else {
        guard arguments.count <= 1 else {
            throw NSError(domain: "gitinuum", code: 64, userInfo: [NSLocalizedDescriptionKey: "Usage: gitinuum [REPOSITORY_PATH]"])
        }
        executable = "/usr/bin/open"
        if let path = arguments.first {
            forwarded = ["-a", app.path, try projectURL(path: path).absoluteString]
        } else {
            forwarded = [app.path]
        }
    }
} catch {
    FileHandle.standardError.write(Data("gitinuum: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let argv = ([executable] + forwarded).map { strdup($0) } + [nil]
argv.withUnsafeBufferPointer { buffer in
    _ = execv(executable, buffer.baseAddress!)
}
perror("gitinuum")
exit(1)
#else
FileHandle.standardError.write(Data("gitinuum: The Portal app requires macOS. Use gitinuumd on this platform.\n".utf8))
exit(1)
#endif
