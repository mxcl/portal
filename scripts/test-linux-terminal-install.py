#!/usr/bin/env python3
"""Verify installing renamed helpers preserves a live legacy state directory."""
import os
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary).resolve()
    stage = root / 'stage'
    stage.mkdir()
    legacy = root / '.local/state/gitinuum-terminal'
    legacy.mkdir(parents=True)
    (legacy / 'history.json').write_text('preserved')
    for name in ('portal-sessiond', 'portal-session-bridge'):
        helper = stage / name
        helper.write_text('#!/bin/sh\necho test-helper\n')
        helper.chmod(0o755)
    for _ in range(2):
        subprocess.run(['bash', str(Path(__file__).with_name('install-linux-terminal-staged.sh')), str(stage)],
                       env=dict(os.environ, HOME=str(root), XDG_STATE_HOME=str(root / '.local/state')), check=True)
        assert (root / '.local/state/portal-terminal').resolve() == legacy
        assert (legacy / 'history.json').read_text() == 'preserved'
        assert (root / '.local/lib/portal/terminal/portal-session-bridge').is_file()
print('Linux terminal installation and repeated upgrades preserve legacy state.')
