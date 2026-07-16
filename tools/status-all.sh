#!/bin/bash
# status-all.sh — one-line status per clone in this spork workspace.
#
# Read-only: uses local ref state. Run `just fetch` (or `just sync`) first
# if you want fresh ahead/behind counts against origin.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# format_relative lives in _lib.sh (shared with log-all.sh).

# Longest SESSION title rendered before truncation with an ellipsis. The column
# is last, so this only bounds row length — it never affects other columns.
SESSION_MAX=56

status_for() {
    local path="$1"
    local branch dirty_count ahead behind state porcelain

    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

    # `git status --porcelain` exits non-zero when the repo can't read its
    # objects (bad alternates, missing HEAD object, corrupted store).
    # Surface that as `broken` rather than silently reporting clean.
    if ! porcelain=$(git -C "$path" status --porcelain 2>/dev/null); then
        echo "${branch}|broken"
        return
    fi
    dirty_count=0
    [[ -n "$porcelain" ]] && dirty_count=$(printf '%s\n' "$porcelain" | wc -l | tr -d ' ')

    ahead=0
    behind=0
    if git -C "$path" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        read -r ahead behind < <(git -C "$path" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null || echo "0 0")
    fi

    # STATE answers one question: can I pick this clone up right now, and if
    # not, why? It's a single verdict, not two orthogonal facts — so occupancy
    # and git state collapse into one word with a clear precedence:
    #   broken  — git can't read the repo (returned above; trumps everything)
    #   in use  — someone is in it: a live claim, or a claude/shell process
    #             cwd'd inside (overrides git state)
    #   parked  — human work blocks a clean pickup: off trunk and/or dirty
    #             tree. BRANCH says which — feat/x vs main* (the * marks dirt)
    #   pull/push — on trunk, clean, but behind/ahead of upstream
    #   open    — trunk, clean, in sync, nobody in it → what `jc` hands you
    if [[ "$branch" != "$TRUNK_BRANCH" ]] || (( dirty_count > 0 )); then
        state="parked"
    elif (( behind > 0 )); then
        state="pull"
    elif (( ahead > 0 )); then
        state="push"
    else
        state="open"
    fi

    # Someone is in it now, whatever the git state says. (When they leave,
    # the clone reverts to the git-derived state above.)
    if clone_occupied "$path"; then
        state="in use"
    fi

    # The dirty marker rides on BRANCH in every state, so `in use` rows keep
    # showing what kind of work sits in the tree.
    (( dirty_count > 0 )) && branch="${branch}*"

    echo "${branch}|${state}"
}

paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

if (( ${#paths[@]} == 0 )); then
    echo "No clones of $ORIGIN_URL found under $BASE_DIR." >&2
    exit 0
fi

# Compute every cell up front so column widths align. BRANCH is the trailing,
# free-text-safe column (no spaces), so it needs no width; every column before
# it is padded.
repo_width=3     # min for "REP" header
session_width=7  # min for "SESSION" header
state_width=5    # min for "STATE" header
age_width=3      # min for "AGE" header
now=$(date +%s)

# Each clone's probes (git status over a large tree, session-log stat) are
# independent and dominated by syscalls, so run them in parallel — one worker
# per clone writing a record to a temp file keyed by index. Wall time drops
# from the sum of per-clone probes to the slowest single clone. Presentation
# (widths, color, ordering) stays serial below, off the collected records.
emit_clone() {
    # Five newline-delimited fields: branch, state, start_epoch, last_epoch,
    # session_title. status_for yields "branch|state"; claude_newest_session
    # yields "<start>|<last>|<title>". Titles are single-line, so newline
    # framing needs no escaping and the reader can split fields by line.
    local path="$1" info session_info start
    info=$(status_for "$path")
    session_info=$(claude_newest_session "$path")
    start="${session_info%%|*}"
    session_info="${session_info#*|}"
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "${info%%|*}" "${info#*|}" "$start" \
        "${session_info%%|*}" "${session_info#*|}"
}

# Warm the process-sweep cache once here in the parent: the per-clone workers
# below are subshells forked after this line, so they inherit the result
# instead of each paying their own ~1s lsof.
spork_procs >/dev/null

tmp=$(mktemp -d "${TMPDIR:-/tmp}/spork-status.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for i in "${!paths[@]}"; do
    emit_clone "${paths[$i]}" >"$tmp/$i" &
done
wait

declare -a name_cells=() branch_cells=() state_cells=() age_cells=() last_epoch_cells=() session_cells=()
for i in "${!paths[@]}"; do
    name=$(basename "${paths[$i]}")
    # Read back the five fields this clone's worker wrote, in order.
    { IFS= read -r branch; IFS= read -r state; IFS= read -r start_epoch; IFS= read -r last_epoch; IFS= read -r session; } < "$tmp/$i"

    # AGE is anchored to the session's *start* — how long this piece of work
    # has existed — while staleness color and row order key on last_epoch,
    # the last write (see age_color and the active-row sort below).
    if [[ -n "$start_epoch" ]]; then
        age="$(format_relative $(( now - start_epoch )))"
    else
        age="—"
    fi

    # Open clones are the "what can I grab" answer: their last-touched time and
    # session title aren't decision-relevant, so blank both (BRANCH still shows
    # trunk). Active clones get AGE's "—" placeholder when untitled, and titles
    # are capped at SESSION_MAX.
    if [[ "$state" == "open" ]]; then
        age=""
        session=""
    else
        [[ -z "$session" ]] && session="—"
        (( ${#session} > SESSION_MAX )) && session="${session:0:SESSION_MAX-1}…"
    fi

    name_cells+=("$name")
    branch_cells+=("$branch")
    state_cells+=("$state")
    age_cells+=("$age")
    last_epoch_cells+=("$last_epoch")
    session_cells+=("$session")

    (( ${#name}    > repo_width ))    && repo_width=${#name}
    (( ${#session} > session_width )) && session_width=${#session}
    (( ${#state}   > state_width ))   && state_width=${#state}
    (( ${#age}     > age_width ))      && age_width=${#age}
done

printf '%*s   %-*s   %-*s   %-*s   %s\n' \
    "$repo_width" "REP" \
    "$session_width" "SESSION" \
    "$state_width" "STATE" \
    "$age_width" "AGE" "BRANCH"

active_idx=()
open_idx=()
for i in "${!paths[@]}"; do
    if [[ "${state_cells[$i]}" == "open" ]]; then
        open_idx+=("$i")
    else
        active_idx+=("$i")
    fi
done

# Active rows render most-recently-used first (by last write). Clones with no
# session sort last among active; ties keep natural clone order via the index
# as a secondary key. Open rows are interchangeable, so they keep natural
# order untouched.
if (( ${#active_idx[@]} > 1 )); then
    sorted=()
    while IFS= read -r line; do sorted+=("${line#* }"); done < <(
        for i in "${active_idx[@]}"; do
            printf '%s %s\n' "${last_epoch_cells[$i]:-0}" "$i"
        done | sort -k1,1rn -k2,2n
    )
    active_idx=("${sorted[@]}")
fi

c_green='' c_yellow='' c_cyan='' c_red='' c_reset=''
if [[ -t 1 ]]; then
    c_green=$'\033[32m'
    c_yellow=$'\033[33m'
    c_cyan=$'\033[36m'
    c_red=$'\033[31m'
    c_reset=$'\033[0m'
fi

# Color the STATE word by meaning, not the whole row.
state_color() {
    case "$1" in
        open)               printf '%s' "$c_green"  ;;
        parked)             printf '%s' "$c_cyan"   ;;
        "in use"|pull|push) printf '%s' "$c_yellow" ;;
        broken)             printf '%s' "$c_red"    ;;
        *)                  printf '%s' ''          ;;
    esac
}

# Color AGE red once a repo hasn't been touched by a Claude session in a while.
STALE_THRESHOLD=$(( 7 * 86400 ))
age_color() {
    local last="$1"
    [[ -z "$last" ]] && { printf '%s' ''; return; }
    if (( now - last >= STALE_THRESHOLD )); then
        printf '%s' "$c_red"
    fi
}

# Print one row in REPO · SESSION · STATE · AGE · BRANCH order. Each column but
# the trailing BRANCH is padded to its width; color codes don't count toward
# width, so they wrap only the visible token. SESSION is padded by character
# count rather than printf's byte width, so 1-column multibyte glyphs (e.g. the
# "—" common in session titles) stay aligned. Cells already hold exactly what's
# shown — open clones carry a blank AGE/SESSION — so this just renders them.
print_row() {
    local i="$1"
    local name="${name_cells[$i]}"
    local session="${session_cells[$i]}"
    local state="${state_cells[$i]}"
    local age="${age_cells[$i]}"

    local sc; sc=$(state_color "$state")
    local ac=""; [[ -n "$age" ]] && ac=$(age_color "${last_epoch_cells[$i]}")

    local name_pad state_pad age_pad
    printf -v name_pad  '%-*s' "$repo_width"  "$name"
    printf -v state_pad '%-*s' "$state_width" "$state"
    printf -v age_pad   '%-*s' "$age_width"   "$age"
    local name_tail="${name_pad:${#name}}"
    local state_tail="${state_pad:${#state}}"
    local age_tail="${age_pad:${#age}}"

    local sess_pad=$(( session_width - ${#session} ))
    (( sess_pad < 0 )) && sess_pad=0

    printf '%s%s%s%s   %s%*s   %s%s%s%s   %s%s%s%s   %s\n' \
        "$name_tail" "$sc" "$name" "$c_reset" \
        "$session" "$sess_pad" "" \
        "$sc" "$state" "$c_reset" "$state_tail" \
        "$ac" "$age" "$c_reset" "$age_tail" \
        "${branch_cells[$i]}"
}

# Active clones first, then open ones (the grabbable answer) last.
for i in ${active_idx[@]+"${active_idx[@]}"}; do print_row "$i"; done
for i in ${open_idx[@]+"${open_idx[@]}"}; do print_row "$i"; done

# Join "$@" with " · ".
join_dot() {
    local out="" sep=" · "
    local p
    for p in "$@"; do
        if [[ -z "$out" ]]; then out="$p"; else out="${out}${sep}${p}"; fi
    done
    printf '%s' "$out"
}

# Count comma-separated items (empty string -> 0).
csv_count() {
    [[ -z "$1" ]] && { echo 0; return; }
    local IFS=','
    # shellcheck disable=SC2206
    local arr=($1)
    echo "${#arr[@]}"
}

# Format CSV "a,b,c" as "a, b, c".
csv_human() {
    printf '%s' "${1//,/, }"
}

print_footer() {
    local dim='' reset=''
    if [[ -t 1 ]]; then
        dim=$'\033[2m'
        reset=$'\033[0m'
    fi

    if [[ -d "$LOCK_DIR" ]]; then
        local started elapsed rel
        started=$(stat -f %B "$LOCK_DIR" 2>/dev/null || echo 0)
        if (( started > 0 )); then
            elapsed=$(( $(date +%s) - started ))
            rel=$(format_relative "$elapsed")
            printf '\n%ssyncing in background (started %s ago)%s\n' "$dim" "$rel" "$reset"
        else
            printf '\n%ssyncing in background%s\n' "$dim" "$reset"
        fi
        return
    fi

    local last="$RUNTIME_DIR/last-sync"
    [[ -f "$last" ]] || return 0

    local line; line=$(cat "$last")
    local epoch duration pulled fetched failed
    epoch="${line%% *}"; line="${line#* }"
    duration="${line%% *}"; line="${line#* }"
    # Remaining tokens are pulled=... fetched=... failed=...
    pulled="${line#*pulled=}"; pulled="${pulled%% *}"
    fetched="${line#*fetched=}"; fetched="${fetched%% *}"
    failed="${line#*failed=}"; failed="${failed%% *}"

    local elapsed; elapsed=$(( $(date +%s) - epoch ))
    local rel; rel=$(format_relative "$elapsed")

    local parts=()
    [[ -n "$pulled" ]]  && parts+=("pulled $(csv_human "$pulled")")
    [[ -n "$fetched" ]] && parts+=("fetched $(csv_count "$fetched")")
    if [[ -n "$failed" ]]; then
        local n; n=$(csv_count "$failed")
        parts+=("$n failed ($(csv_human "$failed"))")
    fi

    if (( ${#parts[@]} == 0 )); then
        printf '\n%slast sync %s ago (%ss)%s\n' "$dim" "$rel" "$duration" "$reset"
    else
        printf '\n%slast sync %s ago (%ss): %s%s\n' "$dim" "$rel" "$duration" "$(join_dot "${parts[@]}")" "$reset"
    fi
}

print_footer
