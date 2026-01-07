#!/bin/bash
# sync-bg.sh — background worker spawned after `just sync` prints status.
#
# Flow:
#   1. Lock (atomic mkdir). Exit silently if another sync is running.
#   2. Fetch the shared bare mirror once (single network download).
#   3. In parallel, for each clone with a 'mirror' remote configured:
#        - git fetch mirror (local; updates origin/* tracking refs)
#        - if branch == $TRUNK_BRANCH and tree clean: git merge --ff-only
#        - otherwise: leave branch work alone
#   4. Wait, log a `done` line.
#
# Output goes to $LOG_FILE (truncated per run).

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Another sync is running. Exit silently.
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

: > "$LOG_FILE"
start_epoch=$(date +%s)
printf '== sync started %s ==\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"

if [[ ! -d "$MIRROR_DIR" ]]; then
    echo "mirror not found at $MIRROR_DIR — run \`just sync-setup\` first" >> "$LOG_FILE"
    exit 0
fi

# Step 1: single network fetch.
mirror_start=$(date +%s)
if mirror_out=$(git -C "$MIRROR_DIR" fetch --prune --quiet 2>&1); then
    printf 'mirror: fetched in %ss\n' "$(( $(date +%s) - mirror_start ))" >> "$LOG_FILE"
else
    printf 'mirror: failed: %s\n' "$(echo "$mirror_out" | head -1)" >> "$LOG_FILE"
fi

# Step 2: parallel local fanout.
paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

sync_one() {
    local path="$1"
    local name; name=$(basename "$path")

    if ! git -C "$path" config --get remote.mirror.url >/dev/null 2>&1; then
        printf '%s: skipped (no mirror remote — run sync-setup)\n' "$name"
        return
    fi

    if ! fetch_err=$(git -C "$path" fetch mirror --quiet 2>&1); then
        printf '%s: failed: fetch mirror: %s\n' "$name" "$(echo "$fetch_err" | head -1)"
        return
    fi

    local branch dirty_count
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    dirty_count=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$branch" != "$TRUNK_BRANCH" ]]; then
        printf '%s: fetched only (branch=%s)\n' "$name" "$branch"
        return
    fi

    if (( dirty_count > 0 )); then
        printf '%s: fetched only (dirty: %d uncommitted)\n' "$name" "$dirty_count"
        return
    fi

    if ! git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$TRUNK_BRANCH" >/dev/null; then
        printf '%s: fetched only (no origin/%s ref)\n' "$name" "$TRUNK_BRANCH"
        return
    fi

    local before after merge_err
    before=$(git -C "$path" rev-parse HEAD)
    if ! merge_err=$(git -C "$path" merge --ff-only --quiet "origin/$TRUNK_BRANCH" 2>&1); then
        printf '%s: failed: merge --ff-only: %s\n' "$name" "$(echo "$merge_err" | head -1)"
        return
    fi
    after=$(git -C "$path" rev-parse HEAD)

    if [[ "$before" == "$after" ]]; then
        printf '%s: up to date\n' "$name"
    else
        printf '%s: pulled %s..%s\n' "$name" "${before:0:7}" "${after:0:7}"
    fi
}

pids=()
tmp_dir=$(mktemp -d)
i=0
for path in "${paths[@]}"; do
    out_file="$tmp_dir/$i"
    sync_one "$path" > "$out_file" &
    pids+=("$!")
    i=$((i + 1))
done

for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

pulled=()
fetched=()
failed=()
for ((j = 0; j < i; j++)); do
    line=$(cat "$tmp_dir/$j")
    printf '%s\n' "$line" >> "$LOG_FILE"
    name="${line%%:*}"
    rest="${line#*: }"
    case "$rest" in
        "pulled "*)        pulled+=("$name") ;;
        "up to date")      fetched+=("$name") ;;
        "fetched only"*)   fetched+=("$name") ;;
        "failed"*)         failed+=("$name") ;;
        *) ;;  # skipped or unrecognized — not bucketed
    esac
done
rm -rf "$tmp_dir"

end_epoch=$(date +%s)
duration=$(( end_epoch - start_epoch ))
printf '== done in %ss ==\n' "$duration" >> "$LOG_FILE"

# Write last-sync summary atomically.
summary="$RUNTIME_DIR/last-sync"
tmp_summary="$summary.tmp.$$"
{
    pulled_csv=$(IFS=,; printf '%s' "${pulled[*]:-}")
    fetched_csv=$(IFS=,; printf '%s' "${fetched[*]:-}")
    failed_csv=$(IFS=,; printf '%s' "${failed[*]:-}")
    printf '%s %s pulled=%s fetched=%s failed=%s\n' \
        "$end_epoch" "$duration" "$pulled_csv" "$fetched_csv" "$failed_csv"
} > "$tmp_summary"
mv "$tmp_summary" "$summary"
