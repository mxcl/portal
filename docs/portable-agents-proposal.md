# Branch and commit-specific agents

Status: proposal. Written November 1, 2026; revised November 2, 2026. This document describes intended
behavior, not functionality Portal currently implements.

## Purpose

Make agent work specific to branches and commits. Each branch owns a conversation;
commits anchor checkpoints in that conversation. Select an earlier commit, choose
**Branch with agent**, and explore another approach with the code and context
available at that point. Show agents directly in Hub's Git tree.

Remote execution belongs in the first release. A project may live on another
machine, and its agent runs there. Open Hub on any connected client to inspect,
steer, approve, and review that work. Closing a client detaches the UI; the host
keeps executing. If the execution host becomes unavailable, the agent waits.

Cross-device runner transfer comes later. Version one binds each agent to an
execution host and workspace, with durable state for reconnection and recovery
on that host. It does not elect replacement hosts or migrate running work.

| First release | Preserve in the design | Later phases |
| --- | --- | --- |
| Branch agents, commit checkpoints, contextual forks, local and remote execution, reconnectable UI | Stable identities, explicit workspace binding, durable operation IDs, versioned journals | Runner transfer, workspace migration, rich project sandbox policies, per-CLI Vault adapters, skill package distribution |

Start with a basic, explicit execution permission boundary and recorded instruction
versions. The fuller project sandbox, Automic Vault controls, and versioned skill
packages below remain intended directions, not prerequisites for the first release.
Do not build distributed ownership infrastructure merely to prepare for migration.

The initial tool interface is CLI execution. MCP integration, a plugin marketplace,
native computer use, and feature parity with ChatGPT are outside the initial scope.
Provider and harness selection remain open. Evaluate existing runtimes against
commit checkpoints, contextual forks, and remote execution before choosing to own
the model loop; future mobility alone does not justify rebuilding a harness.

## Terms and ownership

| Term | Meaning |
| --- | --- |
| Project | A stable identity connecting a user's work, approved policy, and known workspace locations. A folder name alone is insufficient. |
| Agent | A branch's durable conversation and ongoing work, including its instructions, checkpoints, pending operations, and pinned dependencies. |
| Conversation checkpoint | An immutable boundary in an agent journal, associated with a commit and sufficient to construct context for a new branch. |
| Runner | The replaceable process that advances an agent by requesting model output and scheduling operations. |
| Executor | A host service that enforces policy, executes operations, and retains their status and results independently of the runner. |
| Workspace | A particular checkout or worktree on a particular host, including its uncommitted state. |
| Operation | A durably identified request to perform work, with an authorization decision and recorded outcome. |
| Grant | User-authorized access under a specific project policy. Repository content and model output cannot create grants. |
| Skill package | Versioned instructions and supporting resources with declared dependencies and required capabilities. |

In the first release, each agent has one execution host and one writer for its
journal. That host owns its runner and execution service. Multiple clients submit
input through this authority; reconnecting a UI never starts a second runner.
Keep journal storage outside agent-writable project files. Reject incompatible
wire and journal versions and include a source epoch in persistent ordering state.

Portal's persistent terminal sessions provide a precedent for separating execution
from UI lifetime. Agent execution also needs structured operations, durable
receipts, and authorization beyond terminal output replay.

## Commit-linked conversation history

Store conversation history in a durable, versioned journal and associate commit
IDs with immutable checkpoint IDs. Do not put private chat content into Git commit
messages or implicitly publish it when pushing code. Commit associations live in
Portal metadata; their backup, retention, and sharing need explicit rules.

A checkpoint records the conversation prefix, relevant instructions and their
versions, context summaries, complete tool-call/result pairs, and artifact
references needed to understand the work. Provider continuation data may supplement
it, but must not be the only representation of branchable context. A summary made
later must not leak later decisions into a fork from an earlier checkpoint.

Record the checkpoint associated with an agent-created commit before advancing
past that boundary. Discussion after the commit stays in the live branch journal
until another checkpoint captures it. A commit may have several contextual
associations from different agents; retain provenance rather than assuming a
commit hash identifies one universal conversation. External commits may have no
checkpoint. Show that absence and offer a fresh agent or explicitly selected
available context, rather than inventing history.

**Branch with agent** is an explicit user action:

1. Select a commit and its associated conversation checkpoint.
2. Create a new branch and isolated workspace from that exact commit on the chosen
   execution host, using ordinary Git operations. Refuse to overwrite existing work.
3. Create a new agent identity whose context refers to that immutable journal prefix.
4. Apply current permissions and validate instruction/tool availability. Historical
   approvals, credentials, pending operations, and ownership do not transfer.
5. Append the new request to an independent journal and begin the alternative work.

Fork only at a complete context boundary. In-flight operations and uncommitted
files are not part of a commit checkpoint; do not copy or replay them. If historical
instructions are unavailable or revoked, show the required substitution before
execution instead of claiming exact reproduction.

Keep links between source and derived conversations so users can compare code and
reasoning. Merging code retains both histories and supplies the receiving agent
with an attributed merge summary and source links; it does not concatenate journals
or retroactively change existing checkpoints. Rebase, amend, and cherry-pick create
new commit identities. Preserve old associations and record verified new links
without silently treating rewritten commits as identical checkpoints.

## Durable execution and reconnection

Persist messages, complete model outputs, context summaries, operation IDs and
results, approvals, instruction versions, workspace bindings, and task status.
Store secrets separately. Redact sensitive output before it enters history, while
recognizing that redaction alone cannot guarantee containment. Conversation and
artifact storage needs authentication, access controls, retention, and deletion.

A normal step is:

1. Load the latest durable state under the host's single-writer ownership.
2. Record the intended model request, then issue it.
3. Persist its complete response before dispatching any resulting operation.
4. Record the operation ID, workspace, preconditions, and authorization.
5. Durably accept the operation before execution; retain its outcome and output.
6. Advance the journal and record commit associations when applicable.

On client disconnect, the host continues under existing authorization. On host
failure, clients show unavailable status and wait for that host to return.
Recovery reconciles accepted operations before issuing new work. Recover an
in-flight model response where supported; otherwise retry from a complete
checkpoint and accept possible duplicate inference cost. Partial streamed output
is provisional and must not trigger execution. Durable context is useful now for
forking and recovery; distributed ownership is not required for either.

### Outcomes and retries

Executors retain receipts keyed by operation ID. Repeated delivery returns the
existing status instead of launching a second process. Receipts include the
execution host, workspace, authorization revision, start state, exit status, and
bounded output or artifact references.

There is still a crash window between an external side effect and its receipt.
Use service idempotency keys where available and inspect external state when an
outcome is uncertain. An unknown result is a first-class state, not a failure
that Portal retries without investigation. Arbitrary CLIs cannot offer universal
exactly-once execution.

For example, a deployment may succeed just before the executor loses power. The
next runner checks the deployment service using the recorded operation identity;
if it cannot establish the outcome, it pauses that dependent work for review.

## Workspaces and Git

Runner portability does not imply workspace equivalence. Matching Git commits do
not establish matching untracked files, staged changes, toolchains, or processes.
Each mutating operation names its workspace and expected state. Serialize
conflicting agent operations within a workspace and detect external changes;
an agent lock cannot prevent a user or ordinary Git command from editing it.

Initially, keep both execution-host and workspace bindings fixed. If the host goes
offline, show the agent as waiting; do not start it elsewhere. Other branch agents
on available hosts may continue. Moving an existing workspace later requires an
explicit validated transfer of files and metadata. Creating a fresh branch and
workspace from a commit checkpoint is a separate user action, not failover.

The existing Git replication contract remains unchanged: per-ref atomicity and
eventual consistency, independent local branches, tags, stash, HEAD, index, and
working tree. Agent state uses a separate protocol and storage boundary. Background
replication must not promote incoming refs, merge, reset, rebase, or check out
agent work. Agent changes occur through authorized operations in a named workspace.
Use Git plumbing for object validation and ref transactions; do not interpose on
ordinary Git commands to coordinate agents.

## Later: project sandboxes

A project declares its requested environment in version-controlled configuration.
The user authorizes a resolved policy outside the agent-writable workspace.
Repository edits can propose policy changes but cannot activate them.

The policy describes:

- Readable and writable filesystem locations, including scratch and artifact areas.
- Executables and versions, subprocess behavior, and permitted environment variables.
- Network destinations and access to local services, sockets, and host facilities.
- Operation-specific capabilities, approval requirements, and credential references.
- Resource limits and the host capabilities needed to enforce these rules.

Executors enforce restrictions outside the model. A host must support the complete
required policy before it becomes eligible. Unsupported controls leave the task
waiting; migration must not weaken isolation. Host-specific sandbox mechanisms
and their equivalence need implementation spikes on macOS and Linux.

Treat project files, dependencies, command output, and skills as untrusted inputs.
Do not inherit the user's unrestricted shell environment, home directory,
credential caches, SSH agent, or service sockets by default. An allowed executable
may load project-controlled configuration or launch other programs, so executable
allowlists alone are not a sandbox.

## Later: CLI permissions and Automic Vault

Develop an integration in which Portal requests an operation under a project
identity and Automic Vault authorizes access to the associated secret or service.
These are proposed integration requirements, not verified claims about Automic
Vault's current features. Its API, enforcement model, and required extensions
must be investigated before implementation.

Authorization binds the project, agent, operation ID, workspace, executable
identity, structured arguments, destination, requested secret, and policy revision.
A trusted executor or broker supplies this identity; an agent cannot gain access
by writing a different project ID into a command or environment variable.

Illustrative policy, not a configuration schema:

| CLI operation | Secret or authority | Restriction |
| --- | --- | --- |
| Inspect deployment status | Production read credential | Only this project's deployment service; read operations only |
| Deploy staging | Staging deployment credential | Only this project's staging target |
| Deploy production | Production deployment credential | Explicit approval bound to the artifact and target |
| Run tests | None | Project workspace and declared test dependencies |

Prefer brokered operations or short-lived credentials scoped by the service itself.
Passing a broad credential to a process gives that process access to it, even if
the model never sees it. If a CLI needs such access, contain its process tree and
network access and document the remaining trust assumption. Some tools will need
dedicated adapters to enforce resource or operation restrictions.

Do not authorize by matching shell command strings. Evaluate structured arguments,
executable identity, configuration sources, subprocesses, and destination changes.
Credential-bearing operations should use a controlled launch path. General shell
execution stays within the baseline project sandbox without ambient secrets.

On handoff, the new executor obtains authorization for its own operations; Portal
does not copy credential values through agent checkpoints. Approval does not grant
an unrestricted terminal session. Policy revocation blocks new operations and
credential issuance; stopping in-flight work and revoking issued credentials require
explicit executor and service support. Show those limits to the user.

## Later: versioned skill packages

Portal manages skills as project dependencies. A package contains instructions,
optional scripts and resources, compatibility requirements, tool dependencies,
and requested capabilities. Use SKILL.md where practical so instruction content
can remain portable. Package format and registry choices remain open.

Project manifests express dependency intent. A lockfile records exact package
versions, content digests, sources, and resolved dependencies. Portal verifies
package integrity and publisher trust before installation; a digest alone does
not establish that a publisher is trustworthy. Installation scripts receive no
implicit privileges.

Portal can provide maintained packages and support third-party or local packages.
Updates show instruction and script changes alongside dependency and capability
changes. Users can install, update, pin, and roll back packages per project.
An update may request more authority, but only a separate authorization can grant it.

Active agents retain their resolved package set across handoff. Upgrading a running
task requires a recorded checkpoint and explicit transition. Security revocation
can make an old package ineligible even when pinned; pause affected work instead
of bypassing the revocation. Rollback restores package content, not expired grants.

Skill instructions teach an agent which CLIs to use and how to verify results.
Executors enforce permissions independently of whether the agent follows those
instructions. Missing tools, unavailable packages, and unenforceable policies
produce actionable waiting states.

## User experience

Hub is Git-tree centric. Show each branch's agent directly in the Git tree, attached
to that branch's label or tip, with its status and current activity. Selecting the
agent opens its conversation and controls in the detail pane while keeping the
tree visible. Branch history, diffs, and agent activity share the same navigation
context. A separate agent list must not become the primary way to navigate work.

Each branch has one durable agent identity, created when the user first starts
agent work on it. Further requests continue that branch's conversation; completed
tasks remain in its history. Untouched branches need no running process or empty
conversation. Child workers, if introduced, belong to the branch agent and do not
create additional top-level entries in the tree.

Show running, waiting for a host, waiting for approval, paused, completed, failed,
and awaiting reconciliation states at the branch's agent entry. Link recorded
operations and resulting commits so users can move between the conversation and
the exact changes. Activity before a commit still belongs to the branch; do not
invent commits to display it. Selecting an older commit shows historical context
without silently retargeting the agent's workspace.

Agent identity must survive a branch rename and advancing tips. Branch names and
commit IDs alone cannot identify an agent. Bind it to a stable project-scoped
branch identity with explicit host/workspace associations. Equal branch names on
different hosts do not establish shared identity, especially when tips diverge.
Show host-qualified refs and the execution workspace when needed to disambiguate.
Future runner handoff must preserve this binding and never change local refs to
make them match another host.

Creating a branch offers a new agent; carrying context from another branch is an
explicit action. Merge or deletion retains the conversation and its commit links
as archived history. Before retiring a branch agent with active operations, stop
new dispatches and reconcile outstanding work. Reusing a deleted branch name must
not silently revive its former agent or permissions. Exact identity storage and
external rename/deletion reconciliation remain open design decisions.

Users can inspect the current runner and operation hosts from the branch agent
without selecting a host for every message. Multiple clients can observe; their
input passes through the same ordered agent journal.

Expose the execution host, workspace, effective permissions, instruction versions,
and operation audit trail. As later policy and package features arrive, expose
their grants, revisions, installed skills, and pending updates here too. Approval
UI names the project, operation, target, artifact where applicable, and requested
access. Closing Hub
detaches its UI. Pausing prevents new work; cancellation also requests termination
of active operations and reports any uncertain or irreversible effects.

## Delivery and acceptance

1. **Prove branch-specific work, including remote execution.** Run one branch agent
   on a configured local or remote host. Render it in the Git tree, retain its
   journal and operation receipts, enforce a basic permission boundary, and reconnect
   the UI without restarting work. The execution host remains fixed.
2. **Prove commit-specific forks.** Record conversation checkpoints with commits.
   Branch from an earlier commit, inherit only its recorded context, and explore an
   alternative. Compare the code and reasoning while preserving the original agent.
3. **Complete the first-release lifecycle.** Handle external commits, rename,
   merge/archive, rewritten history, same-host recovery, and uncertain operations.
   Evaluate whether contextual forks are useful before expanding infrastructure.
4. **Add project controls and skill packages.** Develop sandbox policy, investigate
   Automic Vault, prove one per-CLI credential workflow, and introduce verified,
   pinned skill updates. These can ship independently of runner transfer.
5. **Add cross-device transfer when justified.** Establish checkpoint replication,
   exclusive ownership across hosts, fencing, and recovery before offering takeover.
   Treat workspace migration as a further capability with its own validation.

The first demonstration uses a project on a remote host: ask its branch agent to
make a change and commit, continue the discussion, then select the earlier commit
and choose **Branch with agent** to try another approach. Verify the new agent
receives the earlier context and matching code, with no later discussion or pending
actions. Close and reopen the client while remote work continues. Disconnect the
execution host and verify an honest waiting state with no automatic takeover.

First-release tests cover checkpoint boundaries, missing associations, contextual
fork isolation, absence of inherited approvals or operations, merge provenance,
rewritten commits, remote reconnect, duplicate dispatches, same-host crash recovery,
concurrent workspace edits, unauthorized policy changes, and incompatible versions.
Later features add partition/fencing/reset tests, Vault revocation and containment,
and package integrity/update tests. Add the smallest regression test for every
non-trivial protocol or failure-recovery change. Preserve existing Git ownership
and replication guarantees throughout.

## Later: cross-device runner transfer

The long-term goal remains an agent whose runner can change hosts while its
conversation, constraints, and execution receipts remain intact. Moving a runner
does not migrate an active shell, build, or workspace.

Before implementing transfer, choose a durability and ownership authority. A small
coordinator is one candidate; a peer quorum is another. Eventual replication alone
cannot ensure exclusive ownership. A local unsynchronized checkpoint cannot prove
that another host can recover it.

Planned handoff publishes a durable checkpoint and releases ownership before the
successor advances. Abrupt takeover must reconcile outstanding operations. Use
source epochs and increasing fencing numbers, with executors rejecting stale
owners and refusing new mutations when they cannot verify authority. Already
accepted work may continue; lease expiry does not undo external effects. A new
runner must not schedule conflicting work until it establishes the outcome.

Authority resets, network partitions, credential reauthorization, pinned instruction
availability, and policy equivalence need explicit recovery contracts. Retain these
requirements as design constraints; do not implement a coordinator or election
protocol as part of the branch-and-commit experiment.

## Open decisions

- Journal/checkpoint storage, commit association format, privacy and backup rules,
  and how to construct historical context after compaction.
- Later: transfer authority and checkpoint replication, including recovery without
  losing ownership history.
- Whether an existing harness supports commit-linked checkpoints and independent
  contextual forks, or Portal must own more of the model loop. A fixed-host runtime
  is acceptable for the first release.
- Provider continuation formats, authentication, billing, retention, and the exact
  recovery guarantees available for requests already in flight.
- Stable project and branch identity, reconciliation of external branch lifecycle
  changes, and enrollment of trusted hosts and approval authorities.
- Automic Vault's existing interfaces and which project/operation controls require
  extensions, plus enforcement responsibilities shared with Portal.
- Sandbox mechanisms, CLI adapter boundaries, credential containment, and revocation
  behavior on each supported host platform.
- Skill package distribution, publisher trust, licensing, update policy, and the
  boundary between Portal-maintained and project-maintained content.

The first release tests Git-centered agent interaction and remote execution.
Distributed recovery, richer sandbox enforcement, and package management each
remain substantial later projects; first-release success must not depend on them.
