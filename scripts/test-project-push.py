#!/usr/bin/env python3
"""Exercise the actual watch subprocess, including idle silence and reconnect."""
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time

executable = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/gitinuumd').resolve())

def frame(process, timeout=5):
    fd = process.stdout.fileno()
    def read(size):
        data = b''
        deadline = time.monotonic() + timeout
        while len(data) < size:
            assert select.select([fd], [], [], max(0, deadline - time.monotonic()))[0], 'missing pushed change'
            part = os.read(fd, size - len(data))
            assert part, 'watcher exited unexpectedly'
            data += part
        return data
    size, = struct.unpack('!I', read(4))
    assert 0 < size <= 1048576
    change = json.loads(read(size))
    assert change['version'] == 2
    return change['projects']

def quiet(process):
    deadline = time.monotonic() + 10
    while select.select([process.stdout], [], [], 1)[0]:
        frame(process)
        assert time.monotonic() < deadline, 'watcher never becomes idle'

def git(*args):
    subprocess.run(['git', *map(str, args)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory) / 'projects'
    root.mkdir()
    # External worktree metadata is not beneath the projects root.
    source = Path(directory) / 'external'
    git('init', '-q', '-b', 'main', source)
    git('-C', source, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
        'commit', '-q', '--allow-empty', '-m', 'initial')
    git('-C', source, 'worktree', 'add', '-q', '-b', 'linked', root / 'linked')
    (root / 'linked' / '.gitignore').write_text('build/\n')
    args = [executable, 'watch-projects', '--root', str(root), '--watch-version', '2']
    for attempt in range(2):
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            initial = frame(process)  # Both initial connection and reconnect must catch up.
            assert 'linked' in initial
            assert 'snapshot' in initial['linked']
            quiet(process)
            ignored = root / 'linked' / 'build'
            ignored.mkdir(exist_ok=True)
            (ignored / 'output').write_text(str(attempt))
            assert not select.select([process.stdout], [], [], 2)[0], 'ignored build output triggered a push'
            nested = root / 'linked' / f'nested-{attempt}' / 'child'
            nested.mkdir(parents=True)
            (nested / 'file').write_text('first')
            first = frame(process)
            quiet(process)
            (nested / 'file').write_text('other')  # Same length/counts, still an event.
            second = frame(process)
            assert first['linked']['revision'] != second['linked']['revision']
            quiet(process)
            git('-C', source, 'branch', f'external-change-{attempt}')
            frame(process)
            quiet(process)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                raise AssertionError('watcher survived client disconnect')
    bad = subprocess.run([*args[:-1], '999'], input=b'', capture_output=True)
    assert bad.returncode != 0, 'unsupported watch version accepted'
print('PASS: idle silence, new directories, same-count edits, external metadata, reconnect and disconnect')
