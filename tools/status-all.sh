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
    local branch="?" ahead=0 behind=0 dirty_count=0 state line porcelain

    # One `git status --porcelain=v2 --branch` answers everything the verdict
    # needs — branch, ahead/behind vs a configured upstream, and the dirty
    # list — in a single fork (it used to take four). It exits non-zero when
    # the repo can't read its objects (bad alternates, missing HEAD object,
    # corrupted store): surface that as `broken` rather than silently
    # reporting clean.
    if ! porcelain=$(git -C "$path" status --porcelain=v2 --branch 2>/dev/null); then
        echo "?|broken"
        return
    fi
    # Header lines start with '#'; every other non-empty line is one
    # changed/untracked entry. `branch.ab +A -B` appears only when an
    # upstream is configured — absent means nothing to compare, i.e. in sync.
    while IFS= read -r line; do
        case "$line" in
            "# branch.head "*) branch="${line#\# branch.head }" ;;
            "# branch.ab "*)   line="${line#\# branch.ab }"
                               ahead="${line%% *}";  ahead="${ahead#+}"
                               behind="${line##* }"; behind="${behind#-}" ;;
            "#"*) ;;
            ?*)   (( dirty_count++ )) ;;
        esac
    done <<<"$porcelain"
    [[ "$branch" == "(detached)" ]] && branch="HEAD"

    # STATE answers one question: can I pick this clone up right now, and if
    # not, why? One verdict with a clear precedence:
    #   broken  — git can't read the repo (returned above; trumps everything)
    #   in use  — someone is in it (overlaid by the parent at render time,
    #             where the process sweep has finished; overrides git state)
    #   parked  — human work blocks a clean pickup: off trunk and/or dirty
    #             tree (parked on trunk implies the latter)
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
pr_width=2       # min for "PR" header
now=$(date +%s)

# Each clone's probes (git status over a large tree, session-log stat) are
# independent and dominated by syscalls, so run them in parallel — one worker
# per clone writing a record to a temp file keyed by index. Wall time drops
# from the sum of per-clone probes to the slowest single clone. Presentation
# (widths, color, ordering) stays serial below, off the collected records.
emit_clone() {
    # Four newline-delimited fields: branch, state, last_epoch, session_title.
    # status_for yields "branch|state"; claude_newest_session yields
    # "<epoch>|<title>". Titles are single-line, so newline framing needs no
    # escaping and the reader can split fields by line.
    local path="$1" info session_info
    info=$(status_for "$path")
    session_info=$(claude_newest_session "$path")
    printf '%s\n%s\n%s\n%s\n' \
        "${info%%|*}" "${info#*|}" "${session_info%%|*}" "${session_info#*|}"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/spork-status.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The process sweep (pgrep+lsof) runs as one more background job alongside
# the per-clone workers — occupancy isn't needed until render time, so its
# latency hides under theirs. spork_procs just prints the cached sweep when
# a caller (or test) pre-loaded one.
spork_procs >"$tmp/procs" &

for i in "${!paths[@]}"; do
    emit_clone "${paths[$i]}" >"$tmp/$i" &
done
wait

# Adopt the sweep for the occupancy checks below (read by the sourced
# spork_procs; shellcheck can't see through the indirection).
# shellcheck disable=SC2034
SPORK_PROC_SWEEP=$(cat "$tmp/procs")
# shellcheck disable=SC2034
SPORK_PROC_SWEEP_LOADED=1

declare -a name_cells=() branch_cells=() state_cells=() age_cells=() last_epoch_cells=() session_cells=() pr_cells=()
for i in "${!paths[@]}"; do
    name=$(basename "${paths[$i]}")
    # Read back the four fields this clone's worker wrote, in order.
    { IFS= read -r branch; IFS= read -r state; IFS= read -r last_epoch; IFS= read -r session; } < "$tmp/$i"

    # Someone is in it now, whatever the git state says — a live claim or a
    # swept claude/shell process. Overlaid here (not in the worker) so the
    # sweep and the git probes could run concurrently; broken still trumps.
    if [[ "$state" != "broken" ]] && clone_occupied "${paths[$i]}"; then
        state="in use"
    fi

    # AGE = time since you last interacted with the clone's newest session
    # (its jsonl's last write). The active-row sort below uses the same
    # epoch, so the table reads top-down from freshest to coldest.
    if [[ -n "$last_epoch" ]]; then
        age="$(format_relative $(( now - last_epoch )))"
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

    # The branch's PR, from the sync-time gh cache or the pr-<n> naming
    # convention (see pr_for_branch). Branches without one stay blank.
    pr=""
    pr_num=$(pr_for_branch "$branch")
    [[ -n "$pr_num" ]] && pr="#$pr_num"

    name_cells+=("$name")
    branch_cells+=("$branch")
    state_cells+=("$state")
    age_cells+=("$age")
    last_epoch_cells+=("$last_epoch")
    session_cells+=("$session")
    pr_cells+=("$pr")

    (( ${#name}    > repo_width ))    && repo_width=${#name}
    (( ${#session} > session_width )) && session_width=${#session}
    (( ${#state}   > state_width ))   && state_width=${#state}
    (( ${#age}     > age_width ))      && age_width=${#age}
    (( ${#pr}      > pr_width ))       && pr_width=${#pr}
done

# Dim the header row on a tty so the data rows carry the visual weight
# (matching the dim sync footer). Escapes wrap the whole line, so the
# padded widths are unaffected; non-tty output stays plain.
c_head='' c_head_reset=''
if [[ -t 1 ]]; then
    c_head=$'\033[2m'
    c_head_reset=$'\033[0m'
fi
printf '%s%*s   %-*s   %-*s   %-*s   %-*s   %s%s\n' \
    "$c_head" \
    "$repo_width" "REP" \
    "$session_width" "SESSION" \
    "$state_width" "STATE" \
    "$age_width" "AGE" \
    "$pr_width" "PR" "BRANCH" \
    "$c_head_reset"

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

c_green='' c_yellow='' c_cyan='' c_red='' c_link='' c_reset=''
if [[ -t 1 ]]; then
    c_green=$'\033[32m'
    c_yellow=$'\033[33m'
    c_cyan=$'\033[36m'
    c_red=$'\033[31m'
    c_link=$'\033[4;34m'   # underlined blue: the classic "this is a link"
    c_reset=$'\033[0m'
fi

# PR cells become OSC 8 hyperlinks on a terminal with a GitHub origin —
# terminals without hyperlink support ignore the escapes and show the plain
# number. Non-tty output (tests, pipes) gets bare text.
web_url=$(origin_web_url)
use_links=0
[[ -t 1 && -n "$web_url" ]] && use_links=1

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
    local pr="${pr_cells[$i]}"

    local sc; sc=$(state_color "$state")
    local ac=""; [[ -n "$age" ]] && ac=$(age_color "${last_epoch_cells[$i]}")

    local name_pad state_pad age_pad pr_pad
    printf -v name_pad  '%-*s' "$repo_width"  "$name"
    printf -v state_pad '%-*s' "$state_width" "$state"
    printf -v age_pad   '%-*s' "$age_width"   "$age"
    printf -v pr_pad    '%-*s' "$pr_width"    "$pr"
    local name_tail="${name_pad:${#name}}"
    local state_tail="${state_pad:${#state}}"
    local age_tail="${age_pad:${#age}}"
    local pr_tail="${pr_pad:${#pr}}"

    # Clickable when the terminal supports OSC 8; underlined blue marks it
    # as a link. Padding counts only the visible "#123", like the color
    # escapes above.
    local pr_out="$pr"
    [[ -n "$pr" ]] && pr_out="${c_link}${pr}${c_reset}"
    if [[ -n "$pr" ]] && (( use_links )); then
        pr_out=$'\033]8;;'"$web_url/pull/${pr#\#}"$'\033\\'"$pr_out"$'\033]8;;\033\\'
    fi

    local sess_pad=$(( session_width - ${#session} ))
    (( sess_pad < 0 )) && sess_pad=0

    printf '%s%s%s%s   %s%*s   %s%s%s%s   %s%s%s%s   %s%s   %s\n' \
        "$name_tail" "$sc" "$name" "$c_reset" \
        "$session" "$sess_pad" "" \
        "$sc" "$state" "$c_reset" "$state_tail" \
        "$ac" "$age" "$c_reset" "$age_tail" \
        "$pr_out" "$pr_tail" \
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
