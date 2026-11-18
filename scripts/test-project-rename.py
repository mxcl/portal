#!/usr/bin/env python3
"""Exercise the deployed rename CLI and its version gate on disposable repositories."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

executable = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/portald').resolve())
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    subprocess.run(['git', 'init', '-q', str(root / 'before')], check=True)
    project_id = str(uuid.uuid4())
    (root / 'before/.git/portal-project-id').write_text(project_id + '\n')
    (root / 'before/dirty').write_text('uncommitted work')
    record = dict(id=str(uuid.uuid4()), old='before', new='after', projectID=project_id,
                  previousRenames=[], moved=False, complete=False)
    payload = base64.b64encode(json.dumps(record).encode()).decode()

    def request(step, version='3'):
        return subprocess.run([executable, 'rename-project', '--root', str(root),
                               '--rename-version', version, '--step', step, '--record', payload],
                              capture_output=True, text=True)

    rejected = request('preflight', '2')
    assert rejected.returncode != 0 and 'Unsupported rename request' in rejected.stderr, rejected
    assert not (root / '.portal-renames.json').exists()
    for step in ['preflight', 'prepare', 'move', 'finish']:
        result = request(step)
        assert result.returncode == 0, (step, result.stderr)
        if step == 'preflight':
            assert not (root / '.portal-renames.json').exists()
    assert not (root / 'before').exists()
    assert (root / 'after/dirty').read_text() == 'uncommitted work'
    assert (root / 'after/.git/portal-project-id').read_text().strip() == project_id
    assert json.loads((root / '.portal-renames.json').read_text())[0]['complete']
print('Rename CLI version gate, UUID preservation, and dirty-work checks passed.')
