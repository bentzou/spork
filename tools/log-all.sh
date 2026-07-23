#!/bin/bash
# log-all.sh — recent agent sessions across the clone pool, newest first.
#
# A "session" is one Claude Code jsonl log. This lists them across every clone
# ordered by last activity, so you can see what you worked on and where —
# including sessions you've already closed out of (every session leaves its log
# behind, so closed and live ones rank side by side).
#
# Read-only: reads session mtimes and titles, never the repos. Same session
# source and dir-encoding rules as the AGE/SESSION columns in `just status`.
#
# Usage: log-all.sh [--agent AGENT] [N]
#   N most recent sessions (default 20; "all" = no limit).

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

agent_filter=""
if [[ "${1:-}" == "--agent" ]]; then
    agent_filter="${2:-}"
    agent_valid "$agent_filter" || { echo "Unknown agent '$agent_filter' (expected one of: $SPORK_AGENTS)." >&2; exit 2; }
    shift 2
fi

limit="${1:-20}"
if [[ "$limit" != "all" && ! "$limit" =~ ^[0-9]+$ ]]; then
    echo "usage: just log [N|all]   (N is a count; default 20)" >&2
    exit 2
fi

now=$(date +%s)

# Longest SESSION title rendered before truncation. The column is last, so this
# only bounds row length. A touch wider than the status table's cap: log rows
# carry fewer columns, so there's room for a fuller title.
SESSION_MAX=72

tmp=$(mktemp -d "${TMPDIR:-/tmp}/spork-log.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if [[ "$agent_filter" != "claude" ]]; then
    spork_session_inventory_build "$tmp/sessions"
    export SPORK_SESSION_INVENTORY_FILE="$tmp/sessions"
fi

# Gather "<mtime>\t<agent>\t<clone>\t<file>" for every session in every clone. Title
# parsing is deferred until after the global sort+truncate below, so we only
# grep the handful of logs we actually print — not every historical session.
# The tab framing lets `sort` key on the numeric mtime and the reader split
# cleanly even though a session title (added later) may contain spaces.
gather() {
    local path name agent line mtime file
    while IFS= read -r path; do
        name=$(basename "${path%/}")
        for agent in $SPORK_AGENTS; do
            [[ -n "$agent_filter" && "$agent" != "$agent_filter" ]] && continue
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                mtime="${line%% *}"
                file="${line#* }"
                printf '%s\t%s\t%s\t%s\n' "$mtime" "$agent" "$name" "$file"
            done < <(agent_clone_session_files "$agent" "$path")
        done
    done < <(spork_clones)
}

rows=$(gather | sort -rn)
if [[ "$limit" != "all" && -n "$rows" ]]; then
    rows=$(printf '%s\n' "$rows" | head -n "$limit")
fi

if [[ -z "$rows" ]]; then
    if [[ -n "$agent_filter" ]]; then
        echo "No $(agent_label "$agent_filter") sessions found for any clone under $BASE_DIR." >&2
    else
        echo "No agent sessions found for any clone under $BASE_DIR." >&2
    fi
    exit 0
fi

# Short session-id handle shown in the ID column and accepted by `just resume`.
# A UUID prefix this wide is unique across a realistic pool; resume matches by
# prefix and disambiguates if two ever collide.
ID_LEN=8

# Read survivors into parallel cells, parsing each title now, and track column
# widths. Order is preserved (newest first) from the sort above.
declare -a age_cells=() agent_cells=() rep_cells=() id_cells=() title_cells=() epoch_cells=()
rep_width=3   # min for "REP" header
agent_width=5 # min for "AGENT" header
age_width=3   # min for "AGE" header
id_width=2    # min for "ID" header
while IFS=$'\t' read -r mtime agent name file; do
    [[ -n "$mtime" ]] || continue
    age=$(format_relative $(( now - mtime )))
    agent_name=$(agent_label "$agent")
    id=$(agent_session_id "$agent" "$file")
    id="${id:0:ID_LEN}"
    title=$(agent_session_title "$agent" "$file")
    [[ -z "$title" ]] && title="—"
    (( ${#title} > SESSION_MAX )) && title="${title:0:SESSION_MAX-1}…"

    age_cells+=("$age")
    agent_cells+=("$agent_name")
    rep_cells+=("$name")
    id_cells+=("$id")
    title_cells+=("$title")
    epoch_cells+=("$mtime")

    (( ${#name} > rep_width )) && rep_width=${#name}
    (( ${#agent_name} > agent_width )) && agent_width=${#agent_name}
    (( ${#age}  > age_width )) && age_width=${#age}
    (( ${#id}   > id_width ))  && id_width=${#id}
done <<< "$rows"

# A clone with a live claim has an agent session attached right now, so any of
# its sessions can't be cleanly resumed — `just resume` would refuse, since
# only one Claude can run per working tree. Mark those rows so you know before
# you reach for an id. Check occupancy once per distinct clone shown (a clone
# spans many rows), recorded in a space-delimited set membership-tested below;
# no extra clone enumeration, just a cheap live-PID probe per clone.
occupied_set=" " checked_set=" "
for name in "${rep_cells[@]}"; do
    [[ "$checked_set" == *" $name "* ]] && continue
    checked_set+="$name "
    clone_occupied "$BASE_DIR/$name" && occupied_set+="$name "
done

c_cyan='' c_yellow='' c_red='' c_reset=''
if [[ -t 1 ]]; then
    c_cyan=$'\033[36m'
    c_yellow=$'\033[33m'
    c_red=$'\033[31m'
    c_reset=$'\033[0m'
fi

# AGE goes red once a session hasn't been touched in a while — same threshold
# as the status table's stale marker.
STALE_THRESHOLD=$(( 7 * 86400 ))

printf '%-*s   %-*s   %-*s   %-*s   %s\n' \
    "$age_width" "AGE" "$agent_width" "AGENT" "$rep_width" "REP" "$id_width" "ID" "SESSION"

# Print AGE · REP · ID · SESSION. Padded columns precede the free-text SESSION;
# color codes wrap only the visible token, so they don't shift alignment. Rows
# whose clone is in use get a trailing "(in use)" marker (yellow on a tty,
# plain text otherwise so it survives piping) — resume will refuse those.
for i in "${!age_cells[@]}"; do
    age="${age_cells[$i]}"
    agent="${agent_cells[$i]}"
    rep="${rep_cells[$i]}"
    id="${id_cells[$i]}"
    title="${title_cells[$i]}"

    ac=""
    (( now - epoch_cells[i] >= STALE_THRESHOLD )) && ac="$c_red"

    marker=""
    [[ "$occupied_set" == *" $rep "* ]] && marker="   ${c_yellow}(in use)${c_reset}"

    pad_tail age_tail   "$age_width"   "$age"
    pad_tail agent_tail "$agent_width" "$agent"
    pad_tail rep_tail   "$rep_width"   "$rep"

    printf '%s%s%s%s   %s%s%s%s   %s%s%s%s   %-*s   %s%s\n' \
        "$ac" "$age" "$c_reset" "$age_tail" \
        "$c_cyan" "$agent" "$c_reset" "$agent_tail" \
        "$c_cyan" "$rep" "$c_reset" "$rep_tail" \
        "$id_width" "$id" \
        "$title" "$marker"
done
