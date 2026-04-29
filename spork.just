# spork shared recipes — imported by a workspace justfile via `.spork/spork.just`.
#
# This file is the canonical source for spork's recipes; it updates whenever you
# pull the spork repo. Don't edit it per-workspace — instead override a recipe in
# your workspace justfile (which needs `set allow-duplicate-recipes := true`).
#
# Recipes dispatch through the `.spork` symlink and run with the working
# directory set to the workspace root, so the `./.spork/tools/...` paths resolve
# regardless of where `just` is invoked.

# Recipes are listed in source order (`--unsorted`); keep each group's listed
# recipes alphabetical by name so the menu reads alphabetically. Private
# plumbing recipes are hidden from the menu, so they sit next to what they
# support rather than in alphabetical position.

# $$ (this recipe's shell) owns the claim; if it dies the claim self-frees.
# Claim the first ready, unclaimed clone, open Claude in it, and release on exit.
[group('use')]
claude:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     path=$(./.spork/tools/claim.sh "$owner") || exit 1; \
     trap 'bash "$rel" "$path" "$owner"' EXIT; \
     cd "$path" && claude

# OWNER is a long-lived PID that keeps the claim held — pass your interactive
# shell's $$ so a shell function can `cd` into the path and `release` it later,
# with the claim owned by your terminal (it self-frees when the terminal closes)
# rather than a transient just process. Bare `just claude` does this internally.
# Claim the first ready, unclaimed clone for OWNER and print its path.
# Private: a plumbing recipe for shell functions (the `jc` alias), not the menu.
[private]
claim owner:
    @./.spork/tools/claim.sh "{{owner}}"

# CLONE is a clone path or bare name; OWNER is the PID that claimed it. A no-op
# if the clone was already reclaimed by someone else.
# Release the claim on CLONE held by OWNER (pairs with `claim`).
# Private: a plumbing recipe for shell functions, not the menu.
[private]
release clone owner:
    @./.spork/tools/release.sh "{{clone}}" "{{owner}}"

# Print the path of the first ready, unclaimed clone (pair with a shell alias that cds to it).
[group('use')]
go:
    @./.spork/tools/pick-ready.sh

# ID is a session id or the short id from `just log`. Claims that session's
# clone for this shell (self-frees on exit), then resumes it in its launch dir.
# Resume a Claude session from `just log` by its ID.
[group('use')]
restart id:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     found=$(./.spork/tools/find-session.sh "{{id}}") || exit 1; \
     IFS=$'\t' read -r name cwd sid <<<"$found"; \
     ./.spork/tools/claim-one.sh "$name" "$owner" >/dev/null || exit 1; \
     trap 'bash "$rel" "$name" "$owner"' EXIT; \
     cd "$cwd" && claude --resume "$sid"

# Create the next clone using the local mirror (no network).
[group('manage')]
clone:
    @./.spork/tools/clone.sh

# Optional N: a count or "all" (defaults to 20). Closed sessions are included.
# Recent Claude sessions across the pool, newest first (no network).
[group('manage')]
log *n:
    @./.spork/tools/log-all.sh "{{n}}"

# Pull trunk in every clean clone. Skips non-trunk branches and dirty trees.
[group('manage')]
pull:
    @./.spork/tools/pull-all.sh

# One-line status per clone (no network).
[group('manage')]
status:
    @./.spork/tools/status-all.sh

# Fetch every clone (no merge, no skip rules).
[private]
fetch:
    @./.spork/tools/pull-all.sh --fetch-only

# One-time: create the shared bare mirror and link each clone to it.
[private]
sync-setup:
    @./.spork/tools/setup-mirror.sh

# Status table, then background fetch/pull via the shared mirror.
[private]
sync:
    @./.spork/tools/status-all.sh
    @( ./.spork/tools/sync-bg.sh </dev/null >/dev/null 2>&1 & ) </dev/null
