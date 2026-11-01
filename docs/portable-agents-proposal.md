# Portable project agents

Status: proposal. Written November 1, 2026. This document describes intended
behavior, not functionality Portal currently implements.

## Purpose

Give a project an ongoing task and continue that work from any of your computers.
Start a migration on a MacBook, close its lid, and let another available host
advance the same conversation. Open Portal Hub elsewhere to inspect progress,
steer the agent, approve an operation, or review its changes. Each branch has its
own agent, shown directly in Hub's Git tree alongside the work it produces.

The project also defines the environment in which agents work: its sandbox,
available CLIs, credential permissions, and versioned skills. Moving responsibility
between hosts preserves those constraints.

This proposal combines four features:

- Durable agents whose runners can change hosts.
- Project sandboxes with explicit filesystem, process, and network access.
- Per-CLI, per-operation secret controls, developed with Automic Vault.
- Versioned skill packages that projects install, pin, update, and roll back.

The initial tool interface is CLI execution. MCP integration, a plugin marketplace,
native computer use, and feature parity with ChatGPT are outside the initial scope.
No specific model provider or API is required by this design. Provider adapters
must establish their continuation and recovery behavior before we depend on it.

## Terms and ownership

| Term | Meaning |
| --- | --- |
| Project | A stable identity connecting a user's work, approved policy, and known workspace locations. A folder name alone is insufficient. |
| Agent | A branch's durable conversation and ongoing work, including its instructions, checkpoints, pending operations, and pinned dependencies. |
| Runner | The replaceable process that advances an agent by requesting model output and scheduling operations. |
| Executor | A host service that enforces policy, executes operations, and retains their status and results independently of the runner. |
| Workspace | A particular checkout or worktree on a particular host, including its uncommitted state. |
| Operation | A durably identified request to perform work, with an authorization decision and recorded outcome. |
| Grant | User-authorized access under a specific project policy. Repository content and model output cannot create grants. |
| Skill package | Versioned instructions and supporting resources with declared dependencies and required capabilities. |

The agent has no permanent execution host. At any moment, one runner owns the
right to advance it. Executors may carry out independent operations on several
hosts. A running build, shell, or browser session stays on its execution host;
moving the runner does not migrate those processes.

Portal's existing persistent terminal sessions provide a precedent for separating
execution from UI lifetime. Agent execution needs structured operations, durable
receipts, and authorization beyond terminal output replay.

## Portable state and handoff

Persist the information needed to continue an agent without the previous runner:

- User messages, instructions, model outputs, and provider continuation data.
- Context summaries and compaction records, preserving required tool-call pairing.
- Pending and completed operations, their IDs, and result or artifact references.
- Approvals, policy revisions, skill and tool versions, and workspace bindings.
- Ownership epochs, journal positions, and task status.

Store secrets separately. Redact sensitive output before it enters conversation
history, while recognizing that redaction alone cannot guarantee secret containment.
Conversation and artifact storage still needs authentication, access controls,
retention rules, and deletion semantics.

A normal step is:

1. Claim ownership and load the latest committed checkpoint.
2. Record the intended model request, then issue it.
3. Persist its complete response before dispatching any resulting operation.
4. Record an operation's identity, target, preconditions, and authorization.
5. Dispatch it to an executor, which durably accepts it before execution.
6. Persist its outcome and advance the conversation.

During a planned handoff, the runner finishes or checkpoints its current step,
publishes that checkpoint, and releases ownership. Its successor verifies the
checkpoint and outstanding operations before advancing. A checkpoint is committed
only once the chosen durability authority acknowledges it; a local unsynchronized
file does not establish that another host can recover it.

During abrupt host loss, recover from the last committed checkpoint. Recover an
in-flight model response if the provider supports that operation; otherwise retry
from a complete checkpoint and accept possible duplicate inference cost. Partial
streamed output is provisional and must not trigger execution.

### One owner, including during partitions

The first prototype should use a small authoritative coordinator for ownership
and durable checkpoints. Its storage and deployment location remain open decisions.
This gives runners mobility but makes the coordinator an availability dependency.
A peer quorum could remove the single-host dependency later; eventual replication
alone cannot provide exclusive ownership.

Use an ownership epoch and increasing fencing number. Executors reject stale
dispatches against the authority, rather than trusting a runner's assertion that
its lease remains valid. If they cannot verify authority, they accept no new
mutating operation. Old runners cannot publish new checkpoints after losing ownership.

Already accepted work can continue under its recorded authorization. A successor
must reconcile it before scheduling conflicting work. Lease expiry does not undo
an external side effect or stop a process already running on a disconnected host.

Keep one writer per persistent store. Reject incompatible wire and checkpoint
versions. An authority reset must establish a new epoch and reconcile outstanding
operations before execution resumes.

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

Initially, keep workspace bindings fixed while allowing runners to move. If the
workspace host goes offline, continue independent work elsewhere and show the
blocked dependency. Moving workspace execution later requires an explicit transfer
of the task's files and metadata with validation, or a user-authorized new worktree.

The existing Git replication contract remains unchanged: per-ref atomicity and
eventual consistency, independent local branches, tags, stash, HEAD, index, and
working tree. Agent state uses a separate protocol and storage boundary. Background
replication must not promote incoming refs, merge, reset, rebase, or check out
agent work. Agent changes occur through authorized operations in a named workspace.
Use Git plumbing for object validation and ref transactions; do not interpose on
ordinary Git commands to coordinate agents.

## Project sandboxes

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

## CLI permissions and Automic Vault

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

## Versioned skill packages

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
Runner handoff preserves this binding and never changes local refs to make them
match another host.

Creating a branch offers a new agent; carrying context from another branch is an
explicit action. Merge or deletion retains the conversation and its commit links
as archived history. Before retiring a branch agent with active operations, stop
new dispatches and reconcile outstanding work. Reusing a deleted branch name must
not silently revive its former agent or permissions. Exact identity storage and
external rename/deletion reconciliation remain open design decisions.

Users can inspect the current runner and operation hosts from the branch agent
without selecting a host for every message. Multiple clients can observe; their
input passes through the same ordered agent journal.

Expose the effective sandbox and grants, their source revisions, installed skills,
pending updates, and an operation audit trail. Approval UI names the project,
operation, target, artifact where applicable, and requested access. Closing Hub
detaches its UI. Pausing prevents new work; cancellation also requests termination
of active operations and reports any uncertain or irreversible effects.

## Delivery and acceptance

1. **Prove continuity.** Two hosts, a single coordinator, a durable journal, one
   provider adapter, and a small CLI executor. Hand off between recorded steps,
   then kill a runner during execution and recover without duplicate dispatch.
2. **Enforce one project sandbox.** Bind a workspace, isolate execution, and reject
   hosts that cannot enforce the policy. Prove repository edits cannot grant access.
3. **Integrate one credential-backed CLI.** Investigate Automic Vault and implement
   staging versus production permissions. Exercise approval, revocation, and an
   uncertain external outcome. Keep unsupported enforcement paths disabled.
4. **Ship skill dependencies.** Install and verify packages, lock versions, review
   updates, and preserve the selected package set through handoff and rollback.
5. **Broaden recovery and host support.** Resolve coordinator availability, workspace
   transfer, and additional adapters based on the first workflows.

The first demonstration should start a task on a MacBook, transfer runner ownership
to another host, close the MacBook, and continue the same conversation with the same
policy and skills. Its required workspace must remain reachable. A separate test
should remove that workspace host and verify an honest waiting state.

Before shipping, cover stale owners, partitions, authority resets, duplicate
dispatches, executor crashes around side effects, revoked grants, changed command
configuration, concurrent workspace edits, tampered packages, unavailable pinned
versions, and incompatible protocol versions. Add the smallest regression test
for every non-trivial protocol or failure-recovery change. Verify existing Git
ownership and replication guarantees remain intact.

## Open decisions

- Where the first coordinator and checkpoint store run, and how they recover or
  migrate without losing ownership history.
- Whether an existing harness exposes sufficient portable state, or Portal should
  own the model loop. Avoiding a permanent app-server host does not by itself
  justify rebuilding compaction, steering, and tool orchestration.
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

The cost of this direction includes an agent runtime, distributed recovery,
sandbox enforcement, and package management. Keeping CLI execution as the first
tool interface limits integration scope; it does not eliminate those responsibilities.
