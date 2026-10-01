#!/usr/bin/env python3
"""Exercise the shared installer with fake platform commands; never install an app."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


with tempfile.TemporaryDirectory(prefix="gitinuum-deploy-test-") as temporary:
    root = Path(temporary)
    applications = root / "Applications"
    staged = applications / ".git-sync-app.install.test"
    staged.mkdir(parents=True)
    captured = root / "environment.json"
    stopped = root / "stopped.json"
    retired = root / "retired.jsonl"
    commands = root / "bin"
    commands.mkdir()
    stubs = {
        "codesign": "#!/bin/sh\nexit 0\n",
        "lsof": "#!/bin/sh\nexit 0\n",
        "lsregister": "#!/bin/sh\nexit 0\n",
        "pkill": (
            f"#!{sys.executable}\nimport json, sys\n"
            f"with open({str(stopped)!r}, 'w') as output:\n"
            "    json.dump(sys.argv[1:], output)\n"
        ),
        "launchctl": (
            f"#!{sys.executable}\nimport json, sys\n"
            "action, service = sys.argv[1:]\n"
            "if service.endswith('/dev.mxcl.git-sync.menu-helper'):\n"
            "    if action in ('disable', 'bootout'):\n"
            f"        with open({str(retired)!r}, 'a') as output: output.write(json.dumps([action, service]) + '\\n')\n"
            "    sys.exit(0)\n"
            "sys.exit(1)\n"
        ),
        "pgrep": '#!/bin/sh\n[ "$2" = PortalApp ]\n',
        "open": (
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"assert sys.argv[1:] == {[str(applications / 'Portal.app')]!r}\n"
            f"with open({str(captured)!r}, 'w') as output:\n"
            "    json.dump(dict(os.environ), output)\n"
        ),
    }
    for name, body in stubs.items():
        command = commands / name
        command.write_text(body)
        command.chmod(0o755)

    script = Path(__file__).with_name("install-staged.sh").read_text()
    script = script.replace("/Applications/", f"{applications}/")
    for command in ("/usr/bin/codesign", "/usr/sbin/lsof", "/usr/bin/open",
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"):
        script = script.replace(command, str(commands / Path(command).name))
    installer = root / "installer.sh"
    installer.write_text(script)
    environment = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin:/usr/sbin:/sbin")
    environment.update(HOME=str(root), USER="tester", LOGNAME="tester", SHELL="/bin/zsh", TMPDIR=str(root))
    pollution = {
        "NO_COLOR": "1", "NOCOLOR": "1", "CLICOLOR": "0", "FORCE_COLOR": "0",
        "CODEX_THREAD_ID": "test", "CODEX_FUTURE_VARIABLE": "test",
        "TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat", "RUST_LOG": "debug",
    }
    environment.update(pollution)
    subprocess.run(["/bin/bash", str(installer), str(staged),
                    str(applications / ".git-sync-app.previous.test")], env=environment, check=True)
    legacy_service = f"gui/{os.getuid()}/dev.mxcl.git-sync.menu-helper"
    assert [json.loads(line) for line in retired.read_text().splitlines()] == [
        ["disable", legacy_service], ["bootout", legacy_service]
    ]
    launched = json.loads(captured.read_text())
    stop_args = json.loads(stopped.read_text())
    assert stop_args[0] == "-x", stop_args
    assert not re.fullmatch(stop_args[1], "portal-sessiond"), stop_args
    assert re.fullmatch(stop_args[1], "gitinuum-sessiond"), stop_args
    assert not re.fullmatch(stop_args[1], "dev.mxcl.git-sync.sessiond"), stop_args
    assert not pollution.keys() & launched.keys(), launched
    assert not any(name.startswith("CODEX_") for name in launched), launched
    for name in ("HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"):
        assert launched[name] == environment[name], (name, launched)
    assert launched["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", launched

print("Deployment launch environment regression passed")
