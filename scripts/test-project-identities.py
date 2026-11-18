#!/usr/bin/env python3
"""Exercise the stopped-host migration without touching real repositories."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import uuid

spec = importlib.util.spec_from_file_location("migration", pathlib.Path(__file__).with_name("migrate-project-identities.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
with tempfile.TemporaryDirectory() as directory:
    base = pathlib.Path(directory)
    root, support = base / "projects", base / "support"
    root.mkdir()
    repository = root / "experiment"
    subprocess.run(["git", "init", "-q", str(repository)], check=True)
    identity = str(uuid.uuid4())
    manifest = base / "manifest.json"
    manifest.write_text(json.dumps({"experiment": identity}))
    migration.apply(root, support, manifest)
    migration.apply(root, support, manifest)
    assert subprocess.check_output(["git", "-C", str(repository), "config", "--local", "portal.projectID"], text=True).strip() == identity
    assert json.loads((support / "project-identities-v1.json").read_text()) == {"experiment": identity}
    manifest.write_text(json.dumps({"experiment": str(uuid.uuid4())}))
    try:
        migration.apply(root, support, manifest)
    except ValueError:
        pass
    else:
        raise AssertionError("Conflicting UUID was accepted")
    assert subprocess.check_output(["git", "-C", str(repository), "config", "--local", "portal.projectID"], text=True).strip() == identity
    subprocess.run(["git", "-C", str(repository), "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "--allow-empty", "-m", "initial"], check=True)
    subprocess.run(["git", "-C", str(repository), "worktree", "add", "-q", str(root / "alias")], check=True)
    manifest.write_text(json.dumps({"experiment": identity, "alias": str(uuid.uuid4())}))
    try:
        migration.apply(root, support, manifest)
    except ValueError:
        pass
    else:
        raise AssertionError("Conflicting worktree UUIDs were accepted")
print("PASS: repeatable migration preserves existing identity and rejects conflicting manifests")
