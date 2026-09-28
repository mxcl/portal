#!/usr/bin/env python3
"""Exercise the shared installer with fake platform commands; never install an app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


with tempfile.TemporaryDirectory(prefix="gitinuum-deploy-test-") as temporary:
    root = Path(temporary)
    applications = root / "Applications"
    staged = applications / ".git-sync-app.install.test"
    staged.mkdir(parents=True)
    captured = root / "environment.json"
    commands = root / "bin"
    commands.mkdir()
    stubs = {
        "codesign": "#!/bin/sh\nexit 0\n",
        "lsof": "#!/bin/sh\nexit 0\n",
        "pkill": "#!/bin/sh\nexit 1\n",
        "launchctl": "#!/bin/sh\nexit 1\n",
        "pgrep": '#!/bin/sh\n[ "$2" = GitinuumApp ]\n',
        "open": (
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"assert sys.argv[1:] == {[str(applications / 'Gitinuum.app')]!r}\n"
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
    for command in ("/usr/bin/codesign", "/usr/sbin/lsof", "/usr/bin/open"):
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
    launched = json.loads(captured.read_text())
    assert not pollution.keys() & launched.keys(), launched
    assert not any(name.startswith("CODEX_") for name in launched), launched
    for name in ("HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"):
        assert launched[name] == environment[name], (name, launched)
    assert launched["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", launched

print("Deployment launch environment regression passed")
