# App UX contract

## Shell and navigation

- Portal is a conventional foreground app with one reusable project window
  and an embedded menu-bar helper that continues syncing after the app closes.
- The helper menu owns global status, Pause/Resume, recent events, Settings,
  opening the project window, and quitting both processes.
- The window uses sidebar, content, and detail columns. Detail hides before the
  sidebar as the window narrows. Selection is restored when possible.
- Projects sort alphabetically and are searchable. Active and archived projects
  are separate sidebar sections.
- Archiving refreshes the backup inventory before completing. Once all hosts
  confirm absence, the selected project moves to Archived without resetting its
  selected commit, graph, README, or diff. Reading from its backup preserves the
  existing content during the source transition and uses the same overview layout.

## Command palette

- Command-P opens Command Palette in the project window; Command-Shift-P retains
  Pause/Resume Sync. The palette owns focus until dismissal, then restores it.
- One field fuzzy-matches project, branch, and tag names (case-insensitive exact,
  prefix, substring, then subsequence). Empty input lists projects alphabetically.
  Four or more hexadecimal characters also search commit SHA prefixes, including
  commits outside the graph's loaded history. Ambiguous prefixes list every match.
- Up/Down select, Return opens, Escape or clicking outside dismisses. Clear resets
  the query and focuses the field. Native system styling and accessible result
  labels match the project browser; project/source subtitles distinguish results.
- Search covers known local repositories, configured host copies, and backup
  snapshots, including archives. Names appear immediately; Git reads debounce for
  300 ms and use at most four concurrent blocking operations across searches.
  Superseded replies cannot replace newer results. Partial failures retain useful
  results, identify unavailable sources, and offer Retry.
- Identical project/ref/commit matches collapse, preferring this Mac, then hosts
  in configuration order, then backups. Divergent tips remain separate results.
- Project results open Info. Ref and SHA results open commit metadata and Diff,
  guarding unsaved edits with the existing editor confirmation. An out-of-history
  commit has separate detail state, without adding a disconnected graph row.
- Local presentation remains preferred when its object exists locally. Explicit
  palette activation may use the matching host or backup when it does not; this
  source choice never promotes refs or changes HEAD, the index, or working files.
- Search protocol v1 is independent of replication and backup control versions.
  Daemon searches require `--search-version 1`; backup search requests carry
  `searchVersion: 1`. Responses carry a checked version. Older hosts report search
  unavailable without interrupting replication or existing browsing operations.

## Project and host state

- Same-named repositories form one project. Adding a host warns before pairing
  names present on both hosts; unrelated repositories must be renamed first.
- Every configured host reports one project state: `notPresent`, `mirrored`, or
  `checkedOut`. Mirrored and checked-out projects always participate in sync.
- State changes apply immediately to the affected host. Offline hosts cannot be
  mutated and are never inferred to be absent.
- Creating a checkout uses published default-branch metadata, then `main`, then
  `master`, and otherwise asks the user to choose a branch.
- Archive is offered only when a backup destination is configured. It requires
  confirmation, moves the selected host's clean checkout to recoverable Trash,
  and leaves the backup available to restore. Permanent deletion is never a fallback.
- Remote commands accept validated project names beneath a configured root only.
  The target host rechecks every safety condition.

## Backup and archive

- One optional system-wide backup destination protects every project and is
  propagated to configured hosts.
- `archived` remains derived after the Archive action: every host has confirmed
  `notPresent` and the backup destination holds the sole repository.
- Removing the final host copy requires an acknowledged backup of its current
  refs. Missing or stale host state cannot produce an archived project.
- Assigning an archived project to a host restores it. Divergent stored snapshots
  require an explicit source choice.
- A remote-only or remotely archived project can render its graph, README, and
  commit diffs from a live host or individual backup snapshot without being brought
  to this Mac. Live hosts precede backups, and a source picker appears when needed.

## Git presentation

- The graph is a conventional vertical commit log with lanes. It shows local
  branches, peer branches, and tags; stashes and expired recovery refs stay hidden.
- Peer ref labels in the graph and commit detail use lowercase configured host names;
  stored ref names and protocol identities remain unchanged.
- Normal branch divergence is information, never a warning.
- Each available host checkout has its own selectable Staging graph row, labeled
  with the host name and placed immediately above that host's HEAD (or first when
  HEAD has no visible commit). Each row links to its own HEAD by a dashed line and
  shows staged, unstaged, untracked, and conflicted file counts, or “Clean” when empty.
  Changed relative paths fill the secondary line as space allows, with green `+X`
  and red `−Y` line counts per file. Counts sum staged and unstaged edits; binary
  files or unavailable counts show paths alone. The tooltip includes the full list.
  A partially staged file counts in both staged and unstaged totals. Local filesystem
  refresh updates the row and selected diff; clean repositories keep the row and selection.
  Selecting the local row opens the editor and file browser together in the right
  detail pane while the lanes remain visible. Command-Shift-S cycles through available
  Staging rows and wraps; Command-S remains Save. The staging toolbar offers Editor
  and Terminal locally, or Diff and Terminal remotely. Other view and external-app
  actions remain in menus. Host placement/status controls appear in the toolbar.
  README/Info is shown only for archived projects. There is no manual Refresh control.
  Peer staging refreshes on project load and every 30 seconds while history
  is visible. Failed reads remove stale peer staging and show a retry message with
  the connection error in its tooltip. Diff retains
  Staged and Unstaged choices, including untracked files. Mirrors and backups omit
  Staging. Reading diffs never changes the index or checkout.
- Commit detail contains message, author, date, object ID, parents, pointing refs,
  and a diff. The file browser belongs to Staging; there are no graph filters or activity pane.
- Archived project README views use Textual for Markdown headings, blockquotes, lists, code
  blocks, and tables, preserve text selection, and label the source ref.
- A local repository is the default presentation source when present. Explicit
  palette navigation may select another source for an object missing locally;
  source selection and reads never change refs, the index, `HEAD`, or a working tree.
- A failed backup inventory refresh retains the last successful list and reports
  the connection error. Cached inventory cannot authorize removal of a last host
  copy while that error remains.

## Settings and lifecycle

- First run chooses the projects root and machine identity. Both are read-only
  afterward. Existing configuration is preserved separately but not migrated.
- Settings contains General, Hosts, and Backup. The folder matrix is removed.
- Checkout fast-forwarding remains one global, opt-in setting.
- Sync runs automatically when configured. Pause/Resume is independent of Launch
  at Login.
- Opening the app starts the helper for the current session. Launch at Login
  controls future logins; turning it off does not stop the current session.
- If the helper is unavailable, the app stays open with Retry and does not run a
  second sync engine.
- Closing or quitting the foreground app leaves the helper running. Quitting
  from the helper stops both processes without changing the login preference.
- The backup destination is optional, but once chosen is read-only in the MVP.
- Host removal is blocked while it is the backup destination or the only active
  location of a project. It never deletes repositories, Git remotes, or refs.

## Feedback and accessibility

- Project and host failures appear on their owning row. App-wide failures appear
  in the toolbar status control and menu-bar menu.
- Pending operations keep controls stable and disable duplicate submission.
- Native keyboard navigation, sidebar/detail commands, visible focus, accessible
  labels, semantic colors, and text alternatives are required.
