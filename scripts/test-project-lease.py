#!/usr/bin/env python3
"""Keep stdin open to reproduce an SSH half-open; only the live client renews."""
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time

executable = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    processes = []
    try:
        for name in ('stale', 'live'):
            root = Path(directory) / name
            root.mkdir()
            p = subprocess.Popen([executable, 'watch-projects', '--root', str(root), '--watch-version', '3'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(p)
            assert select.select([p.stdout], [], [], 10)[0], 'missing initial snapshot'
            size, = struct.unpack('!I', p.stdout.read(4))
            message = json.loads(p.stdout.read(size))
            assert message == {'version': 3, 'projects': {}}, message
            p.stdin.write(b'\0'); p.stdin.flush()
        stale, live = processes
        started = last_renewal = time.monotonic()
        expired = None
        while time.monotonic() - started < 100:
            now = time.monotonic()
            if now - last_renewal >= 20:
                live.stdin.write(b'\0'); live.stdin.flush()
                last_renewal = now
            assert live.poll() is None, 'healthy lease disconnected'
            assert not select.select([live.stdout], [], [], 0)[0], 'heartbeat triggered a project update'
            if stale.poll() is not None and expired is None:
                expired = now - started
            time.sleep(0.5)
        assert expired is not None and 85 <= expired <= 96, ('stale session did not expire on time', expired)
        print('PASS: stale open stdin expired at %.1fs; renewed stream stayed silent and alive for 100s' % expired)
    finally:
        for p in processes:
            p.stdin.close()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait()
                raise AssertionError('watcher survived client EOF')
