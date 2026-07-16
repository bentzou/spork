# spork

Multi-clone workspace for a single git repo. Lets you keep a handful of
checkouts of the same upstream side-by-side (e.g. one per agent, one per
in-flight branch) without paying disk or network for redundant `.git` data.

```
$ just status
REPO  SESSION                        STATE   AGE   BRANCH
p1    Build search index syncer      in use  2m    feat/search-index-sync
p3    Fix image cache expiry bug     parked  5d    fix/image-cache-expiry
p4    Spike: sqlite cache backend    parked  12d   main*  ← stale: AGE turns red after 7d
p5    Abstract the storage backend   in use  1d    feat/storage-interfaces
p2                                   open          main
p6                                   open          main
```

`STATE` answers "can I pick this clone up?" — `open` means yes; `in use`
means someone is in it right now (a live Claude session, or a terminal
parked in the clone); `parked` means unfinished work blocks it, with
BRANCH saying what kind (a feature branch, or `main*` where `*` marks
uncommitted changes). `AGE` is the time since you last
worked in that clone with Claude Code; `SESSION` is the title of that
most-recent Claude session, so you can tell at a glance *what* each
in-flight clone was for — not just that it's busy. (Open clones sort to
the bottom with no AGE or SESSION — a free clone's history isn't
decision-relevant.)

## Concept

Many parallel clones of the same repo cost a lot — each `.git` is hundreds
of megabytes, every `git fetch` re-downloads the same packs, and you end
up with N copies of identical objects.

spork solves this by giving every clone in a workspace the same shared
bare mirror as a git alternates source. One network fetch updates all
clones' view of the world.

## Layout

```
<workspace>/
├── .spork           -> /path/to/spork-repo  (symlink, shared)
├── .spork.local/                            (workspace-specific)
│   ├── config              # ORIGIN_URL / TRUNK_BRANCH / CLONE_PREFIX / POST_CLONE
│   └── runtime/            # mirror.git, sync.log, lock files, claims/
├── justfile                # workspace's just recipes (see examples/)
├── p1/                     # clones, named <CLONE_PREFIX><N>
├── p2/
└── p3/
```

A clone is "in this workspace" iff its `remote.origin.url` matches
`ORIGIN_URL`. Anything else under the workspace dir is ignored.

## Mirror

`runtime/mirror.git` is a single shared bare clone. Each working clone has:

- `.git/objects/info/alternates` pointing at the mirror, so the same packs
  serve every clone.
- A `mirror` remote with fetchspec `+refs/heads/*:refs/remotes/origin/*`,
  so `git fetch mirror` updates `origin/*` tracking refs locally without
  touching the network.
- `origin` pointing at the upstream URL — untouched, so `git push` and any
  manual `git fetch origin` behave normally.

Net effect: one network fetch (in the background, via `just sync`) updates
every clone's view of the world.

## Install in a workspace

```sh
git clone git@github.com:bentzou/spork.git ~/Code/spork    # once, anywhere

mkdir -p ~/Code/myrepo && cd ~/Code/myrepo
ln -s ~/Code/spork .spork
./.spork/init
$EDITOR .spork.local/config                                # ORIGIN_URL etc.
just sync-setup
just clone
```

`init` creates `.spork.local/{config,runtime/}` (workspace-specific) and
a workspace `justfile` if one doesn't exist. It's idempotent — safe to
re-run after pulling spork updates.

The `.spork` symlink stays in sync with this repo via `git -C ~/Code/spork
pull` from any of your sporked workspaces; the tools all dispatch through
the symlink.

## Recipes & the workspace justfile

The recipes live in `spork.just` at the repo root. A workspace doesn't copy
them — its `justfile` **imports** them through the symlink:

```just
set shell := ["bash", "-uc"]
set allow-duplicate-recipes := true

import '.spork/spork.just'

[private]
default:
    @just --list --unsorted

# workspace-specific recipes / overrides go here
```

So `spork.just` is the single source of truth, and `git -C ~/Code/spork pull`
updates every workspace's recipes at once — no per-workspace copy to keep in
sync. `init` writes this stub (it's `examples/justfile.example`) for new
workspaces.

To customize a workspace, add recipes below the import, or **override** a
shared recipe by redefining it — `set allow-duplicate-recipes` lets the local
definition win. For example, a monorepo whose app lives in a subdir overrides
`claude`/`go` to `cd "$path/SUBDIR"` while inheriting everything else.

## Config

`.spork.local/config` is sourced as bash. Required:

| Var | Meaning |
| --- | --- |
| `ORIGIN_URL` | Upstream URL — only matching clones are tracked. |
| `TRUNK_BRANCH` | Branch that `just sync` ff-merges; others are fetch-only. |
| `CLONE_PREFIX` | Prefix `clone` uses for new clones. Default `p`. |

Optional: `POST_CLONE` (see below) and `SPORK_LIVE_COMMANDS` (see
[Claims & occupancy](#claims--occupancy)).

## Recipes

The recipes in `spork.just` wrap the scripts in `tools/`:

| Command | What it does |
| --- | --- |
| `just status` | One-line status per clone (no network). |
| `just log [N]` | Recent Claude sessions across the pool, newest first (no network). |
| `just sync` | Status table, then a background fetch/pull via the mirror. |
| `just pull` | Foreground ff-merge of trunk in every clean clone. |
| `just fetch` | Foreground fetch in every clone. |
| `just sync-setup` | One-time: create the mirror and link existing clones. |
| `just clone` | Create the next `<CLONE_PREFIX><N>` clone, wired to the mirror. No network. |
| `just go` | Print the path of the first open (ready, unoccupied) clone (for shell `cd`). |
| `just claude` | Claim the first open clone and start Claude in it. |
| `just restart <id>` | Reopen a Claude session from `just log` by its ID, in its clone. |

## "Ready" definition

A clone is **ready** when:

- HEAD is on `TRUNK_BRANCH`,
- working tree is clean (`git status --porcelain` empty),
- in sync with `origin/$TRUNK_BRANCH` (no ahead/behind).

`just go` picks the first ready, unoccupied clone in iteration order
(**open** in the status table).

## Claims & occupancy

Opening a session in a clone doesn't change its git state, so a freshly
opened clone still looks **ready** — which means two terminals each running
`jc`/`just claude` would otherwise both land in the *same* clone. Occupancy
is tracked two ways, and a clone counts as occupied if *either* says so:

**Claims** record intent. A claim is the directory `runtime/claims/<clone>`,
holding a `pid` file with the owning process. `just claude` (and the `jc`
shortcut) grabs the first ready clone by atomically creating that directory —
`mkdir` is atomic, so concurrent invocations grab different clones instead
of colliding.

A claim is **live** only while its owner PID is running, so it self-heals:

- normal exit releases the claim promptly,
- a crash or `kill -9` that skips the release leaves a claim whose owner is
  gone — the next claim reclaims it. No background reaper, no stale locks.

The owner PID is the shell/session that lives for the duration of the work
(your interactive shell for `jc`, the recipe's shell for `just claude`).

**Process detection** records observation. Sessions opened *outside* the
wrappers — you `cd` into a clone and run `claude` by hand, or just leave a
terminal tab parked there — never create a claim, so spork also sweeps for
live claude/shell processes whose cwd is inside a clone (one `pgrep`+`lsof`
pass, ~1s, cached per command). Any hit marks the clone `in use`, and
`just go` / `just claude` skip it. `just restart` refuses a clone with a
claude running in it, but tolerates a bare terminal — you're deliberately
returning, and that shell may well be your own. The watched process list is
`claude zsh bash fish`; override `SPORK_LIVE_COMMANDS` in config if your
shell isn't on it. Detection is best-effort (it can't see other users'
processes), and if `pgrep`/`lsof` are unavailable occupancy quietly falls
back to claims alone.

Detection can't replace claims: an `lsof` snapshot has a wide window between
"looks free" and "claude is actually running there", so two concurrent grabs
would both see free. The atomic claim is what makes the race safe; the sweep
is what keeps the table honest.

## Status table columns

```
REPO  SESSION  STATE  AGE  BRANCH
```

- **STATE** — one verdict per clone: can you pick it up, and if not, why?
  - `open` (green) — ready (see above) and nobody in it. What `jc` hands you.
  - `in use` (yellow) — someone is in it now: a live claim, or a claude/shell
    process detected inside the clone (see [Occupancy](#claims--occupancy)).
    Overrides git state; reverts when they leave.
  - `parked` (cyan) — unfinished work blocks a clean pickup: checked out on a
    non-trunk branch and/or a dirty tree. BRANCH says which — a feature
    branch name, and/or a `*` suffix marking uncommitted changes.
  - `pull` / `push` (yellow) — on trunk and clean, but behind/ahead of
    upstream.
  - `broken` (red) — git can't read the repo.
- **AGE** — time since the most recent Claude session jsonl in
  `~/.claude/projects/<encoded-path>*/*.jsonl` was written, where
  `<encoded-path>` is the clone's absolute path with `/` → `-`. Subdir
  sessions count too. Red once a clone hasn't been touched in ≥ 7 days.
  Blank for open clones.

  This column assumes you use [Claude Code](https://claude.ai/code) and
  reflects when you last worked in each clone with it. If you don't, the
  column will just show `—` everywhere.
- **SESSION** — title of that same most-recent session: the `aiTitle`
  Claude Code records for it (the auto-generated name shown in its
  picker). Free-text, truncated past 56 columns. Blank for open clones;
  `—` when the clone has no session. Lets you read the table as "*p3* is
  mid-flight on the *cache expiry* work" without opening anything. Set
  `CLAUDE_PROJECTS_DIR` to point the AGE/SESSION lookups at a non-default
  sessions root.
- **BRANCH** — the clone's current branch. It's the trailing column (a
  branch name has no spaces, so it's safe to leave unpadded after the
  free-text SESSION title).

## Session log

Where `just status` shows the *current* state of each clone (one row per
clone), `just log` shows recent *activity* (one row per Claude session)
across the whole pool, newest first:

```
$ just log
AGE   REP   ID         SESSION
2m    p3    feb693a8   Create spec for image exports        (in use)
1h    p2    686c1b22   Fix dark mode flash on initial page load
3h    p2    a6060d87   Debug websocket reconnect backoff issue
1d    p10   4082b292   Debug RSS feed parser issue
…
```

A clone can appear on several rows — once per session you've worked in it,
**including sessions you've already closed** (every session leaves its
`*.jsonl` log behind). `AGE` is time since that session was last touched
(red past 7 days); `REP` is the clone; `ID` is a short session-id handle
(see `just restart` below); `SESSION` is its `aiTitle`, or `—` if it never
got one.

Rows whose clone is occupied (a live claim, or a claude/shell process
detected inside it — see [Claims & occupancy](#claims--occupancy)) are
marked **`(in use)`** (yellow on a terminal). A clone with a claude already
running can't be cleanly resumed — only one Claude can run per clone — so
`just restart` will refuse it; the marker tells you that up front, before
you copy an id.

`just log` shows the 20 most recent by default. Pass a count for more or
fewer (`just log 50`), or `all` for the full history (`just log all`). It
reads the same sessions root as the status table's AGE/SESSION columns,
overridable via `CLAUDE_PROJECTS_DIR`.

### Resuming a session

`just restart <id>` reopens a logged session where you left off. Copy the
`ID` from `just log` (a prefix is fine — restart resolves it, and asks for
more characters only if it's ambiguous):

```
$ just restart feb693a8
```

It finds the clone the session belongs to, claims it for your shell (the
same self-freeing claim as `just claude`, released when you exit), and runs
`claude --resume` from the session's original launch directory — so a
monorepo subdir session reopens in that subdir, not the clone root. If that
clone is currently in use by another live session, restart refuses rather
than dropping a second Claude into it (the `(in use)` marker in `just log`
flags those up front). The git state of the clone is left as-is: you return
to whatever branch/working tree it's on now.

## Post-clone bootstrap

Set `POST_CLONE` in `.spork/config` to run a command inside each new
clone after `clone` finishes the trunk checkout — e.g. installing
dependencies. Spork ships no default; leave it empty to skip.

```sh
POST_CLONE='bun install'
POST_CLONE='pnpm install && pnpm run prepare'
POST_CLONE=./scripts/setup-new-clone.sh
```

The value is `eval`'d in a subshell with cwd set to the new clone.
Non-zero exit aborts `clone` but leaves the clone on disk — fix
the cause and re-run the command manually in that directory.

## Convenience shell shortcuts (optional)

The recipes work fine on their own. If you want shorter shell aliases —
they have to live in your shell config because they need to `cd` your
real shell — here's a pattern:

```bash
alias js='builtin cd ~/Code/myrepo && just sync'
jg () { local p; p=$(builtin cd ~/Code/myrepo && just go) || return; builtin cd "$p"; }
# Claim a ready clone, run Claude, then release it. $$ is the interactive
# shell — it owns the claim, so a closed terminal frees the clone (see Claims).
jc () {
   local p
   p=$(builtin cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$") || return
   builtin cd "$p"
   claude
   ( builtin cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
```

`jc` calls `claim.sh` directly (not via `just`) so the claim is owned by your
interactive shell, not a short-lived `just` process that exits immediately.

Mirror this block per workspace with a different prefix (`xs`/`xg`/`xc`,
etc.) if you spork more than one repo.

## Repo layout

```
spork/
├── init                    # workspace bootstrap (run once per workspace)
├── spork.just              # shared recipes, imported by each workspace justfile
├── tools/                  # the scripts behind the just recipes
├── examples/
│   ├── config.example      # template for .spork.local/config
│   └── justfile.example    # the thin workspace justfile stub init writes
└── README.md
```

`tools/_lib.sh` is sourced by every other script and derives all paths
from its own location, so the directory can live anywhere.
