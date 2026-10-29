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
    staged = applications / ".portal-app.install.test"
    staged.mkdir(parents=True)
    terminal = applications / ".portal-terminal.install.test"
    terminal.mkdir()
    terminal_backup = applications / ".portal-terminal.previous.test"
    captured = root / "environment.json"
    stopped = root / "stopped.json"
    retired = root / "retired.jsonl"
    commands = root / "bin"
    commands.mkdir()
    stubs = {
        "codesign": '#!/bin/sh\n[ "$4" != "$FAIL_SIGNATURE" ]\n',
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
            f"assert sys.argv[1:] == {[str(applications / 'Portal Hub.app')]!r}\n"
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
    legacy = root / "Library/Application Support/GitSync"
    legacy.mkdir(parents=True)
    (legacy / "state.json").write_text('{"epoch":"preserve-me"}')
    subprocess.run(["/bin/bash", str(installer), str(staged),
                    str(applications / ".portal-app.previous.test"), str(terminal), str(terminal_backup)], env=environment, check=True)
    migrated = root / "Library/Application Support/Portal/Sync"
    assert legacy.is_symlink()
    assert (migrated / "state.json").read_text() == '{"epoch":"preserve-me"}'
    legacy_service = f"gui/{os.getuid()}/dev.mxcl.git-sync.menu-helper"
    assert [json.loads(line) for line in retired.read_text().splitlines()] == [
        ["disable", legacy_service], ["bootout", legacy_service]
    ]
    launched = json.loads(captured.read_text())
    stop_args = json.loads(stopped.read_text())
    assert stop_args[0] == "-x", stop_args
    assert not re.fullmatch(stop_args[1], "portal-sessiond"), stop_args
    assert not re.fullmatch(stop_args[1], "gitinuum-sessiond"), stop_args
    assert not re.fullmatch(stop_args[1], "dev.mxcl.git-sync.sessiond"), stop_args
    assert not pollution.keys() & launched.keys(), launched
    assert not any(name.startswith("CODEX_") for name in launched), launched
    for name in ("HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"):
        assert launched[name] == environment[name], (name, launched)
    assert launched["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", launched

    assert (applications / "Portal.app").is_dir()

    # Failure after swapping either bundle must restore both previous apps.
    (applications / "Portal Hub.app" / "old").touch()
    (applications / "Portal.app" / "old").touch()
    for failed_app in ("Portal Hub.app", "Portal.app"):
        staged.mkdir()
        terminal.mkdir()
        result = subprocess.run(["/bin/bash", str(installer), str(staged),
                                 str(applications / ".portal-app.previous.test"),
                                 str(terminal), str(terminal_backup)],
                                env=dict(environment, FAIL_SIGNATURE=str(applications / failed_app)),
                                capture_output=True)
        assert result.returncode != 0
        assert (applications / "Portal Hub.app" / "old").is_file()
        assert (applications / "Portal.app" / "old").is_file()
        assert not terminal_backup.exists()
        assert not (applications / ".portal-app.previous.test").exists()
    terminal.mkdir()

    # A collision must leave both stores untouched and the staged app uninstalled.
    legacy.unlink()
    legacy.mkdir()
    (legacy / "state.json").write_text('legacy-conflict')
    staged.mkdir()
    result = subprocess.run(["/bin/bash", str(installer), str(staged),
                             str(applications / ".portal-app.previous.test"), str(terminal), str(terminal_backup)],
                            env=environment, capture_output=True)
    assert result.returncode != 0
    assert (legacy / "state.json").read_text() == 'legacy-conflict'
    assert (migrated / "state.json").read_text() == '{"epoch":"preserve-me"}'
    assert staged.is_dir()

print("Deployment environment and state migration regressions passed")
