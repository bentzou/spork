# spork

Multi-clone workspace for a single git repo. Lets you keep a handful of
checkouts of the same upstream side-by-side (e.g. one per agent, one per
in-flight branch) without paying disk or network for redundant `.git` data.

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
│   └── runtime/            # mirror.git, sync.log, lock files
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

## Config

`.spork.local/config` is sourced as bash. Required:

| Var | Meaning |
| --- | --- |
| `ORIGIN_URL` | Upstream URL — only matching clones are tracked. |
| `TRUNK_BRANCH` | Branch that `just sync` ff-merges; others are fetch-only. |
| `CLONE_PREFIX` | Prefix `clone` uses for new clones. Default `p`. |

## Recipes

The recipes in `examples/justfile.example` wrap the scripts in `tools/`:

| Command | What it does |
| --- | --- |
| `just status` | One-line status per clone (no network). |
| `just sync` | Status table, then a background fetch/pull via the mirror. |
| `just pull` | Foreground ff-merge of trunk in every clean clone. |
| `just fetch` | Foreground fetch in every clone. |
| `just sync-setup` | One-time: create the mirror and link existing clones. |
| `just clone` | Create the next `<CLONE_PREFIX><N>` clone, wired to the mirror. No network. |
| `just go` | Print the path of the first ready clone (for shell `cd`). |

### Customizing the recipe menu

`examples/justfile.example` lists every recipe alphabetically; tailor
your workspace's `justfile` to taste:

- **Hide internal recipes** with `[private]` so `just --list` doesn't
  surface them. Useful for `fetch` / `sync-setup` / `sync` once
  everything is set up.
- **Control ordering** with `just --list --unsorted` from a `default`
  recipe, then arrange recipes in source order:
  ```
  [private]
  default:
      @just --list --unsorted
  ```
- **Group recipes** with `[group('name')]` for a separator (and a
  header) between buckets. Example output:
  ```
  Available recipes:
      [use]
      claude # ...
      go     # ...

      [manage]
      status # ...
      pull   # ...
      clone  # ...
  ```

## "Ready" definition

A clone is **ready** when:

- HEAD is on `TRUNK_BRANCH`,
- working tree is clean (`git status --porcelain` empty),
- in sync with `origin/$TRUNK_BRANCH` (no ahead/behind).

`just go` picks the first ready clone in iteration order.

## Status table columns

```
REPO  BRANCH  STATE  AGE
```

- **STATE** — single word per clone:
  - `ready` (green) — see above.
  - `branch` (cyan) — checked out on a non-trunk branch.
  - `local` (yellow) — uncommitted changes on trunk.
  - `pull` / `push` (yellow) — trunk diverged from upstream.
- **AGE** — time since the most recent Claude session jsonl in
  `~/.claude/projects/<encoded-path>*/*.jsonl` was written, where
  `<encoded-path>` is the clone's absolute path with `/` → `-`. Subdir
  sessions count too. Red once a clone hasn't been touched in ≥ 7 days.
  Blank for ready clones.

  This column assumes you use [Claude Code](https://claude.ai/code) and
  reflects when you last worked in each clone with it. If you don't, the
  column will just show `—` everywhere.

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
jc () { local p; p=$(builtin cd ~/Code/myrepo && just go) || return; builtin cd "$p"; claude; }
```

Mirror this block per workspace with a different prefix (`xs`/`xg`/`xc`,
etc.) if you spork more than one repo.

## Repo layout

```
spork/
├── init                    # workspace bootstrap (run once per workspace)
├── tools/                  # the scripts behind the just recipes
├── examples/
│   ├── config.example      # template for .spork.local/config
│   └── justfile.example    # spork-related just recipes
└── README.md
```

`tools/_lib.sh` is sourced by every other script and derives all paths
from its own location, so the directory can live anywhere.
