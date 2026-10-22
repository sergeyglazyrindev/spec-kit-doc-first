#!/usr/bin/env bash
# Docmost extension: fetch-docmost-page.sh
#
# Detects a Docmost page reference (a full page URL containing "/p/", or the
# "docmost:<pageId>" shorthand) anywhere in a free-text input string, fetches
# that page from the Docmost REST API (POST /api/pages/info, format=markdown)
# plus its direct child pages (POST /api/pages/sidebar-pages, which filters
# by parentPageId -- direct children only, not the full subtree), and prints
# one JSON object to stdout. Always exits 0 when no reference is found
# (matched:false) so callers can treat that as a harmless no-op; exits 1 on
# any fetch failure once a reference was recognized (matched:true,
# error:<code>, message:<detail>).
#
# Usage: fetch-docmost-page.sh [--json] "<input text>"
# (--json is accepted for convention parity with other Spec Kit scripts;
# output is always JSON.)

set -e

MAX_CHILDREN=20

INPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --json) ;;
        --) shift; break ;;
        *) INPUT="$1" ;;
    esac
    shift
done

has_jq() { command -v jq >/dev/null 2>&1; }
has_py() { command -v python3 >/dev/null 2>&1; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

emit_no_match() {
    echo '{"matched":false}'
    exit 0
}

emit_error() {
    local code="$1" message="$2"
    if has_jq; then
        jq -cn --arg c "$code" --arg m "$message" '{matched:true, error:$c, message:$m}'
    else
        printf '{"matched":true,"error":"%s","message":"%s"}\n' "$(json_escape "$code")" "$(json_escape "$message")"
    fi
    exit 1
}

# --- 1. Detect a Docmost reference anywhere in the input -------------------

MATCH_KIND=""
CANDIDATE_URL=""
SHORTHAND_ID=""

URL_REGEX='(https?://[^"[:space:]]+)'
if [[ "$INPUT" =~ $URL_REGEX ]]; then
    CANDIDATE_URL="${BASH_REMATCH[1]}"
    # Trim one trailing punctuation character a sentence may have glued on.
    CANDIDATE_URL="${CANDIDATE_URL%[),.\!?\"\']}"
fi

if [[ -n "$CANDIDATE_URL" && "$CANDIDATE_URL" == */p/* ]]; then
    MATCH_KIND="url"
else
    SHORTHAND_REGEX='docmost:([A-Za-z0-9_-]+)'
    if [[ "$INPUT" =~ $SHORTHAND_REGEX ]]; then
        MATCH_KIND="shorthand"
        SHORTHAND_ID="${BASH_REMATCH[1]}"
    fi
fi

[ -z "$MATCH_KIND" ] && emit_no_match

# --- 2. Resolve pageId + base URL from the match ----------------------------

PAGE_ID=""
BASE_URL=""
SOURCE_URL=""

if [ "$MATCH_KIND" = "url" ]; then
    if [[ "$CANDIDATE_URL" =~ ^(https?://[^/]+) ]]; then
        BASE_URL="${BASH_REMATCH[1]}"
    fi
    AFTER_P="${CANDIDATE_URL#*/p/}"
    SEGMENT="${AFTER_P%%[/?#]*}"
    if [[ "$SEGMENT" == *-* ]]; then
        PAGE_ID="${SEGMENT##*-}"
    else
        PAGE_ID="$SEGMENT"
    fi
    SOURCE_URL="$CANDIDATE_URL"
else
    PAGE_ID="$SHORTHAND_ID"
fi

[ -z "$PAGE_ID" ] && emit_error "invalid_reference" "Found a Docmost reference but could not extract a page ID from it."

# --- 3. Load extension config (base_url default, token env var name) -------

find_specify_root() {
    local dir="$1" prev=""
    while true; do
        [ -d "$dir/.specify" ] && { echo "$dir"; return 0; }
        [ "$dir" = "/" ] && break
        [ "$dir" = "$prev" ] && break
        prev="$dir"
        dir="$(dirname "$dir")"
    done
    return 1
}

PROJECT_ROOT=$(find_specify_root "$(pwd)") || PROJECT_ROOT=""
CONFIG_FILE="$PROJECT_ROOT/.specify/extensions/docmost/docmost-config.yml"

read_config_value() {
    local key="$1" file="$2"
    [ -f "$file" ] || return 0
    grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null \
        | head -n1 \
        | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/^"(.*)"$/\1/' \
        | sed -E "s/^'(.*)'\$/\1/"
}

if [ "$MATCH_KIND" = "shorthand" ]; then
    BASE_URL=$(read_config_value "base_url" "$CONFIG_FILE")
fi
[ -z "$BASE_URL" ] && [ "$MATCH_KIND" = "shorthand" ] && \
    emit_error "missing_base_url" "Set base_url in .specify/extensions/docmost/docmost-config.yml, or paste the full Docmost page URL instead of the docmost:<id> shorthand."

BASE_URL="${BASE_URL%/}"
[ -z "$SOURCE_URL" ] && SOURCE_URL="${BASE_URL}/p/${PAGE_ID}"

TOKEN_ENV=$(read_config_value "api_token_env" "$CONFIG_FILE")
[ -z "$TOKEN_ENV" ] && TOKEN_ENV="DOCMOST_API_TOKEN"
if [[ ! "$TOKEN_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    emit_error "invalid_config" "api_token_env in docmost-config.yml ('$TOKEN_ENV') is not a valid environment variable name."
fi

TOKEN="${!TOKEN_ENV:-}"
[ -z "$TOKEN" ] && emit_error "missing_token" "Set the \$$TOKEN_ENV environment variable to a Docmost API token (create one in Docmost under Settings > API tokens)."

command -v curl >/dev/null 2>&1 || emit_error "network_error" "curl is not available; install curl or use the python script variant of this command."

# fetch_page_info PAGE_ID_OR_SLUG -> prints "HTTP_STATUS\nHTTP_BODY" (two lines)
fetch_page_info() {
    local id="$1" body status resp
    body=$(printf '{"pageId":"%s","format":"markdown"}' "$(json_escape "$id")")
    resp=$(curl -sS -w '\n%{http_code}' -X POST "${BASE_URL}/api/pages/info" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "$body" 2>&1) || return 1
    status="${resp##*$'\n'}"
    [[ "$status" =~ ^[0-9]{3}$ ]] || return 1
    printf '%s\n%s' "$status" "${resp%$'\n'*}"
}

# --- 4. Fetch the root page --------------------------------------------------

if ! ROOT_RESP=$(fetch_page_info "$PAGE_ID"); then
    emit_error "network_error" "Could not reach $BASE_URL."
fi
HTTP_STATUS="${ROOT_RESP%%$'\n'*}"
HTTP_BODY="${ROOT_RESP#*$'\n'}"

if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    SNIPPET=$(printf '%s' "$HTTP_BODY" | head -c 300)
    emit_error "http_${HTTP_STATUS}" "Docmost returned HTTP ${HTTP_STATUS}: ${SNIPPET}"
fi

# --- 5. Extract title + markdown content + the real page UUID --------------
# sidebar-pages (step 6) filters by parentPageId, which stores the page's
# UUID -- not its slugId -- so we need the UUID even when PAGE_ID (from the
# URL/shorthand) was a slugId.

TITLE=""
CONTENT=""
ROOT_UUID=""
if has_jq; then
    TITLE=$(printf '%s' "$HTTP_BODY" | jq -r '.title // .page.title // .data.title // empty' 2>/dev/null || true)
    CONTENT=$(printf '%s' "$HTTP_BODY" | jq -r '.content // .page.content // .data.content // empty' 2>/dev/null || true)
    ROOT_UUID=$(printf '%s' "$HTTP_BODY" | jq -r '.id // .page.id // .data.id // empty' 2>/dev/null || true)
elif has_py; then
    _extract_field() {
        printf '%s' "$HTTP_BODY" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for path in (('$1',), ('page', '$1'), ('data', '$1')):
    v = d
    for k in path:
        v = v.get(k) if isinstance(v, dict) else None
    if isinstance(v, str):
        print(v)
        break
" 2>/dev/null || true
    }
    TITLE=$(_extract_field title)
    CONTENT=$(_extract_field content)
    ROOT_UUID=$(_extract_field id)
fi

[ -z "$CONTENT" ] && emit_error "empty_content" "Docmost responded but no page content was found in the response body."

# --- 6. Fetch direct child pages (bounded, best-effort) ---------------------
# A failure here never fails the whole command -- the root page already
# succeeded and is usable on its own.

CHILDREN_JSON="[]"
CHILDREN_TRUNCATED="false"

if [ -n "$ROOT_UUID" ] && { has_jq || has_py; }; then
    SIDEBAR_BODY=$(printf '{"pageId":"%s","limit":%d}' "$(json_escape "$ROOT_UUID")" "$MAX_CHILDREN")
    if SIDEBAR_RESP=$(curl -sS -w '\n%{http_code}' -X POST "${BASE_URL}/api/pages/sidebar-pages" \
            -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            -d "$SIDEBAR_BODY" 2>/dev/null); then
        SIDEBAR_STATUS="${SIDEBAR_RESP##*$'\n'}"
        SIDEBAR_BODY_JSON="${SIDEBAR_RESP%$'\n'*}"
        if [[ "$SIDEBAR_STATUS" =~ ^2[0-9]{2}$ ]]; then
            CHILD_LIST=""
            if has_jq; then
                CHILD_LIST=$(printf '%s' "$SIDEBAR_BODY_JSON" | jq -r '.items[]? | [.id, .title] | @tsv' 2>/dev/null || true)
                CHILDREN_TRUNCATED=$(printf '%s' "$SIDEBAR_BODY_JSON" | jq -r 'if (.meta.hasNextPage // false) then "true" else "false" end' 2>/dev/null || echo false)
            else
                CHILD_LIST=$(printf '%s' "$SIDEBAR_BODY_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in d.get("items", []) or []:
    print("{}\t{}".format(item.get("id", ""), item.get("title", "") or ""))
' 2>/dev/null || true)
                CHILDREN_TRUNCATED=$(printf '%s' "$SIDEBAR_BODY_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("true" if (d.get("meta") or {}).get("hasNextPage") else "false")
except Exception:
    print("false")
' 2>/dev/null || echo false)
            fi

            CHILD_OBJECTS=()
            if [ -n "$CHILD_LIST" ]; then
                while IFS=$'\t' read -r CHILD_ID CHILD_TITLE; do
                    [ -z "$CHILD_ID" ] && continue
                    if CHILD_RESP=$(fetch_page_info "$CHILD_ID"); then
                        CHILD_STATUS="${CHILD_RESP%%$'\n'*}"
                        CHILD_BODY_JSON="${CHILD_RESP#*$'\n'}"
                        if [[ "$CHILD_STATUS" =~ ^2[0-9]{2}$ ]]; then
                            CHILD_CONTENT=""
                            if has_jq; then
                                CHILD_CONTENT=$(printf '%s' "$CHILD_BODY_JSON" | jq -r '.content // empty' 2>/dev/null || true)
                            else
                                CHILD_CONTENT=$(printf '%s' "$CHILD_BODY_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("content") or "")
except Exception:
    pass
' 2>/dev/null || true)
                            fi
                            if [ -n "$CHILD_CONTENT" ]; then
                                CHILD_SOURCE_URL="${BASE_URL}/p/${CHILD_ID}"
                                if has_jq; then
                                    CHILD_OBJECTS+=("$(jq -cn --arg title "$CHILD_TITLE" --arg content "$CHILD_CONTENT" \
                                        --arg pageId "$CHILD_ID" --arg sourceUrl "$CHILD_SOURCE_URL" \
                                        '{title: $title, content: $content, pageId: $pageId, sourceUrl: $sourceUrl}')")
                                else
                                    CHILD_OBJECTS+=("$(python3 -c '
import json, sys
print(json.dumps({"title": sys.argv[1], "content": sys.argv[2], "pageId": sys.argv[3], "sourceUrl": sys.argv[4]}))
' "$CHILD_TITLE" "$CHILD_CONTENT" "$CHILD_ID" "$CHILD_SOURCE_URL")")
                                fi
                            fi
                        fi
                    fi
                done <<< "$CHILD_LIST"
            fi

            if [ "${#CHILD_OBJECTS[@]}" -gt 0 ]; then
                if has_jq; then
                    CHILDREN_JSON=$(printf '%s\n' "${CHILD_OBJECTS[@]}" | jq -cs '.')
                else
                    CHILDREN_JSON=$(printf '%s\n' "${CHILD_OBJECTS[@]}" | python3 -c '
import json, sys
items = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps(items))
')
                fi
            fi
        fi
        # A non-2xx sidebar-pages response (older Docmost without this route,
        # permission error, etc.) is silently treated as "no children found" --
        # the root page fetch already succeeded and stands on its own.
    fi
fi

# --- 7. Emit the final result -----------------------------------------------

FETCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if has_jq; then
    jq -cn --arg title "$TITLE" --arg content "$CONTENT" --arg pageId "$PAGE_ID" \
        --arg sourceUrl "$SOURCE_URL" --arg fetchedAt "$FETCHED_AT" \
        --argjson children "$CHILDREN_JSON" \
        --argjson childrenTruncated "$CHILDREN_TRUNCATED" \
        '{matched: true, title: $title, content: $content, pageId: $pageId, sourceUrl: $sourceUrl, fetchedAt: $fetchedAt, children: $children, childrenTruncated: $childrenTruncated}'
elif has_py; then
    python3 -c '
import json, sys
title, content, pageId, sourceUrl, fetchedAt, children_json, truncated = sys.argv[1:8]
children = json.loads(children_json) if children_json else []
print(json.dumps({
    "matched": True, "title": title, "content": content, "pageId": pageId,
    "sourceUrl": sourceUrl, "fetchedAt": fetchedAt, "children": children,
    "childrenTruncated": truncated == "true",
}))
' "$TITLE" "$CONTENT" "$PAGE_ID" "$SOURCE_URL" "$FETCHED_AT" "$CHILDREN_JSON" "$CHILDREN_TRUNCATED"
else
    printf '{"matched":true,"title":"%s","content":"%s","pageId":"%s","sourceUrl":"%s","fetchedAt":"%s","children":[],"childrenTruncated":false}\n' \
        "$(json_escape "$TITLE")" "$(json_escape "$CONTENT")" "$(json_escape "$PAGE_ID")" \
        "$(json_escape "$SOURCE_URL")" "$FETCHED_AT"
fi
