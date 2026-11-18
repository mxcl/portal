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
    assert (repository / ".git/portal-project-id").read_text().strip() == identity
    assert json.loads((support / "project-identities-v1.json").read_text()) == {"experiment": identity}
    manifest.write_text(json.dumps({"experiment": str(uuid.uuid4())}))
    try:
        migration.apply(root, support, manifest)
    except ValueError:
        pass
    else:
        raise AssertionError("Conflicting UUID was accepted")
    assert (repository / ".git/portal-project-id").read_text().strip() == identity
    subprocess.run(["git", "-C", str(repository), "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "--allow-empty", "-m", "initial"], check=True)
    subprocess.run(["git", "-C", str(repository), "worktree", "add", "-q", str(root / "alias")], check=True)
    alias_id = str(uuid.uuid4())
    manifest.write_text(json.dumps({"experiment": identity, "alias": alias_id}))
    # A second stopped host can assign distinct IDs to worktrees sharing the object database.
    migration.apply(root, base / "second-support", manifest)
    alias_git = pathlib.Path(subprocess.check_output(["git", "-C", str(root / "alias"), "rev-parse", "--path-format=absolute", "--git-dir"], text=True).strip())
    assert (alias_git / "portal-project-id").read_text().strip() == alias_id
    assert (repository / ".git/portal-project-id").read_text().strip() == identity
print("PASS: repeatable migration, conflict rejection and independent linked-worktree identities")
