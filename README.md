# spork

spork keeps a pool of clones of your repo (`p1`, `p2`, `p3`, …) and
places you into the next available one.

- `just claude` / `just codex` — grabs a free clone and starts a
  session in it
- `just status` — shows which session lives where
- `just resume` — picks a past session back up

The clones share one local git mirror, so they're cheap to create and
one download updates them all.

```
$ just status
REP  SESSION                      STATE   AGENT
p1   Fix image cache expiry bug   in use  Claude
p2   Spike: sqlite cache backend  parked  Codex
p3                                open
p4                                open

$ just claude                # starts claude in p3
$ just claude hello world    # starts claude with that prompt
$ just codex                 # starts codex

$ just log
AGE  AGENT   REP  ID        SESSION
2m   Claude  p1   feb693a8  Fix image cache expiry bug    (in use)
5d   Codex   p2   4082b292  Spike: sqlite cache backend

$ just resume p2             # reopens p2's last session
```

## Setup

```sh
git clone git@github.com:bentzou/spork.git ~/Code/spork    # once, anywhere

mkdir -p ~/Code/myrepo && cd ~/Code/myrepo    # will hold all the clones
ln -s ~/Code/spork .spork                     # wires spork into the workspace
./.spork/init git@github.com:me/myrepo.git    # config + mirror + first clone
just clone                                    # repeat to grow the pool
```

`init` is safe to re-run, and everything spork creates lives inside the
workspace directory — delete the directory to undo setup entirely.

### Config

`init` fills in `.spork.local/config` for you. The one setting worth
adding by hand is `POST_CLONE` — a command run inside each new clone,
e.g. `POST_CLONE='bun install'`. The file's comments explain the rest.

## How it works

`just sync-setup` creates one shared mirror of your repo, and every
clone borrows its git history from it. So history is stored on disk
only once no matter how many clones you have, `just clone` needs no
network and almost no disk, and `just sync` downloads new commits once
and hands them to every clone.

## Why full clones instead of worktrees?

Isolation. Worktrees share branches, config, and hooks, so with several
agents working at once you get collisions. Each spork clone is a
complete, ordinary repo — whatever an agent does in one can't affect the
others. And the shared mirror means this costs no more disk than
worktrees would.

## Commands

### use — grab a clone and work in it

| Command | What it does |
| --- | --- |
| `just claude "hello world"` | Grab the first open clone and start Claude Code in it, with an optional starting prompt. |
| `just codex "hello world"` | Same, but starts Codex. |
| `just go` | Print the path of the first open clone (for shell `cd`). |

### manage — take care of the pool

| Command | What it does |
| --- | --- |
| `just clone` | Add a new clone to the pool. No network. |
| `just log [N]` | List recent sessions across all clones, newest first. |
| `just pull` | Update trunk in every clean clone (waits for it). |
| `just clean <name>` | Reset a clone back to `open`: latest trunk, clean tree, branches kept. |
| `just status` | Show every clone's state. No network. |

### plumbing — everything else

| Command | What it does |
| --- | --- |
| `just resume <id\|name>` | Reopen a past session by `just log` ID — or a clone's latest by name. |
| `just resume-claude <id\|name>` | Same, Claude sessions only. |
| `just resume-codex <id\|name>` | Same, Codex sessions only. |
| `just log-claude [N]` | Recent Claude sessions only. |
| `just log-codex [N]` | Recent Codex sessions only. |
| `just sync` | Show status, then update everything in the background. |
| `just fetch` | `git fetch` in every clone (waits for it). |
| `just sync-setup` | One-time: create the shared mirror and link existing clones. |

## Shell shortcuts (optional)

These have to live in your shell config because they need to `cd` your
real shell:

```bash
alias js='builtin cd ~/Code/myrepo && just status'
jg () { local p; p=$(builtin cd ~/Code/myrepo && just go) || return; builtin cd "$p"; }
jc () {
   local p
   p=$(builtin cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$") || return
   builtin cd "$p"
   claude "$@"
   ( builtin cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
```

For Codex, make a `jx` the same way with `claim.sh "$$" codex` and
`codex "$@"`. Copy this block per workspace with a different prefix
(`xs`/`xg`/`xc`, etc.) if you spork more than one repo.
