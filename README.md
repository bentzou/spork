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
├── .spork/
│   ├── config              # ORIGIN_URL / TRUNK_BRANCH / CLONE_PREFIX
│   ├── runtime/            # mirror.git, sync.log, lock files (gitignored)
│   ├── tools/              # symlink to spork repo's tools/, or a copy
│   └── hooks/              # optional per-workspace bootstrap scripts
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

Pick whichever of these you prefer:

**Symlink the tools (recommended — get updates by `git pull`ing this repo):**

```sh
git clone git@github.com:bentzou/spork.git ~/Code/spork
mkdir -p ~/Code/myrepo/.spork
ln -s ~/Code/spork/tools ~/Code/myrepo/.spork/tools
cp ~/Code/spork/examples/config.example ~/Code/myrepo/.spork/config
$EDITOR ~/Code/myrepo/.spork/config            # set ORIGIN_URL etc.
cp ~/Code/spork/examples/justfile.example ~/Code/myrepo/justfile
```

**Or vendor (just copy in — frozen at install time):**

```sh
git clone git@github.com:bentzou/spork.git /tmp/spork
mkdir -p ~/Code/myrepo/.spork
cp -r /tmp/spork/tools ~/Code/myrepo/.spork/
cp /tmp/spork/examples/config.example ~/Code/myrepo/.spork/config
cp /tmp/spork/examples/justfile.example ~/Code/myrepo/justfile
```

Then either clone the upstream once into `<CLONE_PREFIX>1/` and run
`just sync-setup` (mirror seeds from your existing clone — no full
re-fetch), or run `just sync-setup` first against an empty workspace and
follow with `just setup-clone` to create clones one at a time.

## Config

`.spork/config` is sourced as bash. Required:

| Var | Meaning |
| --- | --- |
| `ORIGIN_URL` | Upstream URL — only matching clones are tracked. |
| `TRUNK_BRANCH` | Branch that `just sync` ff-merges; others are fetch-only. |
| `CLONE_PREFIX` | Prefix `setup-clone` uses for new clones. Default `p`. |

## Recipes

The recipes in `examples/justfile.example` wrap the scripts in `tools/`:

| Command | What it does |
| --- | --- |
| `just status` | One-line status per clone (no network). |
| `just sync` | Status table, then a background fetch/pull via the mirror. |
| `just pull` | Foreground ff-merge of trunk in every clean clone. |
| `just fetch` | Foreground fetch in every clone. |
| `just sync-setup` | One-time: create the mirror and link existing clones. |
| `just setup-clone` | Create the next `<CLONE_PREFIX><N>` clone, wired to the mirror. No network. |
| `just go` | Print the path of the first ready clone (for shell `cd`). |

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

## Hooks

Per-workspace bootstrap (e.g. `bun install`, `pnpm install`) goes in
`.spork/hooks/`. Spork ships no defaults — drop in only what your repo
needs.

| Hook | When | Args |
| --- | --- | --- |
| `post-clone` | After `setup-clone` finishes the trunk checkout. | `$1` = absolute path of the new clone. |

A hook is invoked iff it exists and is executable. Non-zero exit aborts
the calling recipe but leaves the clone in place — fix the underlying
issue and re-run the hook directly:

```sh
.spork/hooks/post-clone /path/to/clone
```

To disable a hook without deleting it: `chmod -x .spork/hooks/<name>`.

See `examples/post-clone.example` for a working `bun install` hook.

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
├── tools/                  # the scripts behind the just recipes
├── examples/
│   ├── config.example      # template for .spork/config
│   ├── justfile.example    # spork-related just recipes
│   └── post-clone.example  # example hook (bun install)
└── README.md
```

`tools/_lib.sh` is sourced by every other script and derives all paths
from its own location, so the directory can live anywhere.
