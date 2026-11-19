#!/usr/bin/env python3
"""Exercise the menu helper lock across processes without starting sync."""

from pathlib import Path
import select
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="portal-helper-lock-") as temporary:
    scratch = Path(temporary)
    probe = scratch / "main.swift"
    probe.write_text("""
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
if let descriptor = try acquireMenuHelperLock(at: url) {
    FileHandle.standardOutput.write(Data("acquired\\n".utf8))
    if CommandLine.arguments.count == 3 { _ = readLine() }
    close(descriptor)
} else {
    print("already held")
}
""")
    binary = scratch / "check"
    subprocess.run([
        "swiftc", str(repo / "Sources/PortalMenuBar/MenuHelperLock.swift"),
        str(probe), "-o", str(binary),
    ], check=True, timeout=60)
    command = [str(binary), str(scratch / "Portal" / "menu-helper.lock")]
    with subprocess.Popen([*command, "--hold"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as owner:
        try:
            readable, _, _ = select.select([owner.stdout], [], [], 5)
            assert readable and owner.stdout.readline() == b"acquired\n"
            duplicate = subprocess.check_output(command, timeout=5)
            assert duplicate == b"already held\n", duplicate
        finally:
            owner.kill()
            owner.wait(timeout=5)

    assert Path(command[1]).is_file()
    restarted = subprocess.check_output(command, timeout=5)
    assert restarted == b"acquired\n", restarted
    print("Menu helper lock rejects a duplicate and can be reacquired after a crash")
