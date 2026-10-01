#!/usr/bin/env python3
"""Isolated two-daemon CPU/subprocess/latency check; never touches user repositories.

Usage: python3 scripts/measure-sync-cpu.py /path/to/portald [--check]
Git's own Trace2 records subprocesses; no Git wrapper or production instrumentation.
"""
import collections
import ctypes
import errno
import json
import os
from pathlib import Path
import resource
import signal
import socket
import subprocess
import sys
import tempfile
import time


def process_usage(processes):
    """macOS kernel counters, including the Git children already reaped by each daemon."""
    if sys.platform != "darwin":
        return {}
    class Usage(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 18)]
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    timebase = Timebase()
    ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(timebase))
    seconds_per_tick = timebase.numer / timebase.denom / 1e9
    total = collections.Counter()
    for process in processes:
        usage = Usage()
        if libproc.proc_pid_rusage(process.pid, 2, ctypes.byref(usage)) != 0:
            raise OSError("proc_pid_rusage failed")
        v = usage.values
        total.update(cpu_seconds=(v[0] + v[1] + v[10] + v[11]) * seconds_per_tick,
                     idle_wakeups=v[2] + v[12], interrupt_wakeups=v[3] + v[13])
    return total


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL).decode().strip()


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="portal-perf-") as directory:
        root = Path(directory)
        a, b = root / "a", root / "b"
        a.mkdir()
        b.mkdir()
        project = a / "project"
        project.mkdir()
        git(project, "init", "-q", "-b", "main")
        git(project, "config", "user.name", "Test")
        git(project, "config", "user.email", "test@example.invalid")
        tracked = project / "file"
        tracked.write_text("initial\n")
        git(project, "add", ".")
        git(project, "commit", "-qm", "initial")
        for parent in (a, b):
            for n in range(25):
                (parent / f"excluded-{n}").mkdir()
        a_socket, b_socket = socket.socketpair()
        processes = []
        logs = []
        traces = []
        try:
            for name, parent, stream in (("A", a, a_socket), ("B", b, b_socket)):
                trace = root / f"{name}.trace"
                traces.append(trace)
                log = (root / f"{name}.log").open("w")
                logs.append(log)
                processes.append(subprocess.Popen([
                    binary, "daemon", "--stdio", "--root", str(parent), "--machine", name,
                    "--state", str(root / f"{name}.state"), "--selective", "--repository", "project",
                    "--sync-checkouts",
                ], stdin=stream, stdout=stream, stderr=log, start_new_session=True,
                    env={**os.environ, "GIT_TRACE2_EVENT": str(trace)}))

            def await_ref(expected):
                start = time.monotonic()
                while time.monotonic() - start < 15:
                    try:
                        if git(b / "project", "rev-parse", "refs/remotes/a/main") == expected:
                            return round(time.monotonic() - start, 3)
                    except subprocess.CalledProcessError:
                        pass
                    time.sleep(0.05)
                raise AssertionError("ref did not replicate within 15 seconds")

            def events():
                result = []
                for path in traces:
                    if path.exists():
                        for line in path.read_text().splitlines():
                            try:
                                event = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            if event.get("event") == "start":
                                result.append(event)
                return [event["argv"] for event in sorted(result, key=lambda event: event["time"])]

            await_ref(git(project, "rev-parse", "HEAD"))
            time.sleep(3)
            measurements = {}
            for phase in ("idle", "unrelated-writes", "active"):
                before = len(events())
                usage_before = process_usage(processes)
                start = time.monotonic()
                latency = []
                if phase == "active":
                    for n in range(3):
                        tracked.write_text(f"commit {n}\n")
                        git(project, "add", ".")
                        git(project, "commit", "-qm", f"commit {n}")
                        latency.append(await_ref(git(project, "rev-parse", "HEAD")))
                else:
                    for n in range(24):
                        if phase == "unrelated-writes":
                            (a / "excluded-0" / "build-output").write_text(str(n))
                        time.sleep(0.25)
                commands = events()[before:]
                usage = {key: round(value - usage_before[key], 6)
                         for key, value in process_usage(processes).items()}
                counts = collections.Counter(command[command.index("-C") + 2] if "-C" in command else command[1]
                                             for command in commands)
                measurements[phase] = {"seconds": round(time.monotonic() - start, 3),
                                       "git_processes": len(commands), "commands": dict(counts),
                                       "sync_latency_seconds": latency, **usage}
            # Background replication must leave the destination's local branch alone.
            assert not git(b / "project", "for-each-ref", "--format=%(refname)", "refs/heads")
            print(json.dumps(measurements, indent=2), flush=True)
            if "--check" in sys.argv:
                assert measurements["idle"]["git_processes"] == 0, "idle daemon launches Git"
                assert measurements["unrelated-writes"]["git_processes"] == 0, "unrelated writes wake Git scans"
                assert all("excluded-" not in " ".join(command) for command in events()), "disabled projects invoke Git"
        finally:
            try:
                a_socket.shutdown(socket.SHUT_RDWR)
            except OSError as error:
                if error.errno != errno.ENOTCONN:
                    raise
            a_socket.close()
            b_socket.close()
            for process in processes:
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    raise
            for log in logs:
                log.close()
            usage = resource.getrusage(resource.RUSAGE_CHILDREN)
            print(json.dumps({"children_cpu_seconds": round(usage.ru_utime + usage.ru_stime, 3),
                              "voluntary_context_switches": usage.ru_nvcsw,
                              "involuntary_context_switches": usage.ru_nivcsw}))


if __name__ == "__main__":
    main()
