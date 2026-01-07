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
        echo "Seeding bare mirror at $MIRROR_DIR from $(basename "$seed") (no network) ..."
        git clone --mirror "$seed/.git" "$MIRROR_DIR"
        git -C "$MIRROR_DIR" remote set-url origin "$ORIGIN_URL"
        echo "Fetching latest refs from $ORIGIN_URL ..."
        git -C "$MIRROR_DIR" fetch --prune
    else
        echo "No existing local clone found. Cloning mirror from $ORIGIN_URL ..."
        git clone --mirror "$ORIGIN_URL" "$MIRROR_DIR"
    fi
    echo
else
    echo "Mirror already exists at $MIRROR_DIR (skipping clone)."
    echo
fi

MIRROR_OBJECTS="$MIRROR_DIR/objects"

paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

if (( ${#paths[@]} == 0 )); then
    echo "No clones of $ORIGIN_URL found under $BASE_DIR." >&2
    exit 0
fi

max_width=4
for path in "${paths[@]}"; do
    name=$(basename "$path")
    (( ${#name} > max_width )) && max_width=${#name}
done

link_one() {
    local path="$1"

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
