#!/usr/bin/env python3
"""Exercise the shipped bridge/daemon pair in an isolated runtime directory."""
import base64
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


def encoded(text):
    return base64.b64encode(text.encode()).decode()


class Client:
    def __init__(self, bridge, environment):
        self.process = subprocess.Popen([str(bridge)], env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.lines.put(line.rstrip('\n'))
            self.lines.put(None)
        threading.Thread(target=read, daemon=True).start()

    def send(self, line):
        self.process.stdin.write(line + '\n')
        self.process.stdin.flush()

    def until(self, predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            assert line is not None, self.process.stderr.read()
            if predicate(line):
                return line
        raise AssertionError('terminal response timed out')

    def output_contains(self, text):
        output = ''
        def match(line):
            nonlocal output
            if line.startswith(('OUTPUT ', 'OUTPUT2 ', 'HISTORY ', 'HISTORY_PAGE ')):
                output += base64.b64decode(line.split(' ')[-1]).decode(errors='replace')
            return text in output
        self.until(match)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)


def main():
    helpers = Path(sys.argv[1]).resolve() / 'Contents/Helpers'
    bridge = helpers / 'gitinuum-session-bridge'
    daemon = helpers / 'Portal Session Helper.app/Contents/MacOS/gitinuum-sessiond'
    # Also support the installed Linux pair.
    if not bridge.exists():
        bridge = Path(sys.argv[1]).resolve() / 'gitinuum-session-bridge'
        daemon = bridge.with_name('gitinuum-sessiond')
    with tempfile.TemporaryDirectory(prefix='terminal-session-', dir='/tmp') as temp:
        environment = dict(os.environ, GITINUUM_SESSIOND_SOCKET=temp + '/s.sock',
                           GITINUUM_SESSIOND_REQUIRE_EXISTING='1')
        server = subprocess.Popen([str(daemon), 'serve'], env=environment,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        clients = []
        try:
            for _ in range(100):
                if Path(environment['GITINUUM_SESSIOND_SOCKET']).exists():
                    break
                time.sleep(0.02)
            for version in (1, 2):
                client = Client(bridge, environment)
                clients.append(client)
                client.send('PROTOCOLS')
                assert client.until(lambda line: line.startswith('PROTOCOLS')) == 'PROTOCOLS 1 2'
                # Discovery is a separate, one-shot connection.
                client.close()
                client = Client(bridge, environment)
                clients.append(client)
                session = 'survival-' + str(version)
                fields = ' '.join(map(encoded, [session, temp, '/bin/sh', 'TERM=xterm-256color\0PS1=']))
                attach = 'ATTACH ' + fields if version == 1 else 'ATTACH2 2 mac ' + encoded('test-client') + ' ' + fields
                client.send(attach)
                client.until(lambda line: line.startswith('READY '))
                # Redirection proves a single shell kept executing while all clients detached.
                command = "stty -echo; printf 'before-disconnect\\n'; sleep 1; printf done > survived-" + str(version) + "\n"
                client.send('INPUT ' + encoded(command))
                client.output_contains('before-disconnect')
                client.close()
                deadline = time.monotonic() + 5
                result = Path(temp) / ('survived-' + str(version))
                while not result.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert result.read_text() == 'done'
                resumed = Client(bridge, environment)
                clients.append(resumed)
                resumed.send(attach if version == 1 else 'JOIN2 2 mac ' + encoded('reattached') + ' ' + encoded(session))
                resumed.until(lambda line: line.startswith('READY 0'))
                resumed.output_contains('before-disconnect')
                resumed.send('INPUT ' + encoded("printf 'reattached-ok\\n'\n"))
                resumed.output_contains('reattached-ok')
                resumed.send('INPUT ' + encoded('exit\n'))
                resumed.until(lambda line: line.startswith('EXIT '))
                resumed.close()
            print('Terminal v1/v2 detach, history replay, reattach, and exit checks passed.')
        finally:
            for client in clients:
                if client.process.poll() is None:
                    client.process.kill()
                    client.process.wait()
            server.terminate()
            server.wait(timeout=3)


if __name__ == '__main__':
    main()
