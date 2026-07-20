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
# The printf stamps the clone name on the terminal title (OSC 0) so the
# window is findable in Ghostty's Window menu immediately — Claude retitles
# it with the session topic once one exists.
# Claim the first ready, unclaimed clone, open Claude in it, and release on exit.
[group('use')]
claude:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     path=$(./.spork/tools/claim.sh "$owner" claude) || exit 1; \
     trap 'bash "$rel" "$path" "$owner"' EXIT; \
     printf '\033]0;%s\007' "$(basename "$path")"; \
     cd "$path" && claude

# Claim the first ready, unclaimed clone, open Codex in it, and release on exit.
[group('use')]
codex:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     path=$(./.spork/tools/claim.sh "$owner" codex) || exit 1; \
     trap 'bash "$rel" "$path" "$owner"' EXIT; \
     printf '\033]0;%s\007' "$(basename "$path")"; \
     cd "$path" && codex

# OWNER is a long-lived PID that keeps the claim held — pass your interactive
# shell's $$ so a shell function can `cd` into the path and `release` it later,
# with the claim owned by your terminal (it self-frees when the terminal closes)
# rather than a transient just process. Bare `just claude` does this internally.
# Claim the first ready, unclaimed clone for OWNER and print its path.
# Private: plumbing for shell functions (`jc`/`jx`), not the menu. AGENT
# defaults to Claude for compatibility with existing `j claim $$` shortcuts.
[private]
claim owner agent='claude':
    @./.spork/tools/claim.sh "{{owner}}" "{{agent}}"

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

# ID is a session id (or short id from `just log`), or a clone name like p3
# to resume whatever session was last active there. Claims that session's
# clone for this shell (self-frees on exit), then resumes it in its launch dir.
# Resume a session by `just log` ID — or by clone name (its latest).
[group('use')]
resume id:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     found=$(./.spork/tools/find-session.sh "{{id}}") || exit 1; \
     IFS=$'\t' read -r agent name cwd sid <<<"$found"; \
     ./.spork/tools/claim-one.sh "$name" "$owner" "$agent" >/dev/null || exit 1; \
     trap 'bash "$rel" "$name" "$owner"' EXIT; \
     printf '\033]0;%s\007' "$name"; \
     case "$agent" in \
       claude) cd "$cwd" && claude --resume "$sid" ;; \
       codex)  cd "$cwd" && codex resume "$sid" ;; \
       *) echo "Unknown agent '$agent'." >&2; exit 2 ;; \
     esac

# Resume a Claude session by `just log-claude` ID — or by clone name.
[group('use')]
resume-claude id:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     found=$(./.spork/tools/find-session.sh --agent claude "{{id}}") || exit 1; \
     IFS=$'\t' read -r agent name cwd sid <<<"$found"; \
     ./.spork/tools/claim-one.sh "$name" "$owner" "$agent" >/dev/null || exit 1; \
     trap 'bash "$rel" "$name" "$owner"' EXIT; \
     printf '\033]0;%s\007' "$name"; \
     cd "$cwd" && claude --resume "$sid"

# Resume a Codex session by `just log-codex` ID — or by clone name.
[group('use')]
resume-codex id:
    @owner=$$; rel="$PWD/.spork/tools/release.sh"; \
     found=$(./.spork/tools/find-session.sh --agent codex "{{id}}") || exit 1; \
     IFS=$'\t' read -r agent name cwd sid <<<"$found"; \
     ./.spork/tools/claim-one.sh "$name" "$owner" "$agent" >/dev/null || exit 1; \
     trap 'bash "$rel" "$name" "$owner"' EXIT; \
     printf '\033]0;%s\007' "$name"; \
     cd "$cwd" && codex resume "$sid"

# Create the next clone using the local mirror (no network).
[group('manage')]
clone:
    @./.spork/tools/clone.sh

# Optional N: a count or "all" (defaults to 20). Closed sessions are included.
# Recent agent sessions across the pool, newest first (no network).
[group('manage')]
log *n:
    @./.spork/tools/log-all.sh "{{n}}"

# Recent Claude sessions across the pool, newest first (no network).
[group('manage')]
log-claude *n:
    @./.spork/tools/log-all.sh --agent claude "{{n}}"

# Recent Codex sessions across the pool, newest first (no network).
[group('manage')]
log-codex *n:
    @./.spork/tools/log-all.sh --agent codex "{{n}}"

# Pull trunk in every clean clone. Skips non-trunk branches and dirty trees.
[group('manage')]
pull:
    @./.spork/tools/pull-all.sh

# NAME is a clone name or path. Local branches are kept. Refuses occupied
# clones; refuses to discard uncommitted changes or unpushed trunk commits
# without --force; --full also wipes ignored files (node_modules etc.) and
# reruns POST_CLONE.
# Clean a clone back to open: latest trunk, clean tree; branches kept.
[group('manage')]
clean name *flags:
    @./.spork/tools/clean.sh "{{name}}" {{flags}}

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
