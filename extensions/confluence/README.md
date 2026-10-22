# Confluence Source Integration

Fetch content straight from a Confluence page — plus its direct child
pages, so the feature's supporting detail comes along automatically — so
`spec.md` can be reconciled against the wiki itself, instead of someone
hand-copying (and silently drifting from) it. Unlike the sibling `docmost`
extension, this one has **no fetch script and no API token to manage** — it
calls Atlassian's own official remote MCP server tools directly, so the AI
agent itself does the fetching.

Like `docmost`, this is an **input**, not an automatic ongoing sync: each
`speckit.docsync.usespec` run (provided by the sibling `docsync` extension,
which dispatches this one) is a deliberate, one-time reconciliation. To pull
in later page edits, either run `speckit.docsync.usespec` again, or run
`speckit.docsync.refreshspec`, which re-fetches whatever source is already on
record (no re-asking) and reconciles it across every existing feature
artifact (spec, plan, tasks, etc.), not just `spec.md`.

## Requirements

- Confluence **Cloud** (the official Atlassian MCP server is Cloud-only — no
  Server/Data Center support).
- The [Atlassian MCP server](https://github.com/atlassian/atlassian-mcp-server)
  connected in your AI client (`mcp.atlassian.com`, identifier `atlassian`),
  with at least the `read:confluence:agent-interface` scope (OAuth 2.1 is
  the normal flow; an API token also works if your admin allows it).

If that MCP server isn't connected, this extension's hook detects that and
tells the calling command. `speckit.docsync.usespec` falls through to asking
you to paste the content manually; `speckit.docsync.refreshspec` has no such
fallback and stops with an error, since there's no interactive moment to ask
for a paste mid-refresh. Neither blocks the rest of the command's other work
entirely.

## What it does

Adds one command, `speckit.confluence.fetch`, and registers it as a
**mandatory (automatic)** `before_usespec` hook — fired by both
`speckit.docsync.usespec` and `speckit.docsync.refreshspec`, the `docsync`
extension's commands for pulling an external doc into (or back into) the
current feature's artifacts. When either command runs with a Confluence
reference:

- If it contains a Confluence page URL (`/wiki/spaces/.../pages/...` or a
  `/wiki/x/...` shortlink) or the `confluence:<pageId>` shorthand, the agent
  calls the Atlassian MCP server's `getConfluenceContent` tool automatically
  — no separate confirmation prompt.
- If the source doesn't match (wrong tool, bad reference), this hook reports
  a no-op; `speckit.docsync.usespec` falls through to its manual-paste
  fallback, while `speckit.docsync.refreshspec` stops with an error.

You can also run `/speckit.confluence.fetch <url>` standalone, any time, to
preview a page's content without going through either command.

## Setup

```bash
specify extension add --dev /path/to/spec-kit-doc-first/extensions/confluence
# or, during init:
specify init my-project --extension /path/to/spec-kit-doc-first/extensions/confluence
```

Install the sibling `docsync` extension too, since that's what provides
`speckit.docsync.usespec` and `speckit.docsync.refreshspec`. Nothing else to
configure here — authentication is whatever your AI client's Atlassian MCP
connection already has.

## Example

```text
/speckit.docsync.usespec
> What's the source of documentation for this feature?
https://yourteam.atlassian.net/wiki/spaces/ENG/pages/123456789/Checkout+Redesign
```

## Searching by topic instead of a link

If you run `/speckit.confluence.fetch` standalone and ask explicitly to
search by topic rather than give a link, the command may use the MCP
server's `searchConfluence` (CQL) tool to find candidates — but it will
always show you the matches and ask you to confirm before fetching one. A
pasted URL skips that confirmation; a keyword search does not, since it can
return the wrong page. This search path isn't part of the automatic
`before_usespec` hook.

## Direct child pages

After fetching the referenced page, this also runs `searchConfluence` with
CQL `parent = <pageId> and type = page` (**direct children only** — never
`ancestor =`, which would return the entire recursive subtree) and fetches
up to 20 of them via `getConfluenceContent`. Each is included in the
result's `children`; more than 20 direct children means some were left out
(`childrenTruncated: true`). In-body hyperlinks inside the page's own content
are never followed — only this structural parent/child relationship. A
failure fetching children never fails the command — the root page already
succeeded and stands on its own.

## Why no fetch script?

The sibling `docmost` extension calls Docmost's REST API directly with a
bash/python script and a personal API token, because Docmost's own MCP
server is gated behind a paid Business/Enterprise license. Confluence's
official MCP server has no such gate on Cloud, so there's a cleaner option:
let the AI agent call it directly, exactly like Spec Kit's own `github`
extension calls the `github-mcp-server`'s tools instead of shelling out to
the GitHub REST API. No token to store, no script to maintain.
