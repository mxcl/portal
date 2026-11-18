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
    git_identities = {}
    for repository in sorted(root.iterdir()):
        if repository.name.startswith(".") or repository.is_symlink() or not repository.is_dir():
            continue
        def git(*args):
            return subprocess.run(["git", "-C", str(repository), *args], capture_output=True, text=True)
        if git("rev-parse", "--git-dir").returncode:
            continue
        identity = identities[repository.name]  # Refuse projects absent from the reviewed inventory.
        git_directory = git("rev-parse", "--path-format=absolute", "--git-dir")
        if git_directory.returncode:
            raise RuntimeError(git_directory.stderr)
        identity_path = pathlib.Path(git_directory.stdout.strip()) / "portal-project-id"
        previous = git_identities.setdefault(identity_path, identity)
        if previous != identity:
            raise ValueError(f"Duplicate Git directory has conflicting identities: {repository}")
        if identity_path.exists() and identity_path.read_text().strip() != identity:
            raise ValueError(f"Conflicting identity: {repository}")
        assignments.append((identity_path, identity))
    support.mkdir(parents=True, exist_ok=True)
    destination = support / "project-identities-v1.json"
    encoded = json.dumps(identities, indent=2, sort_keys=True) + "\n"
    if destination.exists() and json.loads(destination.read_text()) != identities:
        raise ValueError(f"Conflicting migration manifest: {destination}")
    temporary = destination.with_suffix(".pending")
    temporary.write_text(encoded)
    temporary.chmod(0o600)
    temporary.replace(destination)
    for identity_path, identity in assignments:
        if identity_path.exists():
            continue
        temporary = identity_path.with_suffix(".pending")
        temporary.write_text(identity + "\n")
        temporary.replace(identity_path)
    print(f"Assigned and verified {len(assignments)} projects; startup manifest contains {len(identities)} identities.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--support", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    args = parser.parse_args()
    apply(args.root, args.support, args.manifest)
