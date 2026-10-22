#!/usr/bin/env python3
"""Docmost extension: fetch_docmost_page.py

Detects a Docmost page reference (a full page URL containing "/p/", or the
"docmost:<pageId>" shorthand) anywhere in a free-text input string, fetches
that page from the Docmost REST API (POST /api/pages/info, format=markdown)
plus its direct child pages (POST /api/pages/sidebar-pages, which filters by
parentPageId -- direct children only, not the full subtree), and prints one
JSON object to stdout.

Always exits 0 when no reference is found ({"matched": false}) so callers can
treat that as a harmless no-op. Exits 1 on any fetch failure once a reference
was recognized ({"matched": true, "error": "<code>", "message": "<detail>"}).

Usage: fetch_docmost_page.py [--json] "<input text>"
(--json is accepted for convention parity with other Spec Kit scripts;
output is always JSON.)
"""

import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

URL_RE = re.compile(r'(https?://[^\s"\']+)')
SHORTHAND_RE = re.compile(r"docmost:([A-Za-z0-9_-]+)")
MAX_CHILDREN = 20


def emit_no_match() -> None:
    print(json.dumps({"matched": False}))
    sys.exit(0)


def emit_error(code: str, message: str) -> None:
    print(json.dumps({"matched": True, "error": code, "message": message}))
    sys.exit(1)


def find_specify_root(start: Path) -> Path | None:
    current = start.resolve()
    while True:
        if (current / ".specify").is_dir():
            return current
        if current.parent == current:
            return None
        current = current.parent


def read_config_value(key: str, config_file: Path) -> str:
    if not config_file.is_file():
        return ""
    pattern = re.compile(rf'^\s*{re.escape(key)}:\s*(.*)\s*$')
    for line in config_file.read_text(encoding="utf-8").splitlines():
        m = pattern.match(line)
        if m:
            value = m.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return ""


def extract_first_value(data, keys) -> str:
    for path in (keys, ("page", keys[0]), ("data", keys[0])):
        node = data
        ok = True
        for k in path:
            if isinstance(node, dict) and k in node:
                node = node[k]
            else:
                ok = False
                break
        if ok and isinstance(node, str):
            return node
    return ""


def call_api(base_url: str, token: str, path: str, payload: dict):
    """POST to the Docmost API. Returns (status, parsed_json_or_none, raw_text)."""
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url}{path}",
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read().decode("utf-8", errors="replace")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = None
    return status, parsed, raw


def fetch_children(base_url: str, token: str, root_uuid: str):
    """Fetch direct children of root_uuid. Best-effort: any failure here just
    means no children are returned -- the root page fetch already succeeded
    and stands on its own. Returns (children, truncated)."""
    try:
        status, parsed, _ = call_api(
            base_url, token, "/api/pages/sidebar-pages",
            {"pageId": root_uuid, "limit": MAX_CHILDREN},
        )
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return [], False

    if status < 200 or status >= 300 or not isinstance(parsed, dict):
        return [], False

    items = parsed.get("items") or []
    truncated = bool((parsed.get("meta") or {}).get("hasNextPage"))

    children = []
    for item in items:
        child_id = item.get("id")
        child_title = item.get("title") or ""
        if not child_id:
            continue
        try:
            c_status, c_parsed, _ = call_api(
                base_url, token, "/api/pages/info",
                {"pageId": child_id, "format": "markdown"},
            )
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            continue
        if c_status < 200 or c_status >= 300 or not isinstance(c_parsed, dict):
            continue
        child_content = extract_first_value(c_parsed, ("content",))
        if not child_content:
            continue
        children.append({
            "title": child_title,
            "content": child_content,
            "pageId": child_id,
            "sourceUrl": f"{base_url}/p/{child_id}",
        })
    return children, truncated


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--json"]
    input_text = args[-1] if args else ""

    url_match = URL_RE.search(input_text)
    candidate_url = url_match.group(1).rstrip(")],.!?\"'") if url_match else ""

    match_kind = None
    shorthand_id = ""
    if candidate_url and "/p/" in candidate_url:
        match_kind = "url"
    else:
        shorthand_match = SHORTHAND_RE.search(input_text)
        if shorthand_match:
            match_kind = "shorthand"
            shorthand_id = shorthand_match.group(1)

    if match_kind is None:
        emit_no_match()

    page_id = ""
    base_url = ""
    source_url = ""

    if match_kind == "url":
        host_match = re.match(r"^(https?://[^/]+)", candidate_url)
        base_url = host_match.group(1) if host_match else ""
        after_p = candidate_url.split("/p/", 1)[1]
        segment = re.split(r"[/?#]", after_p, maxsplit=1)[0]
        page_id = segment.rsplit("-", 1)[-1] if "-" in segment else segment
        source_url = candidate_url
    else:
        page_id = shorthand_id

    if not page_id:
        emit_error("invalid_reference", "Found a Docmost reference but could not extract a page ID from it.")

    project_root = find_specify_root(Path.cwd())
    config_file = (
        project_root / ".specify" / "extensions" / "docmost" / "docmost-config.yml"
        if project_root
        else Path("/nonexistent")
    )

    if match_kind == "shorthand":
        base_url = read_config_value("base_url", config_file)
        if not base_url:
            emit_error(
                "missing_base_url",
                "Set base_url in .specify/extensions/docmost/docmost-config.yml, "
                "or paste the full Docmost page URL instead of the docmost:<id> shorthand.",
            )

    base_url = base_url.rstrip("/")
    if not source_url:
        source_url = f"{base_url}/p/{page_id}"

    token_env = read_config_value("api_token_env", config_file) or "DOCMOST_API_TOKEN"
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", token_env):
        emit_error(
            "invalid_config",
            f"api_token_env in docmost-config.yml ('{token_env}') is not a valid environment variable name.",
        )

    import os

    token = os.environ.get(token_env, "")
    if not token:
        emit_error(
            "missing_token",
            f"Set the ${token_env} environment variable to a Docmost API token "
            "(create one in Docmost under Settings > API tokens).",
        )

    try:
        status, data, response_body = call_api(
            base_url, token, "/api/pages/info", {"pageId": page_id, "format": "markdown"}
        )
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        emit_error("network_error", f"Could not reach {base_url}: {exc}")
        return

    if status < 200 or status >= 300:
        snippet = response_body[:300]
        emit_error(f"http_{status}", f"Docmost returned HTTP {status}: {snippet}")

    if data is None:
        emit_error("invalid_response", "Docmost returned a response that was not valid JSON.")
        return

    title = extract_first_value(data, ("title",))
    content = extract_first_value(data, ("content",))
    root_uuid = extract_first_value(data, ("id",))

    if not content:
        emit_error("empty_content", "Docmost responded but no page content was found in the response body.")

    children, children_truncated = ([], False)
    if root_uuid:
        children, children_truncated = fetch_children(base_url, token, root_uuid)

    result = {
        "matched": True,
        "title": title,
        "content": content,
        "pageId": page_id,
        "sourceUrl": source_url,
        "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "children": children,
        "childrenTruncated": children_truncated,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
