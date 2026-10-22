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
| [`docmost`](extensions/docmost) | `speckit.docmost.fetch` — a `before_usespec` hook for [Docmost](https://docmost.com) pages | `docsync` |
| [`confluence`](extensions/confluence) | `speckit.confluence.fetch` — a `before_usespec` hook for Confluence Cloud pages, via the Atlassian MCP server | `docsync` |

Install `docsync` plus at least one fetch integration:

```bash
specify extension add --dev /path/to/spec-kit-doc-first/extensions/docsync
specify extension add --dev /path/to/spec-kit-doc-first/extensions/docmost
# and/or
specify extension add --dev /path/to/spec-kit-doc-first/extensions/confluence
```

See each extension's own README for setup details and `extensions/docsync/README.md`
for how the fetch contract and hook events work.

## License

MIT — see [LICENSE](LICENSE).
