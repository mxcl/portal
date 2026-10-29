#!/usr/bin/env python3
"""Run the film cues through Portal's existing session bridge."""
import base64
import json
import queue
import subprocess
import sys
import threading
import time

BRIDGE = '/Applications/Portal.app/Contents/Helpers/portal-session-bridge'
def b64(text):
    return base64.b64encode(text.encode()).decode()

def connect():
    listing = subprocess.run([BRIDGE], input='LIST\n', text=True, capture_output=True, check=True).stdout
    sessions = json.loads(base64.b64decode(listing.split()[1]))
    matches = [s for s in sessions if s['cwd'] == '/tmp/orbit']
    assert len(matches) == 1, 'Expected exactly one isolated /tmp/orbit session'
    process = subprocess.Popen([BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    events = queue.Queue()
    def read():
        for line in process.stdout: events.put(line.strip())
    threading.Thread(target=read, daemon=True).start()
    def send(line):
        process.stdin.write(line+'\n'); process.stdin.flush()
    send(f'JOIN2 2 mac {b64("portal-film-director")} {b64(matches[0]["sessionId"])}')
    deadline = time.monotonic()+10
    while not events.get(timeout=max(.01,deadline-time.monotonic())).startswith('READY '): pass
    return process, events, send

CUES = [(2,'explore'),(4.5,'graph'),(6.5,'check'),(8.5,'build'),(12,'test'),
        (14,'bench'),(16,'diff'),(18,'assets'),(20,'status'),(22,'preview')]

def command_script(scene):
    assert scene in [s for _,s in CUES]
    command = 'orbit '+scene
    # Same C/P/D command lifecycle markers as PortalCommandEnvelope.shellScript.
    return (f"\x15stty -echo\nprintf '\\033]133;C;{b64(command)}\\a'; "
            f"{command}; __portal_status=$?; "
            "printf '\\033]133;P;%s\\a' \"$(pwd | base64)\"; "
            "printf '\\033]133;D;%s\\a' \"$__portal_status\"\n")

if __name__ == '__main__':
    if sys.argv[1] == '--self-test':
        assert len(CUES) == 10 and len(set(s for _,s in CUES)) == 10
        for _, scene in CUES:
            script = command_script(scene)
            assert script.count('133;C;') == script.count('133;D;') == 1
        print('Ten unique cues; command lifecycle envelopes validated.')
        sys.exit()
    process, events, send = connect()
    if sys.argv[1] == '--rehearse':
        cues = [(0,'status')]
        start = time.monotonic()
        recorder = None
    else:
        recorder = subprocess.Popen(['/tmp/portal-film/record', sys.argv[1], '31'] + (['--display'] if '--display' in sys.argv else []), stdout=subprocess.PIPE, text=True)
        for line in recorder.stdout:
            print(line.strip(), flush=True)
            if line.startswith('RECORDING '): break
        else: raise RuntimeError('Recorder did not start')
        start = time.monotonic()
        cues = CUES
    try:
        for at, scene in cues:
            time.sleep(max(0,start+at-time.monotonic()))
            send('INPUT '+b64(command_script(scene)))
            deadline = time.monotonic()+8
            complete = ''
            while '\x1b]133;D;' not in complete:
                line = events.get(timeout=max(.01,deadline-time.monotonic()))
                if line.startswith(('OUTPUT ', 'OUTPUT2 ')):
                    complete += base64.b64decode(line.split()[-1]).decode(errors='replace')
            assert '\x1b]133;D;0\x07' in complete, complete
            print(f'{scene}: {time.monotonic()-start:.2f}s',flush=True)
        if recorder: assert recorder.wait(timeout=40) == 0
    finally:
        process.stdin.close()
        process.terminate()
        process.wait(timeout=5)
