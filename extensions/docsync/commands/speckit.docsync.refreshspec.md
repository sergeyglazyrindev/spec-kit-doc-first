---
description: Re-fetch the documentation source already on record for the current feature (set by speckit.docsync.usespec) and reconcile every existing feature artifact against it — spec.md, plan.md, tasks.md, research.md, data-model.md, quickstart.md, and contracts/.
handoffs:
  - label: Build Technical Plan
    agent: speckit.plan
    prompt: Create a plan for the spec. I am building with...
scripts:
  sh: scripts/bash/resolve-feature-paths.sh --json --paths-only
  ps: scripts/powershell/resolve-feature-paths.ps1 -Json -PathsOnly
  py: scripts/python/resolve_feature_paths.py --json --paths-only
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty). If non-empty, treat it as an override source to refresh from instead of the one already on record (see step 2) — a URL or `<tool>:<id>` shorthand. Otherwise this command takes no interactive input of its own; it never asks "what's the source?" the way `speckit.docsync.usespec` does.

## Outline

Goal: re-pull the documentation source already established for this feature and reconcile **every existing artifact for this feature** against what changed — not just `spec.md`. This command never establishes a source for the first time (that's `speckit.docsync.usespec`'s job) and never regenerates a file from scratch — every file is reconciled the same careful way: add what the refreshed source introduces that isn't captured yet, and flag (never silently overwrite) anything it contradicts. Completed task checkmarks, existing task/requirement IDs, and already-decided technical choices in `plan.md` are never silently rewritten.

Execution steps:

1. Run `{SCRIPT}` from repo root **once** (combined `--json --paths-only` mode / `-Json -PathsOnly`). Parse `FEATURE_DIR`, `FEATURE_SPEC`, `IMPL_PLAN`, `TASKS`, `RESEARCH`, `DATA_MODEL`, `QUICKSTART`, `CONTRACTS_DIR`.
   - If this fails or there is no current feature on record, tell the user to run `__SPECKIT_COMMAND_SPECIFY__` (or `speckit.docsync.usespec`) first and stop.
   - For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **Determine the source to refresh from**:
   - If `$ARGUMENTS` is non-empty, use it as the source (an explicit override).
   - Otherwise, read `FEATURE_SPEC` for an existing `**Source**:` citation line (the format `speckit.docsync.usespec` writes: `**Source**: [<title>](<sourceUrl>) — fetched <fetchedAt>`, optionally followed by `+ N child page(s)`). Extract `<sourceUrl>`.
   - If there is no `**Source**:` line and no override was given, there is nothing on record to refresh — tell the user to run `speckit.docsync.usespec` first to establish a source, and stop. Do not ask "what's the source?" yourself; that would blur this command's purpose with `speckit.docsync.usespec`'s.

3. **Dispatch the fetch via extension hooks** — identical mechanism to `speckit.docsync.usespec`'s step 3, reusing the same `hooks.before_usespec` event (no separate `before_refreshspec` fetch hook exists; the fetch is the same operation either command needs, so both dispatch the same way):
   - Check if `.specify/extensions.yml` exists and look for entries under `hooks.before_usespec`.
   - If the YAML cannot be parsed, tell the user it couldn't be read (include the parser error) and treat this as "no hooks registered" below.
   - Filter out hooks where `enabled` is explicitly `false`. Skip any hook with a non-empty `condition`.
   - If no hooks are registered: tell the user none of the installed extensions can fetch this source (mention `docmost`/`confluence` if neither is installed) and stop — unlike `speckit.docsync.usespec`, there is no manual-paste fallback here, since there's no interactive moment to ask for pasted content in a refresh.
   - Otherwise, for each remaining hook **in order**: invoke its `command` with the source text from step 2 as its argument — run it the same way you would run the command yourself in this agent/session. Parse its JSON result.
     - `"matched": true` (success or error) stops the search — this hook claimed the reference.
     - `"matched": false` continues to the next hook.
   - If every hook returns `"matched": false`, tell the user the recorded source is no longer recognized (the extension that originally fetched it may have been removed, or the source format changed) and stop, suggesting `speckit.docsync.usespec` to re-establish it.
   - If the matching hook returns `"matched": true` with an `error`, show the `message` and stop — do not partially reconcile anything.
   - On success you have `title`/`content`/`sourceUrl`/`fetchedAt`, and optionally a `children` array (direct child pages, fetched automatically) with a `childrenTruncated` flag — treat every child's content as additional source material alongside the root page, exactly as `speckit.docsync.usespec` does.

4. **IF EXISTS**: Load `/memory/constitution.md` for project principles and governance constraints — none of the reconciliation in step 5 may introduce anything that conflicts with it.

5. **Reconcile every existing feature artifact against the fetched content.** Only reconcile a file if it already exists — never create `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`, or `contracts/*` from scratch; that remains `__SPECKIT_COMMAND_PLAN__`/`__SPECKIT_COMMAND_TASKS__`'s job. For every file below, the same two rules apply: **add** what the source introduces that isn't captured yet; **flag** (collect into one combined conflict list, do not silently overwrite) anything the source directly contradicts — an actual different decision, not just "more specific than a placeholder."

   - **`FEATURE_SPEC`** (`spec.md`): identical procedure to `speckit.docsync.usespec`'s step 6 — update/add the `**Source**:` citation line (replace the existing one, including the child-page count), and reconcile User Stories, Edge Cases, Functional Requirements, Key Entities, Measurable Outcomes, and Assumptions the same way.
   - **`TASKS`** (`tasks.md`), if it exists:
     - For a capability the refreshed source introduces that no existing task covers, append a new task using the next available ID (`T{M+1:03d}` — the same floor-not-cap convention `__SPECKIT_COMMAND_CONVERGE__` uses, so this is safe to run after convergence has already assigned IDs past 999).
     - Never renumber, reorder, or delete an existing task, and never change any `- [x]` / `- [ ]` completion marker — a refresh is about new/changed source material, not re-grading already-tracked work.
     - If the source directly contradicts the premise of an existing, not-yet-completed task (e.g. it specifies a different approach than what the task assumes), do not delete or silently rewrite it — add it to the combined conflict list so the user decides whether to mark it obsolete.
   - **`IMPL_PLAN`** (`plan.md`), if it exists: add new content for scope the source introduces that plan.md doesn't yet address (e.g. a new constraint needing a new section). If the source contradicts an already-documented technical decision (architecture, data flow, integration choice), do not rewrite that decision — flag it; resolving a real plan-level conflict belongs to a deliberate re-run of `__SPECKIT_COMMAND_PLAN__`, not a silent edit here.
   - **`RESEARCH`** (`research.md`), **`DATA_MODEL`** (`data-model.md`), **`QUICKSTART`** (`quickstart.md`), if they exist: same add/flag treatment — append findings, entities, or steps the source newly introduces; flag contradictions of existing documented content.
   - **`CONTRACTS_DIR`** (`contracts/`), if it exists and is non-empty: only flag — do not edit contract files automatically. A contract conflict (e.g. the source implies a different request/response shape) always needs a deliberate decision, never a silent rewrite of an API shape other code may already depend on.
   - **Conflict review**: once every file above has been scanned, present the full combined conflict list to the user **once**, grouped by file (e.g. "## spec.md" / "## tasks.md" / ...), each entry showing the existing text vs. what the source says. Apply every non-conflicting change first (you don't need to wait on the review for those), then apply the user's resolution for each conflict they choose to accept.
   - Preserve heading hierarchy and ordering within every file touched; only change what the reconciliation above actually changes. Save each modified file after reconciliation (atomic overwrite per file).

6. **Re-validate every checklist** under `FEATURE_DIR/checklists/*.md` (if any exist) — same procedure `__SPECKIT_COMMAND_CLARIFY__` and `speckit.docsync.usespec` use for `requirements.md`, generalized to every checklist file found: snapshot each checkbox's state and text, re-evaluate against the files as just updated, toggle only items whose pass/fail state actually changed, and compute before/after pass counts per checklist.

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_refreshspec`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_refreshspec` key.
- If the YAML cannot be parsed or is invalid, do not skip silently: tell the user that `.specify/extensions.yml` could not be read (include the parser error) and that no hooks were checked, including any mandatory (`optional: false`) hooks registered there, then continue to the Completion Report.
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- For each executable hook, output the following based on its `optional` flag:
  - **Mandatory hook** (`optional: false`) — **You MUST emit `EXECUTE_COMMAND:` for each mandatory hook**:
    ```
    ## Extension Hooks

    **Automatic Hook**: {extension}
    Executing: `/{command}`
    EXECUTE_COMMAND: {command}
    ```
    After emitting the block above you MUST actually invoke the hook and wait for it to finish before continuing. Run it the same way you would run the command yourself in this agent/session (the invocation may differ from the literal `{command}` id shown above, e.g. a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Emitting the block alone does not run the hook.
  - **Optional hook** (`optional: true`):
    ```
    ## Extension Hooks

    **Optional Hook**: {extension}
    Command: `/{command}`
    Description: {description}

    Prompt: {prompt}
    To execute: `/{command}`
    ```
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Completion Report

Report:
- The source refreshed from: title + URL + fetch time, plus child-page count if any.
- Per file touched (only list files that actually exist and were scanned): a short bullet list of what changed, or "no changes needed" if the refresh introduced nothing new for that file.
- The combined conflict list and how each was resolved (including any the user declined to apply).
- Checklist statuses, for every checklist re-validated (before/after pass counts).
- Suggested next command — `__SPECKIT_COMMAND_PLAN__` or `__SPECKIT_COMMAND_TASKS__` if a flagged plan/contract conflict needs a deliberate re-run, otherwise whatever the normal next step in the workflow is.

## Done When

- [ ] The source already on record (or an explicit override) was re-fetched, or the command stopped cleanly with instructions to run `speckit.docsync.usespec` first
- [ ] Every existing feature artifact (`spec.md`, and `plan.md`/`tasks.md`/`research.md`/`data-model.md`/`quickstart.md`/`contracts/` wherever they exist) was reconciled against the refreshed content, with conflicts surfaced once as a combined list rather than silently overwritten
- [ ] No existing task ID, task completion marker, or already-decided plan/contract content was silently rewritten
- [ ] Every checklist under `FEATURE_DIR/checklists/` was re-validated (if any exist)
- [ ] Completion reported with source, per-file changes, conflicts, and checklist status
