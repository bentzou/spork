#!/bin/bash
# log-all.sh — recent agent sessions across the clone pool, newest first.
#
# A "session" is one logical agent session: one Claude Code jsonl, or one
# Codex session id (which may span several rollout files — Codex writes a new
# file per resume/fork, all carrying the original session_id; those collapse
# to a single row here). Ordered by last real interaction, so you can see
# what you worked on and where — including sessions you've already closed out
# of (every session leaves its log behind, so closed and live ones rank side
# by side).
#
# Read-only: reads session logs, never the repos. Same session source and
# dir-encoding rules as the AGE/SESSION columns in `just status`.
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

# Gather "<mtime>\t<agent>\t<clone>\t<id>\t<file>" for every session file in
# every clone. Title parsing and record-timestamp scans are deferred until
# after the global sort+dedupe+truncate below, so we only read the handful of
# logs we actually print — not every historical session.
gather() {
    local path name agent mtime id file
    while IFS= read -r path; do
        name=$(basename "${path%/}")
        for agent in $SPORK_AGENTS; do
            [[ -n "$agent_filter" && "$agent" != "$agent_filter" ]] && continue
            while IFS=$'\t' read -r mtime id file; do
                [[ -n "$mtime" ]] || continue
                printf '%s\t%s\t%s\t%s\t%s\n' "$mtime" "$agent" "$name" "$id" "$file"
            done < <(agent_clone_session_rows "$agent" "$path")
        done
    done < <(spork_clones)
}

# One row per logical session: rows arrive newest-mtime first, so the first
# file seen for an (agent, id) pair is the freshest rollout and the rest are
# older forks of the same session. Dedupe must run before the N-truncation,
# or a heavily-forked session would eat the whole window.
dedupe() {
    local seen=$'\n' mtime agent name id file key
    while IFS=$'\t' read -r mtime agent name id file; do
        [[ -n "$mtime" ]] || continue
        key="$agent/$id"
        [[ "$seen" == *$'\n'"$key"$'\n'* ]] && continue
        seen+="$key"$'\n'
        printf '%s\t%s\t%s\t%s\t%s\n' "$mtime" "$agent" "$name" "$id" "$file"
    done
}

rows=$(gather | sort -rn | dedupe)

if [[ -z "$rows" ]]; then
    if [[ -n "$agent_filter" ]]; then
        echo "No $(agent_label "$agent_filter") sessions found for any clone under $BASE_DIR." >&2
    else
        echo "No agent sessions found for any clone under $BASE_DIR." >&2
    fi
    exit 0
fi

# Rank by last real interaction, not mtime. mtime lies about recency: idle
# agent processes rewrite their logs on every system wake, clustering
# untouched sessions at "just now" — and truncating on it would let those
# crowd out genuinely recent work. The record timestamp is the last real
# interaction (same fix `just status` uses); files carrying no timestamps
# keep their mtime.
#
# The lie only runs one way — a record can't be newer than its file — so an
# mtime-descending walk can stop scanning once the next file's mtime can no
# longer beat the N-th best timestamp found: an exact top-N without reading
# every historical log.
ranked="$tmp/ranked"
: > "$ranked"
count=0
nth_ts=0
while IFS=$'\t' read -r mtime agent name id file; do
    [[ -n "$mtime" ]] || continue
    if [[ "$limit" != "all" ]] && (( count >= limit && mtime < nth_ts )); then
        break
    fi
    ts=$(agent_session_last_ts "$agent" "$file")
    [[ -n "$ts" ]] || ts="$mtime"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$agent" "$name" "$id" "$file" >> "$ranked"
    count=$(( count + 1 ))
    if [[ "$limit" != "all" ]] && (( count >= limit )); then
        nth_ts=$(cut -f1 "$ranked" | sort -rn | awk -v n="$limit" 'NR==n{print; exit}')
    fi
done <<< "$rows"

rows=$(sort -rn "$ranked")
if [[ "$limit" != "all" && -n "$rows" ]]; then
    rows=$(printf '%s\n' "$rows" | head -n "$limit")
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
while IFS=$'\t' read -r ts agent name id file; do
    [[ -n "$ts" ]] || continue
    age=$(format_relative $(( now - ts )))
    agent_name=$(agent_label "$agent")
    id="${id:0:ID_LEN}"
    title=$(agent_session_title "$agent" "$file")
    [[ -z "$title" ]] && title="—"
    (( ${#title} > SESSION_MAX )) && title="${title:0:SESSION_MAX-1}…"

    age_cells+=("$age")
    agent_cells+=("$agent_name")
    rep_cells+=("$name")
    id_cells+=("$id")
    title_cells+=("$title")
    epoch_cells+=("$ts")

    (( ${#name} > rep_width )) && rep_width=${#name}
    (( ${#agent_name} > agent_width )) && agent_width=${#agent_name}
    (( ${#age}  > age_width )) && age_width=${#age}
    (( ${#id}   > id_width ))  && id_width=${#id}
done <<< "$rows"

# A clone with a live claim has an agent session attached right now, so any of
# its sessions can't be cleanly resumed — `just resume` would refuse, since
# only one agent can run per working tree. Mark those rows so you know before
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

# Print AGE · AGENT · REP · ID · SESSION. Padded columns precede the free-text
# SESSION; color codes wrap only the visible token, so they don't shift
# alignment. Rows whose clone is in use get a trailing "(in use)" marker
# (yellow on a tty, plain text otherwise so it survives piping) — resume will
# refuse those.
# pad_tail assigns through printf -v; initialize the cells so shellcheck can
# see the assignments.
age_tail='' agent_tail='' rep_tail=''
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
