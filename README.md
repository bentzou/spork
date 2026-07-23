# spork

Run multiple Claude Code and Codex sessions on one repo, side by side.
spork keeps a pool of clones (`p1`, `p2`, `p3`, …): one command grabs a
free clone and starts a session in it, `just status` shows which session
lives where, and `just resume` reopens any past session where you left
off. The clones share one local git mirror, so extra clones cost almost
no disk and a single download updates them all.

```
$ just status                                   # js
REP  SESSION                        STATE   AGENT   AGE  PR     BRANCH
p1   Build search index syncer      in use  Claude  2m   #4269  feat/search-index-sync
p3   Fix image cache expiry bug     parked  Claude  5d          fix/image-cache-expiry
p4   Spike: sqlite cache backend    parked  Codex   12d         main
p5   Abstract the storage backend   in use  Codex   1d   #4301  feat/storage-interfaces
p2                                  open                       main
p6                                  open                       main

$ just claude                                   # jc
# claims p2 — the first open clone — and opens Claude Code in it;
# p2 shows as "in use" until you exit

$ just claude hello world                       # jc hello world
# same, but starts the session with the prompt "hello world" —
# bare words are joined; quotes work too

$ just codex
# same picker/claim behavior, but opens Codex instead

$ just log
AGE  AGENT   REP  ID        SESSION
2m   Claude  p1   feb693a8  Build search index syncer            (in use)
1d   Codex   p5   4082b292  Abstract the storage backend         (in use)
5d   Claude  p3   686c1b22  Fix image cache expiry bug
5d   Claude  p3   a6060d87  Debug websocket reconnect backoff
12d  Codex   p4   9c1f22e0  Spike: sqlite cache backend

$ just resume p3                                # or: just resume 686c1b22
# reopens p3's most recent Claude or Codex session where you left off
```

Each clone is in one of three states: `open` (free to grab), `in use`
(an agent or shell is in it right now), or `parked` (unfinished work is
sitting there — a feature branch checked out, or uncommitted changes).
SESSION and AGE come from the clone's most recent Claude Code or Codex
session; AGENT is which tool ran it; PR is the branch's open pull
request. (`js`/`jc` are optional
[shell shortcuts](#shell-shortcuts-optional).)

## Setup

```sh
git clone git@github.com:bentzou/spork.git ~/Code/spork    # once, anywhere

mkdir -p ~/Code/myrepo && cd ~/Code/myrepo
ln -s ~/Code/spork .spork
./.spork/init
$EDITOR .spork.local/config      # set ORIGIN_URL etc.
just sync-setup                  # one-time: create the shared mirror
just clone                       # create your first clone
```

`init` is safe to re-run after updating spork. The workspace `justfile`
imports spork's recipes through the `.spork` symlink, so
`git -C ~/Code/spork pull` updates every workspace at once. Add your own
recipes (or override the shared ones) below the import.

### Config

`.spork.local/config`:

| Var | Meaning |
| --- | --- |
| `ORIGIN_URL` | URL of the repo to clone. Only clones of this repo are tracked. |
| `TRUNK_BRANCH` | The main branch to keep up to date. |
| `CLONE_PREFIX` | Name prefix for clones (`p1`, `p2`, …). Default `p`. |
| `POST_CLONE` | Command to run inside each new clone, e.g. `bun install`. |
| `SPORK_AGENTS` | Which agents to look for. Default `claude codex`. |
| `SPORK_LIVE_COMMANDS` | Programs that count as "someone is in this clone". Default `claude codex zsh bash fish`. |

## Commands

Grouped the same way the `just` menu shows them.

### use — grab a clone and work in it

| Command | What it does |
| --- | --- |
| `just claude [args…]` | Grab the first open clone and start Claude Code in it; args go to the CLI. |
| `just codex [args…]` | Same, but starts Codex. |
| `just go` | Print the path of the first open clone (for shell `cd`). |
| `just resume <id\|name>` | Reopen a past session by `just log` ID — or a clone's latest by name. |
| `just resume-claude <id\|name>` | Same, Claude sessions only. |
| `just resume-codex <id\|name>` | Same, Codex sessions only. |

### manage — take care of the pool

| Command | What it does |
| --- | --- |
| `just clone` | Add a new clone to the pool. No network. |
| `just log [N]` | List recent sessions across all clones, newest first. |
| `just log-claude [N]` | Same, Claude sessions only. |
| `just log-codex [N]` | Same, Codex sessions only. |
| `just pull` | Update trunk in every clean clone (waits for it). |
| `just clean <name>` | Reset a clone back to `open`: latest trunk, clean tree, branches kept. |
| `just status` | Show every clone's state. No network. |

### plumbing — hidden from the `just` menu, still callable

| Command | What it does |
| --- | --- |
| `just sync` | Show status, then update everything in the background. |
| `just fetch` | `git fetch` in every clone (waits for it). |
| `just sync-setup` | One-time: create the shared mirror and link existing clones. |

Worth knowing:

- `just go` / `just claude` hand out the first **open** clone — one
  that's on trunk, clean, up to date, and empty. Two grabs at the same
  time get different clones, and sessions you start by hand inside a
  clone are noticed too, so it won't hand out a clone someone is
  sitting in.
- `just resume` takes a session ID from `just log` (a prefix is enough)
  or a clone name — `just resume p3` reopens whatever session was last
  active in p3. It won't touch a clone that already has an agent
  running.
- `just clean` never deletes local branches, and refuses to throw away
  work that exists nowhere else unless you pass `--force`. `--full`
  also removes ignored files and reruns `POST_CLONE` — factory-new
  rather than merely grabbable.

## How it works

All the clones share one object store. `just sync-setup` creates a
single bare mirror of your repo; each clone points at the mirror's
objects (via git "alternates"), so the repo's history is stored on disk
only once no matter how many clones you keep.

That's why everything stays cheap:

- `just clone` downloads nothing — it's a `git init` plus a local fetch
  from the mirror. No network, almost no new disk.
- `just sync` downloads from origin once (into the mirror), then each
  clone updates from the mirror locally. More clones never means more
  downloads.
- `just pull` / `just fetch` are the exception: they talk to origin
  directly, once per clone, for when you want a foreground update.

## Why full clones instead of worktrees?

Isolation. Worktrees share branches, config, and hooks, so with several
agents working at once you get collisions. Each spork clone is a
complete, ordinary repo — whatever an agent does in one can't affect the
others. And the shared mirror means this costs no more disk than
worktrees would.

## Shell shortcuts (optional)

These have to live in your shell config because they need to `cd` your
real shell:

```bash
alias js='builtin cd ~/Code/myrepo && just sync'
jg () { local p; p=$(builtin cd ~/Code/myrepo && just go) || return; builtin cd "$p"; }
jc () {
   local p
   case " $* " in *" -"*) ;; *) [ $# -gt 1 ] && set -- "$*";; esac
   p=$(builtin cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$") || return
   builtin cd "$p"
   printf '\033]0;%s\007' "${p##*/}"
   claude "$@"
   ( builtin cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
jx () {
   local p
   case " $* " in *" -"*) ;; *) [ $# -gt 1 ] && set -- "$*";; esac
   p=$(builtin cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$" codex) || return
   builtin cd "$p"
   printf '\033]0;%s\007' "${p##*/}"
   codex "$@"
   ( builtin cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
```

Copy this block per workspace with a different prefix (`xs`/`xg`/`xc`,
etc.) if you spork more than one repo.
