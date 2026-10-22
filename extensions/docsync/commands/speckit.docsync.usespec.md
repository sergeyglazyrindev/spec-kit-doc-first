---
description: Ask the user for an external documentation source for the current feature (e.g. a Confluence page) and which platform it's on, fetch it, and either create a new spec from it (if no feature exists yet, the way speckit.specify does) or reconcile an existing spec's sections against it.
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

You **MUST** consider the user input before proceeding (if not empty). If it already looks like a documentation source (a URL, or a `<tool>:<id>` shorthand such as `confluence:<id>`), treat it as the source and skip straight to the Outline's dispatch step — do not ask again. A `<tool>:<id>` shorthand also names the platform; a bare URL does not, so the platform still needs to be resolved there (see step 2).

## Outline

Goal: pull in an external, authoritative documentation source for this feature. What happens with it depends on whether a feature already exists:

- **No current feature yet**: create one from the fetched content, the same way `__SPECKIT_COMMAND_SPECIFY__` creates a spec from a free-text description — except the "description" is the fetched page (and its direct child pages) instead of typed text.
- **A feature already exists**: reconcile its spec's **existing** sections against the fetched content — not append a new section, and not regenerate the file from scratch.

Either way, this command only reads external sources; it never keeps `spec.md` automatically synced with them afterward — each run is a deliberate, one-time pull. `__SPECKIT_COMMAND_SPECIFY__` and `__SPECKIT_COMMAND_CLARIFY__` are unaffected by this command and do not call it automatically. `speckit.docsync.refreshspec` is the companion command that re-pulls the same source later and reconciles every feature artifact, not just the spec.

Execution steps:

1. Run `{SCRIPT}` from repo root **once** (combined `--json --paths-only` mode / `-Json -PathsOnly`).
   - If it succeeds, set `HAS_FEATURE = true` and parse `FEATURE_DIR` and `FEATURE_SPEC` from its output.
   - If it fails specifically because there is no current feature on record (the script's "No current feature on record" error), set `HAS_FEATURE = false` and continue — step 6 below creates one from the fetched content, the way `__SPECKIT_COMMAND_SPECIFY__` would. Do **not** stop here.
   - If it fails for any other reason (e.g. this isn't a Spec Kit project at all), surface that error and stop, telling the user to run `specify init` first.
   - For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **Determine the documentation platform and source**:
   - If `$ARGUMENTS` is a `<tool>:<id>` shorthand, that names both the platform (`<tool>`) and the source — use it directly and skip to step 3's **known-platform dispatch**.
   - If `$ARGUMENTS` is a bare URL (no tool prefix), use it as the source but the platform is still unknown — skip to step 3's **auto-match dispatch**.
   - Otherwise (no usable argument), ask the user for both at once: **"What's the source of documentation for this feature, and which platform is it on?"** List the platforms actually installed as explicit choices — read `.specify/extensions.yml`'s `hooks.before_usespec` entries and offer one option per distinct `extension` value found there (e.g. "Confluence"), plus an "Other — I'll paste the content directly" option (always offered, and the only option when the hook list is empty or unreadable). Wait for their reply with a platform choice and a URL/shorthand.
   - If the reply is "skip", "none", "no", or similar — report that nothing was changed and stop here. Do not treat silence or a refusal as an error. If `HAS_FEATURE` is false, mention `__SPECKIT_COMMAND_SPECIFY__` as the way to create a spec from a typed description instead.
   - If the user picked "Other — I'll paste the content directly", skip straight to step 4's manual-paste fallback.

3. **Dispatch the fetch via extension hooks**:
   - Check if `.specify/extensions.yml` exists and look for entries under the `hooks.before_usespec` key. (This is the same hook-registration file every other command's extension-hook checks use. `before_usespec` is a custom event owned by this command, not a core Spec Kit event — any installed extension can register a fetch integration under it, exactly as `confluence` does.)
   - If the YAML cannot be parsed, tell the user it couldn't be read (include the parser error) and treat this as "no hooks registered" below — do not abort the whole command over it.
   - Filter out hooks where `enabled` is explicitly `false`. Skip any hook with a non-empty `condition` (leave evaluation to the HookExecutor implementation, per the standard convention).
   - **Known-platform dispatch** (step 2 resolved a specific platform — via the `<tool>:<id>` shorthand or the user's explicit choice): filter the remaining hooks to the one whose `extension` field matches the chosen platform (case-insensitive).
     - If none match (that platform isn't installed), tell the user there's no fetch integration installed for that platform and go to step 4's manual-paste fallback.
     - Otherwise invoke that hook's `command` with the source text from step 2 as its argument — run it the same way you would run the command yourself in this agent/session (a skills-mode agent runs it as `/skill:speckit-...` or `$speckit-...`). Parse its JSON result.
       - `"matched": true` (success or with an `error`) — proceed to step 4 with that result.
       - `"matched": false` — the given reference doesn't actually look like one for that platform. Tell the user, and let them retry with a corrected reference for the same platform, switch platforms (back to step 2), or paste manually (step 4).
   - **Auto-match dispatch** (step 2 didn't resolve a platform — the bare-URL shortcut): for each remaining hook **in order**, invoke its `command` with the source text from step 2. Parse its JSON result.
     - `"matched": true` (whether it succeeded or carries an `error`) — **stop checking further hooks** — this one claimed the reference. Only one fetch extension should ever recognize a given source.
     - `"matched": false` — continue to the next hook.
     - If every registered hook returns `"matched": false`, treat it the same as "no hooks registered": tell the user none of the installed fetch integrations recognize this source, and go to step 4's manual-paste fallback.
   - If no hooks are registered at all (including the case where `.specify/extensions.yml` doesn't exist): tell the user there's no fetch integration installed for this kind of source (mention that the `confluence` extension provides one) and go to step 4's manual-paste fallback.

4. **Resolve the fetched content**:
   - **A hook returned `"matched": true` with an `error`**: show the `message` to the user. Ask whether to retry with a different source, paste the content manually (continue below), or skip (stop here, nothing changed).
   - **A hook returned `"matched": true` with `title`/`content`**: that's your fetched content; `sourceUrl` and `fetchedAt` come from the same result. If the result also carries a non-empty `children` array (the referenced page's direct child pages — one level, fetched automatically by the hook, not something you request separately), treat each child's `title`/`content`/`sourceUrl` as additional source material alongside the root page for step 6's generation or reconciliation; mention in the Completion Report how many child pages were included, and flag it if `childrenTruncated` is `true` (more children exist than were fetched). Proceed to step 5.
   - **Manual-paste fallback** (no hook recognized the source, no hook was installed for the chosen platform, or the user chose to paste after an error or explicitly asked to): ask the user to paste the relevant content directly. Use their pasted text as `content`, ask them for a short title if one isn't obvious from the text, and set `sourceUrl` to the source text they originally gave (or "user-provided" if step 2 was skipped and they're pasting ad hoc) and `fetchedAt` to the current date. There are no `children` in this path — if the user has more relevant pages, they can paste those too and you fold them in the same way. Proceed to step 5.
   - If the user chooses to skip at any point in this step, report that nothing changed and stop.

5. **IF EXISTS**: Load `/memory/constitution.md` for project principles and governance constraints — neither path in step 6 may introduce anything that conflicts with it.

6. **Branch on `HAS_FEATURE` from step 1:**

   **A. `HAS_FEATURE` is false — create a new spec from the fetched content.**

   Build one combined source text first: the root page's `title` + `content`, followed by each child page's `title` + `content` from step 4 (if any). Then follow `__SPECKIT_COMMAND_SPECIFY__`'s Outline **exactly as written there** — steps 1 ("Generate a concise short name"), 2 ("Branch creation"), 3 ("Create the spec feature directory"), 4 ("Load the resolved active `spec-template` file"), 6 ("Follow this execution flow"), 7 ("Write the specification"), 8 ("Specification Quality Validation"), and its **Mandatory Post-Execution Hooks** section — substituting that combined source text everywhere `__SPECKIT_COMMAND_SPECIFY__` uses "the feature description" / `$ARGUMENTS`. In particular:
      - **Short name** (specify step 1): derive it from the fetched `title` when it's specific; when the title is generic (e.g. "Untitled", "Home", "Notes", or absent), fall back to extracting a short name from the body the same way specify does from free text.
      - **Branch creation** (specify step 2): dispatches the **`before_specify`** hook (e.g. the git extension) exactly as `__SPECKIT_COMMAND_SPECIFY__` does. This is a separate hook event from the `before_usespec` fetch already dispatched in step 3 above — both may run during this flow, for different purposes.
      - **Feature directory + `.specify/feature.json`** (specify step 3): identical — same `SPECIFY_FEATURE_DIRECTORY` resolution order, same persistence.
      - **Execution flow and writing the spec** (specify steps 6-7): identical, parsing the combined source text as "the feature description." `[NEEDS CLARIFICATION: ...]` markers follow the same rules and the same 3-marker limit.
      - **Quality validation** (specify step 8): identical, including the clarification Q&A loop (max 3 markers, max 3 validation iterations) if the fetched content leaves genuine ambiguity.
      - **Mandatory Post-Execution Hooks** (`after_specify`): identical.

      **Specific to this command**, once the spec has been written (as part of specify step 7): set the `**Input**:` line to a short note since there was no typed description, e.g. `**Input**: User description: "Imported from <title>"`, and immediately after it add a `**Source**:` citation line: `**Source**: [<title>](<sourceUrl>) — fetched <fetchedAt>`, appending `+ N child page(s)` when `children` was non-empty.

   **B. `HAS_FEATURE` is true — reconcile the existing spec (this command's original behavior).**

   Reconcile `FEATURE_SPEC`'s existing sections against the fetched content (the root page plus any direct child pages from step 4, treated as one combined body of source material; do not create a new top-level section for this; do not regenerate the file from scratch — this is a targeted update of what's already there):
      - Load the current spec file and keep both an in-memory structured view and the raw text.
      - **Source citation**: update (or add, if absent) a `**Source**:` metadata line immediately after the existing `**Input**: User description: "..."` line, formatted as `**Source**: [<title>](<sourceUrl>) — fetched <fetchedAt>`, and append `+ N child page(s)` to that line when `children` was non-empty. If a `**Source**` line from a previous `speckit.docsync.usespec` run already exists, replace it rather than adding a second one.
      - **Section-by-section reconciliation** — mirror the category → section mapping `__SPECKIT_COMMAND_CLARIFY__` uses for the same spec template, but driven by what the fetched content says rather than by a Q&A answer:
        - User flows / journeys described in the source → add a new `### User Story N` entry (next priority slot) if not already covered, or sharpen an existing one's placeholder bracketed text.
        - Negative/boundary scenarios in the source → add bullets under `### Edge Cases`.
        - Capabilities, behaviors, or constraints the source specifies → resolve any `[NEEDS CLARIFICATION: ...]` marker it answers, and add new `FR-0NN` bullets under `### Functional Requirements` for capabilities not yet listed. Never renumber or remove an existing FR unless the source directly contradicts it (see Conflict handling below).
        - Entities/data the source defines → add or sharpen bullets under `### Key Entities`.
        - Metrics or measurable outcomes the source specifies → add new `SC-0NN` bullets under `### Measurable Outcomes`, or sharpen a vague existing one.
        - Anything the source leaves genuinely unclear → leave or add a bullet under `## Assumptions` as today; anything the source newly resolves should be **removed** from Assumptions once it's been moved into the section above that now states it concretely (no duplication between Assumptions and a resolved section).
      - **Conflict handling**: if the source directly contradicts an existing, already-decided statement in the spec (not merely "more specific than a placeholder" — an actual different decision, e.g. spec says email/password auth and the source says SSO-only), do **not** silently overwrite it. Collect these as a list and present them to the user, one at a time or as a short table (existing text vs. source text), and ask which should win before writing that specific change. Everything non-conflicting from the reconciliation above can be written without asking.
      - Preserve heading hierarchy and the ordering of unrelated content; only touch what the reconciliation above actually changes.
      - Save `FEATURE_SPEC` after reconciliation (atomic overwrite).

7. **Re-validate the Spec Quality Checklist** — only applies to path **B** above (path A already creates and validates its own checklist inline as part of `__SPECKIT_COMMAND_SPECIFY__` step 8). For path B, identical procedure to `__SPECKIT_COMMAND_CLARIFY__`'s checklist re-validation:
   - If `FEATURE_DIR/checklists/requirements.md` does not exist, skip silently.
   - Otherwise: snapshot each `- [ ]`/`- [x]`/`- [X]` checkbox line's state and text, re-evaluate each against the spec as just updated, and toggle only the items whose pass/fail state actually changed (preserve case on unchanged items; touch nothing else in the file). Compute newly-passing, regressions, and still-unchecked lists plus a before/after pass count for the Completion Report.

## Mandatory Post-Execution Hooks

**You MUST complete this section before reporting completion to the user.**

Check if `.specify/extensions.yml` exists in the project root.
- If it does not exist, or no hooks are registered under `hooks.after_usespec`, skip to the Completion Report.
- If it exists, read it and look for entries under the `hooks.after_usespec` key.
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

This is distinct from the `before_usespec` fetch dispatch in step 3 above — that event resolves the source content and runs mid-flow with its own `matched`/`content` contract; `after_usespec` is a plain post-execution hook (e.g. for the `git` extension's auto-commit or the `agent-context` extension's context refresh), and it fires once, after path A or B has finished writing, regardless of which path ran.

## Completion Report

Report, matching whichever path ran:

- **Path A (created)**: the same shape as `__SPECKIT_COMMAND_SPECIFY__`'s completion report — feature directory, spec file path, checklist results, readiness for the next phase — plus the source used (title + URL + fetch time, and child-page count if any).
- **Path B (reconciled)**:
  - The source used: title + URL + fetch time, or "pasted manually", or "skipped — no source provided".
  - Sections touched, with a short bullet per change (e.g. "Added FR-006 (SSO requirement)", "Resolved NEEDS CLARIFICATION in FR-002", "Added User Story 3").
  - Any conflicts that were flagged, and how each was resolved.
  - Spec quality checklist status (before/after pass counts and any newly-passing/regressed/still-unchecked items).
- **Skipped (either path)**: "skipped — no source provided", and for path A, a reminder that `__SPECKIT_COMMAND_SPECIFY__` can create a spec from a typed description instead.

Either way, suggest the next command: `__SPECKIT_COMMAND_CLARIFY__` if unresolved ambiguities remain, otherwise `__SPECKIT_COMMAND_PLAN__`. Mention `speckit.docsync.refreshspec` as the way to pull this same source again later.

## Done When

- [ ] `HAS_FEATURE` was determined from the prerequisites check, without stopping just because no feature exists yet
- [ ] A documentation platform and source were determined (explicit platform + source asked when not already given, fetched via the matching extension hook, pasted manually, or explicitly skipped)
- [ ] If no feature existed: a new spec was created from the fetched content the same way `__SPECKIT_COMMAND_SPECIFY__` creates one (short name, branch, directory, template, execution flow, checklist, post-hooks), with a `**Source**:` citation recorded
- [ ] If a feature already existed: `FEATURE_SPEC`'s existing sections were reconciled against the fetched content, with conflicts surfaced to the user rather than silently overwritten
- [ ] Spec quality checklist created-and-validated (path A) or re-validated (path B)
- [ ] Extension hooks dispatched or skipped according to the rules in Mandatory Post-Execution Hooks above
- [ ] Completion reported with the shape matching whichever path ran
