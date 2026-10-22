---
description: "Fetch a Docmost page referenced in the input and output its content as Markdown"
---

# Fetch Content From Docmost

Resolve a Docmost page reference found in the input into Markdown content, plus its **direct child pages** (one level — not the full subtree, and not links found inside the page body). This command only reads from Docmost — it never writes to any file itself. It can be run two ways:

- **Standalone**, as a preview: the user runs `/speckit.docmost.fetch <url>` directly to see a page's content.
- **As a hook**, dispatched by another command (currently `speckit.docsync.usespec` / `speckit.docsync.refreshspec`, registered under `hooks.before_usespec`) that passes it a source reference and uses the returned JSON itself. This command has no opinion on what the caller does with the result.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty). When dispatched as a hook, this is the source text the calling command forwards — treat it the same as if the user had typed it directly.

## Recognized References

A Docmost reference is either:

- A full page URL whose path contains `/p/`, e.g. `https://docmost.example.com/s/engineering/p/checkout-redesign-t7i4wXav8l`
- The shorthand `docmost:<pageId>` (e.g. `docmost:t7i4wXav8l`), which requires `base_url` to be set in `.specify/extensions/docmost/docmost-config.yml`

If the input contains neither form anywhere in the text, there is nothing to fetch — this is the expected case for ordinary free text. Do not treat plain prose as a reference just because it mentions "docmost" or "wiki".

## Execution

Run the script for your platform, passing the **entire** input text as a single quoted argument (the script does its own reference detection and extracts the reference from surrounding text):

- **Bash**: `.specify/extensions/docmost/scripts/bash/fetch-docmost-page.sh --json "<input text>"`
- **PowerShell**: `.specify/extensions/docmost/scripts/powershell/fetch-docmost-page.ps1 -Json "<input text>"`
- **Python**: `.specify/extensions/docmost/scripts/python/fetch_docmost_page.py --json "<input text>"`

For single quotes inside the input, use the same escaping convention as other Spec Kit commands: `'I'\''m Groot'` (or switch to double quotes when possible).

The script prints one JSON object to stdout:

| Field | Meaning |
| --- | --- |
| `matched` | `false` when no Docmost reference was found in the input — the rest of the fields are absent; do not report this as an error. |
| `error` | Present only when `matched: true` and the fetch failed (`missing_token`, `missing_base_url`, an `http_<status>` code, or `network_error`). `message` carries the human-readable detail. |
| `title` | The page's title (on success). |
| `content` | The page body converted to Markdown (on success). |
| `pageId` | The resolved page ID / slugId that was queried. |
| `sourceUrl` | The page URL that was fetched (reconstructed from `base_url` + `pageId` when the shorthand form was used). |
| `fetchedAt` | ISO-8601 UTC timestamp of the fetch. |
| `children` | Array of `{title, content, pageId, sourceUrl}` for the page's **direct children only** (up to 20) — empty if the page has none, or if the children fetch itself failed (that never fails the overall result; the root page already succeeded). |
| `childrenTruncated` | `true` if the page has more than 20 direct children and some were left out. |

## Handling the Result

1. **`matched: false`** — Report in one line that no Docmost reference was found in the input, and stop. If dispatched as a hook, the calling command's JSON parse of this result is enough; nothing further is needed here.
2. **`matched: true` with `error`** — Show the `message` to the user. Do **not** fabricate content and do not fall back to treating the raw reference string (the URL/shorthand) as if it were the page's content. Common cases:
   - `missing_token`: tell the user which environment variable to set (from `api_token_env` in the config, default `DOCMOST_API_TOKEN`) and that the token is created in Docmost under Settings → API tokens.
   - `missing_base_url`: tell the user to either set `base_url` in `.specify/extensions/docmost/docmost-config.yml`, or paste the full page URL instead of the `docmost:<id>` shorthand.
   - `http_401` / `http_403`: the token is invalid, expired, or lacks access to that page/space.
   - `http_404`: the page ID was not found — the URL or shorthand ID is likely wrong.
3. **Success** — If invoked standalone, print the result under a clear heading as a preview, including any children:

   ```markdown
   ## Fetched from Docmost

   **Source**: {sourceUrl}
   **Title**: {title}

   {content}

   ### Child pages fetched
   - {child title} — {child sourceUrl}
   ```

   Omit the "Child pages fetched" section entirely if `children` is empty. Note `childrenTruncated: true` to the user if present, so they know more children exist than were fetched.

   If invoked as a hook, the calling command already has everything from the JSON result and decides what to do with it — this command's job ends here.

## Graceful Degradation

If `curl`/`python3` (per platform) or network access to the Docmost instance is unavailable, the script reports a `network_error`. Relay that to whoever is handling the result (the user directly, or the calling command) rather than retrying silently.
