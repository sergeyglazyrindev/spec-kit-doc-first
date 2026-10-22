# spec-kit-doc-first

Spec Kit extensions for a doc-first workflow: treat an external wiki page as
the source of truth for a feature spec, instead of hand-copying it and
letting the copy drift.

This was originally prototyped as two core [Spec Kit](https://github.com/github/spec-kit)
commands. It's built here as standalone extensions instead, so it can ship
and version independently of core.

## Extensions

| Extension | Provides | Depends on |
| --- | --- | --- |
| [`docsync`](extensions/docsync) | `speckit.docsync.usespec`, `speckit.docsync.refreshspec` | A `before_usespec` fetch integration (see below) |
| [`confluence`](extensions/confluence) | `speckit.confluence.fetch` — a `before_usespec` hook for Confluence Cloud pages, via the Atlassian MCP server | `docsync` |

## Setup

`specify extension add` can install an extension two ways: `--dev <path>`
from a local directory, or `--from <url>` from a downloaded archive (zip or
tar.gz) containing exactly one extension — either `extension.yml` at the
archive's root, or inside a single top-level folder.

This repo bundles multiple extensions side by side in one Git repository,
and GitHub doesn't offer a way to download just one subdirectory as an
archive (a repo zip/tarball always contains the whole repo, with all
extensions as sibling folders) — so **`--from` a raw GitHub URL won't work
here**. Clone the repo first, then install from local paths with `--dev`:

```bash
git clone https://github.com/sergeyglazyrindev/spec-kit-doc-first.git
cd spec-kit-doc-first

specify extension add --dev extensions/docsync
specify extension add --dev extensions/confluence
```

(`--from` would work if you instead point it at a packaged archive holding
just one extension — e.g. a zip attached to a GitHub Release for that
extension alone — but no such release archives are published for this repo
today.)

See each extension's own README for configuration details, and
`extensions/docsync/README.md` for how the fetch contract and hook events
work.

## License

MIT — see [LICENSE](LICENSE).
