#!/bin/bash
# setup-mirror.sh — one-time, idempotent setup for the shared bare mirror.
#
# Creates $MIRROR_DIR as a bare clone of $ORIGIN_URL, then for each clone
# under $BASE_DIR with matching origin:
#   - git repack -ad   (so the repo is self-contained before linking)
#   - link .git/objects/info/alternates -> mirror's objects/
#   - add a 'mirror' remote with refspec writing to refs/remotes/origin/*,
#     so 'git fetch mirror' updates origin/* tracking refs locally.
#
# The 'origin' remote is left untouched, so manual git fetch origin / git push
# behavior is unchanged.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if [[ ! -d "$MIRROR_DIR" ]]; then
    # Seed from an existing local clone instead of re-downloading from origin.
    seed=""
    while IFS= read -r candidate; do
        seed="$candidate"
        break
    done < <(spork_clones)

    if [[ -n "$seed" ]]; then
        echo "Seeding mirror from $(basename "$seed") (no network) ..."
        git clone --mirror "$seed/.git" "$MIRROR_DIR"
        git -C "$MIRROR_DIR" remote set-url origin "$ORIGIN_URL"
        echo "Fetching latest refs from origin ..."
        git -C "$MIRROR_DIR" fetch --prune
    else
        # git's own progress passes through untouched: the download is the one
        # real network wait here, and silence on a big repo reads as hung.
        echo "Cloning mirror from origin (one-time, full history) ..."
        git clone --mirror "$ORIGIN_URL" "$MIRROR_DIR"
    fi
else
    echo "Mirror already exists (skipping clone)."
fi

MIRROR_OBJECTS="$MIRROR_DIR/objects"

paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

# Nothing to link yet is a normal state, not a warning: during init the first
# clone is created right after this, and standalone the next step is
# `just clone` either way. Say nothing rather than sound like a failure.
if (( ${#paths[@]} == 0 )); then
    exit 0
fi

max_width=4
for path in "${paths[@]}"; do
    name=$(basename "$path")
    (( ${#name} > max_width )) && max_width=${#name}
done

link_one() {
    local path="$1"

    # Backfill the status perf config on every run, even for already-linked
    # clones — a cheap `just sync-setup` re-run is how existing workspaces pick
    # it up (idempotent; only writes when unset).
    ensure_status_perf "$path"

    local git_dir
    git_dir=$(git -C "$path" rev-parse --git-dir 2>/dev/null)
    if [[ "$git_dir" != /* ]]; then
        git_dir="$path$git_dir"
    fi

    local alternates_file="$git_dir/objects/info/alternates"
    local linked_alt=0
    mkdir -p "$git_dir/objects/info"
    if [[ -f "$alternates_file" ]] && grep -Fxq "$MIRROR_OBJECTS" "$alternates_file"; then
        linked_alt=1
    fi

    local has_remote=0
    if git -C "$path" config --get remote.mirror.url >/dev/null 2>&1; then
        has_remote=1
    fi

    if (( linked_alt && has_remote )); then
        echo "already linked"
        return
    fi

    # Repack BEFORE adding alternates so the repo is self-contained at link
    # time. After this, only newly fetched objects live solely in the mirror.
    local before after
    before=$(du -sk "$git_dir/objects" 2>/dev/null | awk '{print $1}')
    git -C "$path" repack -ad --quiet 2>/dev/null || true

    if (( ! linked_alt )); then
        printf '%s\n' "$MIRROR_OBJECTS" >> "$alternates_file"
    fi

    if (( ! has_remote )); then
        git -C "$path" remote add mirror "$MIRROR_DIR"
        git -C "$path" config --replace-all remote.mirror.fetch '+refs/heads/*:refs/remotes/origin/*'
    else
        # Heal a stale URL (e.g. mirror moved on disk).
        git -C "$path" remote set-url mirror "$MIRROR_DIR"
    fi

    after=$(du -sk "$git_dir/objects" 2>/dev/null | awk '{print $1}')
    if [[ -n "${before:-}" && -n "${after:-}" ]]; then
        local saved=$(( before - after ))
        echo "linked (objects: ${before}K -> ${after}K, saved ${saved}K)"
    else
        echo "linked"
    fi
}

for path in "${paths[@]}"; do
    name=$(basename "$path")
    printf '%-*s  %s\n' "$max_width" "$name" "$(link_one "$path")"
done
