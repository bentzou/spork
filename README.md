# spork

Multi-clone workspace for a single git repo. Keep a handful of checkouts
of the same upstream side-by-side (one per agent, one per in-flight
branch) without paying disk or network for redundant `.git` data — every
clone shares one local mirror, so clones are cheap to create and one
background fetch updates them all.

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

`open` means free to grab; `in use` means someone is in it right now;
`parked` means unfinished work is sitting there (a feature branch checked
out, or a dirty tree). SESSION and AGE come from each clone's most recent
Claude Code or Codex session; AGENT records which backend owns or last touched
the session. PR links the branch's open pull request. (`js`/`jc` are optional
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

`init` is idempotent — safe to re-run after pulling spork updates. The
workspace `justfile` imports spork's recipes through the `.spork` symlink,
so `git -C ~/Code/spork pull` updates every workspace at once. Add your
own recipes (or override shared ones) below the import.

### Config

`.spork.local/config`:

| Var | Meaning |
| --- | --- |
| `ORIGIN_URL` | Upstream URL — only matching clones are tracked. |
| `TRUNK_BRANCH` | The branch `just sync` keeps up to date. |
| `CLONE_PREFIX` | Naming prefix for new clones. Default `p`. |
| `POST_CLONE` | Optional command run inside each new clone, e.g. `bun install`. |
| `SPORK_AGENTS` | Agent backends to scan. Default `claude codex`. |
| `SPORK_LIVE_COMMANDS` | Process names whose cwd marks a clone occupied. Default `claude codex zsh bash fish`. |

## Commands

| Command | What it does |
| --- | --- |
| `just status` | One-line status per clone (no network). |
| `just log [N]` | Recent Claude and Codex sessions across the pool, newest first. |
| `just log-claude [N]` | Recent Claude sessions only. |
| `just log-codex [N]` | Recent Codex sessions only. |
| `just sync` | Status table, then a background fetch/pull via the mirror. |
| `just pull` | Foreground ff-merge of trunk in every clean clone. |
| `just fetch` | Foreground fetch in every clone. |
| `just clone` | Create the next clone, wired to the mirror. No network. |
| `just go` | Print the path of the first open clone (for shell `cd`). |
| `just claude [args…]` | Claim the first open clone and start Claude in it; args go to the CLI (e.g. `just claude "hello world"`). |
| `just codex [args…]` | Claim the first open clone and start Codex in it; args go to the CLI. |
| `just resume <id\|name>` | Reopen a Claude or Codex session by `just log` ID — or a clone's latest by name. |
| `just resume-claude <id\|name>` | Reopen only a Claude session. |
| `just resume-codex <id\|name>` | Reopen only a Codex session. |
| `just clean <name>` | Return a clone to `open`: latest trunk, clean tree, branches kept. |
| `just sync-setup` | One-time: create the mirror and link existing clones. |

Worth knowing:

- `just go` / `just claude` hand out the first **open** clone — on trunk,
  clean, in sync, and nobody in it. Concurrent grabs get different clones,
  and sessions you open by hand inside a clone are detected too, so it
  won't hand out a clone someone is sitting in.
- `just resume` takes a session ID from `just log` (a prefix is fine) or a
  clone name — `just resume p3` reopens whatever Claude or Codex session was
  last active in p3. It refuses a clone that already has an agent running.
- `just clean` never touches local branches, and refuses to discard work
  that exists nowhere else unless you pass `--force`. `--full` also wipes
  ignored files and reruns `POST_CLONE` — factory-new rather than merely
  grabbable.

## How it works

All clones share a single object store, which is what makes cloning and
syncing cheap. `just sync-setup` creates one bare mirror of the upstream
repo; each clone's `.git/objects/info/alternates` points at the mirror's
objects, so the repo's history lives on disk exactly once no matter how
many clones you keep.

- `just clone` is a `git init` plus a local ref fetch from the mirror —
  no network at all, and near-zero new disk.
- `just sync` hits the network exactly once (a single fetch into the
  mirror), then each clone fetches from the mirror locally. Adding more
  clones never adds parallel downloads of the same objects.
- `just pull` / `just fetch` are the exception: they talk to origin
  directly, once per clone, for when you want a foreground update.

## Shell shortcuts (optional)

Shorter aliases have to live in your shell config because they need to
`cd` your real shell:

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

Mirror this block per workspace with a different prefix (`xs`/`xg`/`xc`,
etc.) if you spork more than one repo.
