#!/bin/bash
# find-session.sh — resolve a session id (or the short id shown by `just log`),
# or a clone name (its newest session), to everything `just resume` needs.
#
# Usage: find-session.sh [--agent AGENT] <id-or-prefix-or-clone-name>
# Output: one TAB-separated line:
#   <agent>\t<clone-name>\t<cwd>\t<full-session-id>

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

agent_filter=""
if [[ "${1:-}" == "--agent" ]]; then
    agent_filter="${2:-}"
    agent_valid "$agent_filter" || { echo "Unknown agent '$agent_filter' (expected one of: $SPORK_AGENTS)." >&2; exit 2; }
    shift 2
fi

[[ $# -ge 1 && -n "${1:-}" ]] || { echo "usage: find-session.sh [--agent AGENT] <id-or-prefix>" >&2; exit 2; }
query="$1"

match_agents() {
    local agent
    if [[ -n "$agent_filter" ]]; then
        printf '%s\n' "$agent_filter"
    else
        for agent in $SPORK_AGENTS; do printf '%s\n' "$agent"; done
    fi
}

matches=()
if [[ -d "$BASE_DIR/$query" && "$(clone_origin_url "$BASE_DIR/$query")" == "$ORIGIN_URL" ]]; then
    # The query names a pool clone: resume its newest session across the
    # selected agent set.
    best_agent="" best_file="" best_mtime=0
    while IFS= read -r agent; do
        file=$(agent_newest_session_file "$agent" "$BASE_DIR/$query")
        [[ -n "$file" ]] || continue
        mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
        if (( mtime > best_mtime )); then
            best_mtime="$mtime"
            best_agent="$agent"
            best_file="$file"
        fi
    done < <(match_agents)

    if [[ -z "$best_file" ]]; then
        if [[ -n "$agent_filter" ]]; then
            echo "No $(agent_label "$agent_filter") sessions recorded for clone '$query' — nothing to resume." >&2
        else
            echo "No sessions recorded for clone '$query' — nothing to resume." >&2
        fi
        echo "Run \`just log\` for sessions, or \`just claude\` / \`just codex\` to start fresh." >&2
        exit 1
    fi
    matches+=("$best_agent"$'\t'"$(agent_session_id "$best_agent" "$best_file")"$'\t'"$query"$'\t'"$best_file")
else
    # Collect every session whose id starts with the query, as
    # "agent\tid\tclone\tfile" lines. Exact full-id matches win below.
    while IFS= read -r path; do
        name=$(basename "${path%/}")
        while IFS= read -r agent; do
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                file="${line#* }"
                id=$(agent_session_id "$agent" "$file")
                case "$id" in
                    "$query"*) matches+=("$agent"$'\t'"$id"$'\t'"$name"$'\t'"$file") ;;
                esac
            done < <(agent_clone_session_files "$agent" "$path")
        done < <(match_agents)
    done < <(spork_clones)
fi

if (( ${#matches[@]} == 0 )); then
    echo "No session matching '$query' in any clone under $BASE_DIR." >&2
    echo "Run \`just log\` to see available session ids." >&2
    exit 1
fi

chosen=""
if (( ${#matches[@]} == 1 )); then
    chosen="${matches[0]}"
else
    for m in "${matches[@]}"; do
        rest="${m#*$'\t'}"
        id="${rest%%$'\t'*}"
        if [[ "$id" == "$query" ]]; then chosen="$m"; break; fi
    done
    if [[ -z "$chosen" ]]; then
        echo "'$query' matches ${#matches[@]} sessions — use more characters:" >&2
        for m in "${matches[@]}"; do
            agent="${m%%$'\t'*}"
            rest="${m#*$'\t'}"
            id="${rest%%$'\t'*}"
            clone_and_file="${rest#*$'\t'}"
            clone="${clone_and_file%%$'\t'*}"
            printf '  %s  (%s, %s)\n' "$id" "$clone" "$(agent_label "$agent")" >&2
        done
        exit 1
    fi
fi

agent="${chosen%%$'\t'*}"
rest="${chosen#*$'\t'}"
id="${rest%%$'\t'*}"
rest="${rest#*$'\t'}"
name="${rest%%$'\t'*}"
file="${rest#*$'\t'}"
clone_path="$BASE_DIR/$name"

cwd=$(agent_session_cwd "$agent" "$file")
[[ -n "$cwd" && -d "$cwd" ]] || cwd="$clone_path"
[[ -d "$cwd" ]] || { echo "Clone dir for session $id no longer exists: $cwd" >&2; exit 1; }

printf '%s\t%s\t%s\t%s\n' "$agent" "$name" "$cwd" "$id"
