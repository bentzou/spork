#!/bin/bash
# clone.sh — create the next <prefix><N> clone(s), sharing objects with the
# mirror.
#
# Usage: clone.sh [COUNT]   (positive number of clones to add, default 1)
#
# Picks N = highest-existing-<prefix><N> + 1, where <prefix> comes from
# CLONE_PREFIX in .spork.local/config (default `p`). Inits each new clone
# wired up to the mirror the same way setup-mirror.sh wires existing clones,
# and checks out the trunk branch. Skips network — all objects come from the
# local mirror. A failure partway stops there: earlier clones are kept, and a
# re-run continues from the highest existing number.

set -euo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

count="${1:-1}"
if (( $# > 1 )) || ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: clone.sh [COUNT]   (positive number of clones to add, default 1)" >&2
    exit 2
fi

if [[ ! -d "$MIRROR_DIR" ]]; then
    echo "Mirror $MIRROR_DIR not found. Run \`just sync-setup\` first." >&2
    exit 1
fi

# The summary's freshness parenthetical answers the question a mirror-local
# clone raises — how fresh is it? — from the sync-time record the status
# footer also reads; absent (never synced), it's simply omitted. One value
# serves the whole batch.
synced=""
if [[ -f "$RUNTIME_DIR/last-sync" ]]; then
    read -r epoch _ < "$RUNTIME_DIR/last-sync"
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        synced=" (synced $(format_relative $(( $(date +%s) - epoch ))) ago)"
    fi
fi

make_next_clone() {
    # Find next number: max existing <CLONE_PREFIX><N> + 1.
    local max=0 path name n next target
    shopt -s nullglob
    for path in "$BASE_DIR/$CLONE_PREFIX"*/; do
        name=$(basename "$path")
        if [[ "$name" =~ ^${CLONE_PREFIX}([0-9]+)$ ]]; then
            n="${BASH_REMATCH[1]}"
            (( n > max )) && max=$n
        fi
    done
    shopt -u nullglob

    next=$(( max + 1 ))
    target="$BASE_DIR/$CLONE_PREFIX$next"

    if [[ -e "$target" ]]; then
        echo "Target $target already exists." >&2
        exit 1
    fi

    # Silent until the summary — the whole operation is local and fast, so
    # step narration is noise; failures still speak through their own messages.
    git init -q "$target"

    mkdir -p "$target/.git/objects/info"
    printf '%s\n' "$MIRROR_DIR/objects" > "$target/.git/objects/info/alternates"

    git -C "$target" remote add origin "$ORIGIN_URL"
    git -C "$target" remote add mirror "$MIRROR_DIR"
    git -C "$target" config --replace-all remote.mirror.fetch '+refs/heads/*:refs/remotes/origin/*'

    git -C "$target" fetch -q mirror

    if ! git -C "$target" rev-parse --verify -q "refs/remotes/origin/$TRUNK_BRANCH" >/dev/null; then
        echo "Mirror has no $TRUNK_BRANCH branch — try \`just sync\` first to refresh the mirror." >&2
        exit 1
    fi

    # --no-track + explicit branch config: both `origin` and `mirror` write to
    # refs/remotes/origin/*, so git's auto-tracking errors with "ambiguous
    # information for ref". We pin tracking to origin ourselves.
    git -C "$target" checkout -q --no-track -b "$TRUNK_BRANCH" "origin/$TRUNK_BRANCH"
    git -C "$target" config "branch.$TRUNK_BRANCH.remote" origin
    git -C "$target" config "branch.$TRUNK_BRANCH.merge"  "refs/heads/$TRUNK_BRANCH"

    # Make `just status` fast on this clone from the first run (see _lib.sh).
    ensure_status_perf "$target"

    # Optional per-workspace bootstrap (POST_CLONE in .spork/config) — e.g.
    # `bun install`, `pnpm install && pnpm run prepare`. Runs in the new clone,
    # sequentially per clone: parallel installs fight over lockfiles/caches.
    if [[ -n "${POST_CLONE:-}" ]]; then
        echo "${SPORK_INDENT:-}Running POST_CLONE: $POST_CLONE"
        ( cd "$target" && eval "$POST_CLONE" )
    fi

    # One dense done-line per clone, clean.sh style. SPORK_INDENT (exported by
    # init) nests it under init's summary; standalone `just clone` prints flush.
    echo "${SPORK_INDENT:-}Cloned $CLONE_PREFIX$next → $TRUNK_BRANCH @ $(git -C "$target" rev-parse --short HEAD)$synced"
}

for (( i = 0; i < count; i++ )); do
    make_next_clone
done
