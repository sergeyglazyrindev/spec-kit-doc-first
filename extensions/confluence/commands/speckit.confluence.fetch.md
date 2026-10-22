---
description: "Fetch a Confluence page referenced in the input, via the Atlassian MCP server, and output its content"
tools: ['atlassian/atlassian-mcp-server/getConfluenceContent', 'atlassian/atlassian-mcp-server/searchConfluence']
---

# Fetch Content From Confluence

Resolve a Confluence page reference found in the input into content, via the Atlassian MCP server's own tools — there is no script in this extension and no API token to manage; authentication is whatever the MCP server session already has (OAuth 2.1, typically). This command only reads from Confluence; it never writes to any file itself. It can be run two ways:

- **Standalone**, as a preview: the user runs `/speckit.confluence.fetch <url>` directly to see a page's content.
- **As a hook**, dispatched by another command (currently `speckit.docsync.usespec` / `speckit.docsync.refreshspec`, registered under `hooks.before_usespec`) that passes it a source reference and uses the returned content itself. This command has no opinion on what the caller does with it.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty). When dispatched as a hook, this is the source text the calling command forwards — treat it the same as if the user had typed it directly. Do nothing and report no match when the input has no Confluence reference — see below.

## Recognized References

A Confluence reference is either:

- A full page URL, e.g. `https://yourteam.atlassian.net/wiki/spaces/ENG/pages/123456789/Checkout+Redesign` or a shortlink `https://yourteam.atlassian.net/wiki/x/AbCdEf` — recognize it by the path containing `/wiki/spaces/.../pages/` or `/wiki/x/`.
- The shorthand `confluence:<pageId>` (e.g. `confluence:123456789`).

If the input contains neither form anywhere in the text, there is nothing to fetch — report that in one line (equivalent to `matched: false`) and stop. Do not treat plain prose as a reference just because it mentions "Confluence" or "wiki" — only an actual URL or the explicit shorthand counts.

## Execution

1. **Check tool availability**: If the `getConfluenceContent` tool (from the `atlassian` MCP server) is not available in this session, the Atlassian MCP server isn't connected. Tell the user once: "The Atlassian MCP server isn't connected, so I can't fetch this Confluence page — see https://github.com/atlassian/atlassian-mcp-server for setup." Report this the same way as a `matched: true` fetch error (see below) so a calling command's manual-paste fallback kicks in, and stop. Do not treat this as a hard failure.
2. **Call the tool**: With a recognized reference, call `getConfluenceContent`:
   - Full URL form: pass the URL itself as the content locator (the tool accepts a page by ID or URL directly — do not try to parse out a page ID yourself).
   - Shorthand form: pass the extracted `<pageId>` as the content ID.
3. **On a tool error** (not found, no access, auth expired, etc.): report it as a `matched: true` fetch error — do **not** fabricate content and do not fall back to treating the raw reference string (the URL/shorthand) as if it were the page's content. Suggest checking the link and the MCP server's connection/permissions.
4. **On success**: the tool returns the page's title, body, and its own Confluence content ID (needed for step 5). Treat this as `matched: true` with `title`/`content`/`sourceUrl`/`fetchedAt`, matching the `docsync` extension's `before_usespec` JSON contract even though this one has no script to literally emit JSON.
5. **Fetch direct child pages** (bounded, best-effort — a failure here never invalidates the step-4 result, which already stands on its own):
   - Call `searchConfluence` with CQL `parent = <pageId> and type = page`, where `<pageId>` is the content ID from step 4 (`parent =` returns direct children only — use `ancestor =` never, since that returns the entire recursive subtree, not what this command does).
   - Limit to the first 20 results; if more exist, note that the children list is truncated.
   - For each result, call `getConfluenceContent` to get its full body (search results are lightweight — title/excerpt/URL, not the full page). Skip any child that errors rather than failing the whole command.
   - Collect these as `children`: a list of `{title, content, sourceUrl}` per child, alongside a `childrenTruncated` flag, per the `docsync` extension's contract.
6. **Report the result**. If invoked standalone, print the root page under a clear heading as a preview, followed by one line per child fetched:

   ```markdown
   ## Fetched from Confluence

   **Source**: {page URL}
   **Title**: {title}

   {content}

   ### Child pages fetched
   - {child title} — {child sourceUrl}
   ```

   If invoked as a hook, the calling command already has what it needs (`title`/`content`/`sourceUrl`/`fetchedAt`/`children`/`childrenTruncated`) and decides what to do with it — this command's job ends here.

## Optional: Searching Instead of a Direct Link

If the user explicitly asks to search Confluence by topic rather than give a link (e.g. "search Confluence for the page about checkout redesign"), you may use `searchConfluence` (CQL) to find candidates, then show the top matches to the user and ask them to confirm which one before fetching it with `getConfluenceContent`. Never auto-select a search result without that confirmation — unlike a pasted URL, a keyword search can return the wrong page. This path is not part of the automatic `before_usespec` hook; it only applies when the user clearly asked you to search, typically by running this command standalone.
