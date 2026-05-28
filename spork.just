# spork shared recipes — imported by a workspace justfile via `.spork/spork.just`.
#
# This file is the canonical source for spork's recipes; it updates whenever you
# pull the spork repo. Don't edit it per-workspace — instead override a recipe in
# your workspace justfile (which needs `set allow-duplicate-recipes := true`).
#
# Recipes dispatch through the `.spork` symlink and run with the working
# directory set to the workspace root, so the `./.spork/tools/...` paths resolve
# regardless of where `just` is invoked.

# Print the path of the first ready, unclaimed clone (pair with a shell alias that cds to it).
[group('use')]
go:
    @./.spork/tools/pick-ready.sh

# $$ (this recipe's shell) owns the claim; if it dies the claim self-frees.
# Claim the first ready, unclaimed clone, open Claude in it, and release on exit.
[group('use')]
claude:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     path=$(./.spork/tools/claim.sh "$owner") || exit 1; \
     trap 'bash "$rel" "$path" "$owner"' EXIT; \
     cd "$path" && claude

# One-line status per clone (no network).
[group('manage')]
status:
    @./.spork/tools/status-all.sh

# Pull trunk in every clean clone. Skips non-trunk branches and dirty trees.
[group('manage')]
pull:
    @./.spork/tools/pull-all.sh

# Create the next clone using the local mirror (no network).
[group('manage')]
clone:
    @./.spork/tools/clone.sh

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
