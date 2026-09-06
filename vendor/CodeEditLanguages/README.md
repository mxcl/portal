# CodeEditLanguages

Vendored from [CodeEditLanguages 0.1.20](https://github.com/CodeEditApp/CodeEditLanguages/tree/0.1.20),
commit `331d5dbc5fc8513be5848fce8a2a312908f36a11`.

Local changes: locate installed resource bundles in Contents/Resources and resolve
query paths from the bundle root. The manifest fetches the unchanged grammar binary
from the pinned commit with a SHA-256 checksum, avoiding the repository's large
history of binary archives. Upstream tests are not included.
