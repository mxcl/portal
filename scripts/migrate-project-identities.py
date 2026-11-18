#!/usr/bin/env python3
"""Apply a reviewed shared name→UUID manifest to a stopped host's project root.

The backup-index owner applies the same manifest to bare backups on startup.
This script never edits refs, working files, or replication state.
"""
import argparse
import json
import pathlib
import subprocess
import uuid


def apply(root, support, manifest):
    identities = json.loads(manifest.read_text())
    for name, identity in identities.items():
        if not name or name in (".", "..") or "/" in name or "\x00" in name:
            raise ValueError(f"Invalid project name: {name!r}")
        if str(uuid.UUID(identity)) != identity:
            raise ValueError(f"Invalid canonical UUID: {identity}")
    assignments = []
    common_identities = {}
    for repository in sorted(root.iterdir()):
        if repository.name.startswith(".") or repository.is_symlink() or not repository.is_dir():
            continue
        def git(*args):
            return subprocess.run(["git", "-C", str(repository), *args], capture_output=True, text=True)
        if git("rev-parse", "--git-dir").returncode:
            continue
        identity = identities[repository.name]  # Refuse projects absent from the reviewed inventory.
        common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
        if common.returncode:
            raise RuntimeError(common.stderr)
        previous = common_identities.setdefault(common.stdout.strip(), identity)
        if previous != identity:
            raise ValueError(f"Worktrees have conflicting manifest identities: {repository}")
        current = git("config", "--local", "--get", "portal.projectID")
        if current.returncode not in (0, 1) or current.stderr:
            raise RuntimeError(current.stderr)
        if current.stdout.strip() not in ("", identity):
            raise ValueError(f"Conflicting identity: {repository}")
        assignments.append((repository, identity))
    support.mkdir(parents=True, exist_ok=True)
    destination = support / "project-identities-v1.json"
    encoded = json.dumps(identities, indent=2, sort_keys=True) + "\n"
    if destination.exists() and json.loads(destination.read_text()) != identities:
        raise ValueError(f"Conflicting migration manifest: {destination}")
    temporary = destination.with_suffix(".pending")
    temporary.write_text(encoded)
    temporary.chmod(0o600)
    temporary.replace(destination)
    for repository, identity in assignments:
        subprocess.run(["git", "-C", str(repository), "config", "--local", "portal.projectID", identity], check=True)
    print(f"Assigned and verified {len(assignments)} projects; startup manifest contains {len(identities)} identities.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--support", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    args = parser.parse_args()
    apply(args.root, args.support, args.manifest)
