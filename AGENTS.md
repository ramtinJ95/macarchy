# Macarchy agent instructions

These instructions apply to the entire repository.

## Read before working

At the start of every implementation session:

1. Read `docs/project-plan.md` for approved product scope, architecture,
   milestone order, and acceptance gates.
2. Read `docs/adr/README.md` for the ADR index and selective-reading policy.
3. Read `docs/handoff.md` for the current milestone's execution state and ADRs
   known to be relevant to the active slice.
4. Read individual files under `docs/adr/` when the handoff names them, their
   indexed milestone/topics match the work, touched code crosses their boundary,
   or a relevant ADR's supersession chain points to them. Do not load every ADR
   by default.
5. Inspect the working tree and verify handoff claims against code, tests, and
   the environment before acting.

The documents have different jobs:

- `docs/project-plan.md` is the durable source of approved product intent.
- `docs/adr/README.md` is the canonical ADR index; individual files in
  `docs/adr/` are the durable internal decision and discovery records.
- `docs/handoff.md` is the only short-term, phase-scoped memory document.
- Code, tests, and observed runtime behavior are the source of implementation
  facts; do not preserve a contradicted handoff claim as if it were true.

Do not create competing plans, ADR indexes/logs, handoff files, session diaries,
or status documents.

The entire `docs/` tree is local-only and gitignored. Never force-add the
project plan, ADR, handoff, or other internal agent documentation. These files
carry memory between sessions in this working tree; they do not travel with a
fresh clone. `AGENTS.md` and `.gitignore` remain tracked so the workflow itself
does travel with the repository.

## Project-plan discipline

- Follow milestone dependencies and gates in `docs/project-plan.md`.
- Do not silently turn a discovery into new product scope.
- If implementation evidence contradicts the plan or requires a product,
  security, permission, compatibility, or scope change, stop at the judgment
  point, explain the tradeoff, and ask for a decision.
- Update the project plan only when an approved decision changes durable product
  intent. Record implementation-level decisions in the ADR instead.
- Preserve explicit uncertainty. Do not rewrite an unresolved question as a
  settled decision.

## Internal ADR and discovery log

Use one file per decision under `docs/adr/` for durable findings that were not
already captured by the plan and that affect later implementation, including:

- an unexpected platform, framework, provider, or application constraint;
- a choice between meaningful implementation alternatives;
- a security, TCC, signing, private-API, state, or failure-semantics decision;
- a consumer integration seam or version-specific limitation other agents must
  preserve; or
- evidence that invalidates a prior implementation assumption.

Do not add ADR entries for routine progress, obvious code-local choices,
temporary debugging notes, command transcripts, or information already stated
in the project plan.

Before adding or changing an ADR, read `docs/adr/README.md` and every relevant
supersession chain. The index owns the next sequential `ADR-NNNN` identifier.
Each ADR file must include:

- status (`Accepted`, `Superseded`, or `Reversed`);
- date and milestone;
- context and evidence;
- decision;
- consequences and constraints; and
- superseding entry, when applicable.

Create new entries as `docs/adr/ADR-NNNN-short-title.md` using the index
template. In the same change, add the index row with concise milestone/topics
that make selective discovery practical and advance the index's next
identifier. Do not rewrite historical context to make a later outcome look
inevitable. When a decision changes, mark the old file, add its `Superseded by`
field, create the new ADR, and update both index rows. Never create another
aggregate ADR file. Keep secrets and irrelevant personal data out of ADRs.

## Canonical handoff

`docs/handoff.md` is working memory for the current milestone, not a diary. Keep
it concise, current, and directly actionable.

Update it whenever work reaches a meaningful state change and before ending a
session or approaching a context limit. It must state:

- current milestone and acceptance gate;
- objective and current verified state;
- completed work relevant to the active milestone;
- work in progress and exact next actions;
- blockers and decisions awaiting user input;
- ADRs relevant to the current slice and why;
- tests/checks run and their results;
- touched areas and important working-tree state; and
- temporary facts needed to resume safely.

Replace stale content instead of appending a session-by-session narrative. Do
not paste long logs, diffs, chat summaries, speculative ideas, or facts easily
rediscovered from the repository. Never store secrets.

Treat a milestone as complete only after its acceptance evidence is verified
and explicitly accepted. At that boundary:

1. Promote durable decisions/discoveries into individual `docs/adr/` files and
   update `docs/adr/README.md`.
2. Update the project plan or permanent documentation only where an approved
   durable change requires it.
3. Encode repeatable facts in tests, fixtures, or code comments where they are
   more authoritative than prose.
4. Reset `docs/handoff.md` in place for the next milestone using its existing
   template.
5. Delete transient details from the completed milestone. Do not archive old
   handoffs or create another handoff file.

## Implementation principles

- Implement every milestone as a sequence of small vertical slices, never as
  disconnected horizontal layers or a large batch of scaffolding. Each slice
  must cross the real end-to-end path relevant to that work—for example input
  or package, core behavior, observable output or side effect, status/error
  reporting, and verification.
- Define the slice's observable behavior and acceptance evidence before coding.
  A slice is complete only when it leaves behind something independently
  runnable or inspectable, focused automated tests, and any required
  real-machine verification. Record that evidence in the handoff.
- Keep the previous working path available while building the next slice. Do
  not combine several unverified slices and defer integration/testing until the
  end of a milestone.
- Extract shared frameworks only after multiple completed vertical slices prove
  the duplication and required boundary. Do not build generic infrastructure
  merely because later milestones might need it.
- Do not advance to the next milestone until every required slice for the
  current milestone satisfies the project plan's acceptance gate and the gate
  is explicitly accepted.
- Keep the theme pointer and normalized active theme authoritative; notification
  mechanisms are hints, not state.
- Prefer direct palette consumption and live repaint, then supported runtime
  reload, then next-invocation behavior. A restart requirement is the last
  resort and must have evidence.
- Keep slow subprocess, network, and optional adapter work off activation's
  canonical pointer-swap and native repaint path.
- Do not hide drift, unsupported capabilities, missing permissions, or failed
  reconciliation behind silent fallback.
- Preserve dotfile behavior ownership. Generated theme state belongs to
  Macarchy, not the dotfiles repository.
- Keep no-SA yabai, normal SIP, process-permission boundaries, clean-room
  Omacosy implementation, and no-telemetry policy intact unless the user
  explicitly changes them.
- Never commit local signing identities, certificates with private keys,
  provisioning secrets, tokens, generated runtime state, or user configuration.

## Verification and repository hygiene

- Add focused tests with implementation changes and run the narrowest relevant
  checks before broader suites.
- Record runtime-dependent claims as observations until tested on the supported
  machine.
- Keep generated output out of source control unless it is an intentional test
  fixture or golden file.
- Keep the gitignored `docs/` tree local; never use `git add -f` to commit it.
- Do not modify unrelated working-tree changes.
- Do not commit unless explicitly asked.

## Git and pull-request workflow

The initial repository bootstrap commit is the only direct-to-`main` exception.
After that commit, all implementation, documentation, configuration, fixes,
and refactors follow this workflow:

1. Start from an up-to-date local `main` that matches `origin/main`.
2. Create a new, purpose-specific branch from `main`. Do not work directly on
   `main` and do not reuse a branch for unrelated work.
3. Keep the branch scoped to one vertical slice or one tightly related review
   unit. If the slice is too large to review comfortably, split it before
   opening the PR.
4. Commit coherent increments frequently. Each commit should explain one
   meaningful step, keep the repository in an understandable state, and include
   its relevant tests when practical.
5. If work accumulated into a large change before committing, use selective
   staging to divide it into smaller logical commits. Never submit one huge
   mixed commit merely because the work was performed in one session.
6. Use Conventional Commit subjects (`type(scope): description` when a scope
   adds value). Avoid noisy checkpoint/WIP commits in the final PR history.
7. Run the relevant verification, update the local handoff, push the branch,
   and open a pull request. Direct pushes to `main` are prohibited.
8. Rebase the branch onto the latest `origin/main` before merge and resolve
   conflicts on the branch. Never merge `main` into the branch to update it.
9. Merge pull requests with GitHub's **Rebase and merge** method. Do not create
   merge commits and do not squash the carefully structured commit series into
   one oversized commit.
10. Delete merged branches. Begin the next slice from the newly updated
    `main`, not from a previous feature branch.

PR descriptions must identify the milestone and vertical slice, summarize the
observable behavior, list verification performed, and call out any ADR or
remaining restart/runtime limitation. Keep unrelated working-tree changes and
gitignored internal docs out of commits and PRs.
