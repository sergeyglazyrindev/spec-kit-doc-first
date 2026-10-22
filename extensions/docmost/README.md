# Docmost Source Integration

Fetch content straight from a [Docmost](https://docmost.com) page — plus its
direct child pages, so the feature's supporting detail comes along
automatically — so `spec.md` can be reconciled against the wiki itself,
instead of someone hand-copying (and silently drifting from) it. This closes
the usual "two sources of truth" gap between a team's wiki and its spec-kit
specs — but only as an **input**, via the `speckit.docsync.usespec` command
from the sibling `docsync` extension. Spec Kit does not keep `spec.md`
synced with the page afterward automatically — each `speckit.docsync.usespec`
run is a deliberate, one-time reconciliation. To pull in a page's later
edits, either run `speckit.docsync.usespec` again, or run
`speckit.docsync.refreshspec`, which re-fetches whatever source is already on
record (no re-asking) and reconciles it across every existing feature
artifact (spec, plan, tasks, etc.), not just `spec.md`.

## What it does

Adds one command, `speckit.docmost.fetch`, and registers it as a **mandatory
(automatic)** `before_usespec` hook — fired by both `speckit.docsync.usespec`
and `speckit.docsync.refreshspec`, the `docsync` extension's commands for
pulling an external doc into (or back into) the current feature's artifacts.
When either command runs with a Docmost reference:

- If it contains a Docmost page URL (anything with `/p/` in the path) or the
  `docmost:<pageId>` shorthand, the agent fetches that page's content
  automatically — no separate confirmation prompt.
- If the source doesn't match (wrong tool, bad reference), this hook reports
  a no-op; `speckit.docsync.usespec` falls through to its manual-paste
  fallback, while `speckit.docsync.refreshspec` has no such fallback and
  stops with an error.

You can also run `/speckit.docmost.fetch <url>` standalone, any time, to
preview a page's content as Markdown without going through either command.

## Setup

1. Install the extension in your project:

   ```bash
   specify extension add --dev /path/to/spec-kit-doc-first/extensions/docmost
   # or, during init:
   specify init my-project --extension /path/to/spec-kit-doc-first/extensions/docmost
   ```

   `docmost` only provides the fetch hook — install the sibling `docsync`
   extension too, since that's what provides `speckit.docsync.usespec` and
   `speckit.docsync.refreshspec`.

2. Create a Docmost API token: in Docmost, go to **Settings → API tokens**,
   create one, and export it:

   ```bash
   export DOCMOST_API_TOKEN="<token>"
   ```

   This is the only required setup when you reference pages by their full
   URL (e.g. pasted straight from the browser) — the instance's base URL is
   read from the URL itself.

3. *(Optional, only for the `docmost:<pageId>` shorthand)* — set a default
   instance URL:

   ```bash
   cp .specify/extensions/docmost/config-template.yml \
      .specify/extensions/docmost/docmost-config.yml
   # edit base_url in docmost-config.yml
   ```

   Never put the token itself in this file — it stays in the environment
   variable (`DOCMOST_API_TOKEN` by default; `api_token_env` in the config
   lets you point at a different variable name).

## Example

```text
/speckit.docsync.usespec
> What's the source of documentation for this feature?
https://docmost.example.com/s/eng/p/checkout-redesign-t7i4wXav8l
```

`speckit.docsync.usespec` fetches the page via this extension and reconciles
the current feature's `spec.md` sections against it, recording a `**Source**`
citation and the fetch time.

## How reference detection works

| Input form | Resolved against |
| --- | --- |
| Full URL containing `/p/...` | Base URL + page ID parsed directly from the URL |
| `docmost:<pageId>` | `base_url` from `docmost-config.yml` |
| Anything else | Not matched — hook reports `matched: false`, `speckit.docsync.usespec` falls through to another hook or its manual-paste fallback |

Under the hood this calls Docmost's `POST /api/pages/info` with
`{"pageId": "<id>", "format": "markdown"}`, which accepts either a page's
UUID or its short slugId (the trailing segment of a page URL) and returns the
page's body already converted to Markdown.

## Direct child pages

After fetching the referenced page, this also calls `POST
/api/pages/sidebar-pages` (filtered by `parentPageId` — **direct children
only**, one level, never the full recursive subtree) and fetches up to 20 of
them the same way as the root page. Each is included in the result's
`children` array; `childrenTruncated: true` means the page has more than 20
children and some were left out. In-body hyperlinks inside the page's own
content are never followed — only this structural parent/child relationship.
A failure fetching children never fails the command — the root page already
succeeded and stands on its own.

## Adding another wiki backend (e.g. Confluence)

This extension deliberately keeps the "detect a reference → fetch → emit
`{matched, title, content, sourceUrl, fetchedAt}` JSON" contract generic. The
sibling `confluence` extension follows the exact same shape, registered on
the same `before_usespec` hook — `speckit.docsync.usespec` tries each
registered hook in turn and stops at the first one that claims the reference
(`matched: true`), so installing both at once is safe.
