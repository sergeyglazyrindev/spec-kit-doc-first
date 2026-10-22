# Documentation Source Sync

Treat an external doc page (Confluence, Docmost, or anything you can paste)
as the source of truth for a Spec Kit feature, instead of a spec that
quietly drifts from the wiki someone else keeps editing.

## Commands

| Command | Description |
| --- | --- |
| `speckit.docsync.usespec` | Ask for (or accept) a documentation source for the current feature. With no current feature, creates a new spec from it — the same way `speckit.specify` creates one from typed text. With an existing feature, reconciles the spec's existing sections against the source instead of appending or regenerating. |
| `speckit.docsync.refreshspec` | Re-fetch the source already on record (set by a prior `usespec` run) and reconcile every existing feature artifact against it — `spec.md`, `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`, and `contracts/`. |

Neither command keeps anything automatically in sync afterward — each run is
a deliberate, one-time pull. That is the whole point of having two
commands: `usespec` establishes (or re-establishes) a source, `refreshspec`
re-pulls it later without having to re-ask.

## How it fetches a source

This extension defines the fetch contract but doesn't implement any
particular wiki's API itself. `speckit.docsync.usespec` dispatches to
whichever extension claims the given reference, via a hook event named
`before_usespec`:

```yaml
hooks:
  before_usespec:
    command: speckit.docmost.fetch   # or speckit.confluence.fetch, etc.
    optional: false
```

Both commands read `.specify/extensions.yml` for `hooks.before_usespec`
entries and invoke each hook's command with the source text, expecting one
JSON object back: `{"matched": true|false, "title", "content", "sourceUrl",
"fetchedAt", "children"?, "childrenTruncated"?, "error"?}`. The first hook to
report `matched: true` wins. See the sibling `docmost` and `confluence`
extensions for two working implementations of this contract — install
either (or both) alongside this extension to give `usespec`/`refreshspec`
something to fetch from. Without one installed, `usespec` falls back to
asking the user to paste content directly; `refreshspec` has no such
fallback (there's no interactive moment mid-refresh) and stops with an
error telling the user which extension to install.

`before_usespec` is a custom event owned by this extension's commands, not a
core Spec Kit hook — any extension can register a fetch integration under
it, the same way `docmost` and `confluence` do.

## Post-execution hooks

Both commands also fire a plain post-execution hook once they finish
writing — `after_usespec` and `after_refreshspec` respectively — so other
extensions can react the same way they react to core commands like
`after_specify`. For example, the bundled `git` extension's auto-commit and
the bundled `agent-context` extension's context refresh can both be wired to
these events in a project's `.specify/extensions.yml`:

```yaml
hooks:
  after_usespec:
    - command: speckit.git.commit
      optional: true
      prompt: "Commit changes pulled from external documentation?"
    - command: speckit.agent-context.update
      optional: true
  after_refreshspec:
    - command: speckit.git.commit
      optional: true
      prompt: "Commit changes from the refreshed documentation source?"
    - command: speckit.agent-context.update
      optional: true
```

This extension does not register those hooks itself — it only defines (and
fires) the events. Wire them up in your project's extension configuration
for whichever extensions you want reacting to a doc sync.

## Setup

```bash
specify extension add --dev /path/to/spec-kit-doc-first/extensions/docsync
# or, during init:
specify init my-project --extension /path/to/spec-kit-doc-first/extensions/docsync
```

Install at least one fetch integration alongside it (`docmost`, `confluence`,
or your own extension implementing the same `before_usespec` contract) —
otherwise every run falls back to pasting content by hand.

## Why a standalone extension, not a core command

This started as two core Spec Kit commands. Doc-sync is a workflow a subset
of projects want, not something every Spec Kit user needs baked in — and
keeping it as an extension means it can version, ship, and break
independently of core, exactly like `github`'s issue sync or `agent-context`'s
file management already do.
