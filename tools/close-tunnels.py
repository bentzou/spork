#!/usr/bin/env python3
"""Close dedicated gcloud SQL tunnel terminal groups inside one clone."""

import os
import re
import signal
import subprocess
import sys
import time


# Match the complete wrapper, never an arbitrary shell containing tunnel text.
# Restrict arguments to plain words so shell operators/substitutions cannot match.
WRAPPER = re.compile(
    r"(?:/[^\s]+/)?bash -c gcloud compute ssh [\w.-]+ "
    r"--project=[\w.-]+ --zone=[\w.-]+ --tunnel-through-iap -- "
    r"-N -L [0-9]+:[\w.-]+:[0-9]+; "
    r"read -p 'Tunnel exited\. Press Enter to close\.'"
)


def snapshot():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,uid=,stat=,command="],
        check=True, capture_output=True, text=True,
    )
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 5)
        if len(parts) == 6 and not parts[4].startswith("Z"):
            pid, parent, group, uid = map(int, parts[:4])
            rows[pid] = (parent, group, uid, parts[5])
    return rows


def dedicated(pid, rows):
    """Only a group led by this wrapper, with all members descending from it."""
    parent, group, uid, command = rows[pid]
    if group != pid or uid != os.getuid() or not WRAPPER.fullmatch(command):
        return False
    for member, (_, member_group, member_uid, _) in rows.items():
        if member_group != group:
            continue
        if member_uid != uid:
            return False
        ancestor, seen = member, set()
        while ancestor != pid:
            if ancestor in seen or ancestor not in rows:
                return False
            seen.add(ancestor)
            ancestor = rows[ancestor][0]
    return True


def inside(pid, path):
    result = subprocess.run(
        ["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
        capture_output=True, text=True,
    )
    return result.returncode == 0 and any(
        line.startswith("n") and (
            os.path.realpath(line[1:]) == path
            or os.path.realpath(line[1:]).startswith(path + os.sep)
        ) for line in result.stdout.splitlines()
    )


def other_occupants(path, rows):
    """Use Spork's watched process names, excluding verified tunnel groups."""
    groups = {pid for pid in rows if dedicated(pid, rows)}
    for command in os.environ.get("SPORK_LIVE_COMMANDS", "claude codex zsh bash fish").split():
        result = subprocess.run(
            ["pgrep", "-x", "-u", str(os.getuid()), command],
            capture_output=True, text=True,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError("Cannot inspect live occupants")
        for value in result.stdout.split():
            pid = int(value)
            if pid in rows and rows[pid][1] in groups:
                continue
            cwd = subprocess.run(
                ["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
                capture_output=True, text=True,
            )
            names = [os.path.realpath(line[1:]) for line in cwd.stdout.splitlines()
                     if line.startswith("n")]
            if cwd.returncode != 0 or not names:
                # A disappearing process is fine; an unreadable live one isn't.
                if pid in snapshot():
                    raise RuntimeError("Cannot inspect an occupant's working directory")
                continue
            if any(name == path or name.startswith(path + os.sep) for name in names):
                return True
    return False


def close(path, only_occupant=False):
    path = os.path.realpath(path)
    closed = []
    for pid, row in snapshot().items():
        if not WRAPPER.fullmatch(row[3]) or not inside(pid, path):
            continue
        current = snapshot()
        if current.get(pid) != row or not dedicated(pid, current):
            continue
        if only_occupant and other_occupants(path, current):
            return
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        print(f"Closing tunnel terminal (PID {pid})", flush=True)
        closed.append(pid)
    if closed:
        for _ in range(30):
            if not any(row[1] in closed for row in snapshot().values()):
                return
            time.sleep(0.1)
        raise RuntimeError("Tunnel processes are still exiting; retry clean shortly.")


if __name__ == "__main__":
    try:
        close(sys.argv[1], only_occupant="--only-occupant" in sys.argv[2:])
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        sys.exit(f"Cannot safely close tunnels: {error}")
