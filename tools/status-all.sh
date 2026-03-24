#!/bin/bash
# status-all.sh — one-line status per clone in this spork workspace.
#
# Read-only: uses local ref state. Run `just fetch` (or `just sync`) first
# if you want fresh ahead/behind counts against origin.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

format_relative() {
    local s="$1"
    # `now` is sampled once up front, so a session that writes its log after
    # that sampling yields a small negative delta — clamp it to 0.
    (( s < 0 )) && s=0
    if (( s < 60 ));     then printf '%ss' "$s"
    elif (( s < 3600 )); then printf '%sm' "$(( s / 60 ))"
    elif (( s < 86400 ));then printf '%sh' "$(( s / 3600 ))"
    else                      printf '%sd' "$(( s / 86400 ))"
    fi
}

# Newest mtime (epoch) across Claude session jsonl files for any cwd inside
# this repo. Project dirs encode the cwd as the absolute path with `/` → `-`.
# Subdir sessions count too (e.g. `<repo>-src-foo`). Empty string if none.
claude_last_epoch() {
    local repo_path="${1%/}"
    local encoded="${repo_path//\//-}"
    local root="$HOME/.claude/projects"
    [[ -d "$root" ]] || return 0

    local best=0 dir f mtime
    shopt -s nullglob
    for dir in "$root/$encoded" "$root/$encoded"-*; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.jsonl; do
            mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
            (( mtime > best )) && best=$mtime
        done
    done
    shopt -u nullglob
    (( best > 0 )) && printf '%s' "$best"
}

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
    # not, why? It's a single verdict, not two orthogonal facts — so a live
    # claim and git state collapse into one word with a clear precedence:
    #   broken  — git can't read the repo (returned above; trumps everything)
    #   in use  — a live session is attached (overrides git state)
    #   branch/local/pull/push — parked: has work that blocks a clean pickup
    #   open    — on trunk, clean, in sync, unclaimed → exactly what `jc` hands you
    if [[ "$branch" != "$TRUNK_BRANCH" ]]; then
        state="branch"
    elif (( dirty_count > 0 )); then
        state="local"
    elif (( behind > 0 )); then
        state="pull"
    elif (( ahead > 0 )); then
        state="push"
    else
        state="open"
    fi

    # A live claim means someone is in it now, whatever the git state says.
    # (When they exit, the clone reverts to the git-derived state above.)
    if clone_occupied "$path"; then
        state="in use"
    fi

    echo "${branch}|${state}"
}

paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

if (( ${#paths[@]} == 0 )); then
    echo "No clones of $ORIGIN_URL found under $BASE_DIR." >&2
    exit 0
fi

# Compute every cell up front so column widths align (AGE goes last, STATE
# has variable detail and must be padded too).
repo_width=4    # min for "REPO" header
branch_width=6  # min for "BRANCH" header
state_width=5   # min for "STATE" header
age_width=3     # min for "AGE" header
now=$(date +%s)
declare -a name_cells=() branch_cells=() state_cells=() age_cells=() last_epoch_cells=()
for path in "${paths[@]}"; do
    name=$(basename "$path")
    info=$(status_for "$path")
    branch="${info%%|*}"
    state="${info#*|}"

    last_epoch=$(claude_last_epoch "$path")
    if [[ -n "$last_epoch" ]]; then
        age="$(format_relative $(( now - last_epoch )))"
    else
        age="—"
    fi

    name_cells+=("$name")
    branch_cells+=("$branch")
    state_cells+=("$state")
    age_cells+=("$age")
    last_epoch_cells+=("$last_epoch")

    (( ${#name}   > repo_width ))   && repo_width=${#name}
    (( ${#branch} > branch_width )) && branch_width=${#branch}
    (( ${#state}  > state_width ))  && state_width=${#state}
    (( ${#age}    > age_width ))    && age_width=${#age}
done

printf '%-*s  %-*s  %-*s   %s\n' \
    "$repo_width" "REPO" \
    "$branch_width" "BRANCH" \
    "$state_width" "STATE" "AGE"

active_idx=()
open_idx=()
for i in "${!paths[@]}"; do
    if [[ "${state_cells[$i]}" == "open" ]]; then
        open_idx+=("$i")
    else
        active_idx+=("$i")
    fi
done

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
        open)                  printf '%s' "$c_green"  ;;
        branch)                printf '%s' "$c_cyan"   ;;
        "in use"|local|pull|push) printf '%s' "$c_yellow" ;;
        broken)                printf '%s' "$c_red"    ;;
        *)                     printf '%s' ''          ;;
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

# Print a row. Pads first so column widths line up; color codes don't count
# toward width, so they're applied only to the visible token.
print_row() {
    local i="$1" age="$2"
    local state="${state_cells[$i]}"
    local sc; sc=$(state_color "$state")
    local ac; ac=$(age_color "${last_epoch_cells[$i]}")
    local name="${name_cells[$i]}"
    local name_pad state_pad
    printf -v name_pad  '%-*s' "$repo_width"  "$name"
    printf -v state_pad '%-*s' "$state_width" "$state"
    # Re-wrap just the non-space prefix in color so trailing padding stays plain.
    local name_tail="${name_pad:${#name}}"
    local state_tail="${state_pad:${#state}}"
    printf '%s%s%s%s  %-*s  %s%s%s%s   %s%s%s\n' \
        "$sc" "$name" "$c_reset" "$name_tail" \
        "$branch_width" "${branch_cells[$i]}" \
        "$sc" "$state" "$c_reset" "$state_tail" \
        "$ac" "$age" "$c_reset"
}

for i in ${active_idx[@]+"${active_idx[@]}"}; do print_row "$i" "${age_cells[$i]}"; done
# Open clones go last, with no AGE: they're the answer to "what can I grab",
# and a free clone's last-touched time isn't decision-relevant.
for i in ${open_idx[@]+"${open_idx[@]}"}; do print_row "$i" ""; done

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
