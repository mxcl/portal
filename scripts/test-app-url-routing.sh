#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 - "$repo" "$scratch" <<'PY'
import pathlib, sys
repo, scratch = map(pathlib.Path, sys.argv[1:])
source = (repo / 'Sources/PortalApp/PortalApp.swift').read_text()
delegate = source[source.index('@MainActor\nfinal class AppDelegate:'):source.index('\nprivate struct HostDraft')]
(scratch / 'Delegate.swift').write_text('import AppKit\n' + delegate)
PY
cat > "$scratch/Probe.swift" <<'SWIFT'
import AppKit

@MainActor enum TerminalApplication {
    static var requests: [[URL]] = []
    static func open(_ urls: [URL] = []) { requests.append(urls) }
}
@main struct Probe {
    @MainActor static func main() {
        let delegate = AppDelegate()
        let application = NSApplication.shared
        for address in ["portal://palette", "portal://settings", "portal://github-connected", "gitsync://project?name=example"] {
            delegate.application(application, open: [URL(string: address)!])
        }
        guard TerminalApplication.requests.isEmpty else {
            print("FAIL: Portal URLs launched Portal")
            exit(1)
        }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        delegate.application(application, open: [URL(string: "portal://palette")!, directory])
        guard TerminalApplication.requests == [[directory]] else {
            print("FAIL: file-open routing did not forward only the file URL")
            exit(1)
        }
        print("PASS: Portal URLs do not launch Terminal; file URLs still do")
    }
}
SWIFT
swiftc -parse-as-library "$scratch/Delegate.swift" "$scratch/Probe.swift" -o "$scratch/probe"
"$scratch/probe"
