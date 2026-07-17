#!/bin/bash
# find-session.sh — resolve a session id (or the short id shown by `just log`)
# to everything `just resume` needs to reopen it.
#
# Usage: find-session.sh <id-or-prefix>
# Output: one TAB-separated line on stdout: <clone-name>\t<cwd>\t<full-session-id>
#   clone-name — the pool clone the session lives in (what resume claims).
#   cwd        — the directory the session was launched from, read from the
#                session log itself (so a monorepo subdir cwd is preserved
#                exactly, with no lossy dir-name decoding). Falls back to the
#                clone root if the log records no cwd or it no longer exists.
#   full-id    — the complete session id to hand to `claude --resume`.
#
# Read-only — never claims or mutates. This is the single source of truth for
# "given an id from the log, where do I resume it and as what?", so resume and
# its tests share one resolver. Exits 2 on usage error, 1 when zero or several
# sessions match (candidates listed on stderr so you can disambiguate).

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $# -ge 1 && -n "${1:-}" ]] || { echo "usage: find-session.sh <id-or-prefix>" >&2; exit 2; }
query="$1"

# The cwd a session was launched from: the first record carrying a "cwd" field.
# Best-effort string parse, matching the no-jq style of the other readers; an
# unparseable log degrades to empty rather than failing.
session_cwd() {
    local file="$1" line cwd
    line=$(grep -m1 -F '"cwd":"' "$file" 2>/dev/null)
    [[ -n "$line" ]] || return 0
    cwd=$(sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' <<<"$line")
    # Unescape the JSON escapes a filesystem path can realistically carry.
    cwd=${cwd//\\\//\/}
    cwd=${cwd//\\\\/\\}
    printf '%s' "$cwd"
}

# Collect every session whose id starts with the query, as "id\tclone" lines.
# UUID/short ids contain no glob metacharacters, so the prefix case is literal.
matches=()
while IFS= read -r path; do
    name=$(basename "${path%/}")
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        file="${line#* }"
        id="${file##*/}"; id="${id%.jsonl}"
        case "$id" in
            "$query"*) matches+=("$id"$'\t'"$name") ;;
        esac
    done < <(claude_clone_session_files "$path")
done < <(spork_clones)

if (( ${#matches[@]} == 0 )); then
    echo "No session matching '$query' in any clone under $BASE_DIR." >&2
    echo "Run \`just log\` to see available session ids." >&2
    exit 1
fi

# Resolve to one. An exact full-id match wins even if it's also a prefix of
# other ids, so a complete id is never ambiguous; otherwise a unique prefix
# resolves, and a non-unique one lists its candidates.
chosen=""
if (( ${#matches[@]} == 1 )); then
    chosen="${matches[0]}"
else
    for m in "${matches[@]}"; do
        if [[ "${m%%$'\t'*}" == "$query" ]]; then chosen="$m"; break; fi
    done
    if [[ -z "$chosen" ]]; then
        echo "'$query' matches ${#matches[@]} sessions — use more characters:" >&2
        for m in "${matches[@]}"; do
            printf '  %s  (%s)\n' "${m%%$'\t'*}" "${m#*$'\t'}" >&2
        done
        exit 1
    fi
fi

id="${chosen%%$'\t'*}"
name="${chosen#*$'\t'}"
clone_path="$BASE_DIR/$name"

# Re-find the matched file's full path to read its cwd (cheaper than threading
# it through the match list, and there's only one survivor now).
file=""
shopt -s nullglob
for dir in "$CLAUDE_PROJECTS_DIR/${clone_path//\//-}" "$CLAUDE_PROJECTS_DIR/${clone_path//\//-}"-*; do
    [[ -f "$dir/$id.jsonl" ]] && { file="$dir/$id.jsonl"; break; }
done
shopt -u nullglob

cwd=""
[[ -n "$file" ]] && cwd=$(session_cwd "$file")
# Fall back to the clone root when the log records no cwd or it's since gone
# (resume-by-id still locates the session; cwd only sets the working tree).
[[ -n "$cwd" && -d "$cwd" ]] || cwd="$clone_path"
[[ -d "$cwd" ]] || { echo "Clone dir for session $id no longer exists: $cwd" >&2; exit 1; }

printf '%s\t%s\t%s\n' "$name" "$cwd" "$id"
