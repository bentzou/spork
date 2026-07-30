# spork

spork is a pool manager for coding-agent workspaces. It keeps clones
of your repo (`p1`, `p2`, `p3`, …) and drops you into the next free
one.

- `just claude` / `just codex` — grabs a free clone and starts a
  session in it
- `just status` — shows which session lives where
- `just sync` — updates every clone in the background
- `just resume` — picks a past session back up

The clones share one local git mirror. Cheap to create, one download
updates them all.

### Start a new session

```console
$ just sync                  # prints status, syncs in background
REP  SESSION                      STATE   AGENT
p1   Fix image cache expiry bug   in use  Claude
p2   Spike: sqlite cache backend  parked  Codex
p3                                open
p4                                open

$ just claude [my prompt]    # starts claude in p3

# just codex                 # or codex
```

### Return to a previous session

```console
$ just log
AGE  AGENT   REP  ID        SESSION
2m   Claude  p1   feb693a8  Fix image cache expiry bug    (in use)
5d   Codex   p2   4082b292  Spike: sqlite cache backend

$ just resume p2             # reopens p2's last session
```

### Or use the [shell shortcuts](#shell-shortcuts)

```console
$ js                         # just sync - prints status, updates in background
REP  SESSION                      STATE   AGENT
p1   Fix image cache expiry bug   in use  Claude
p2   Spike: sqlite cache backend  parked  Codex

$ jc [my prompt]             # just claude - starts claude in next open clone

# jx [my prompt]             # or codex
```

## Setup

### New workspace

```console
$ git clone git@github.com:bentzou/spork.git ~/Code/spork    # once, anywhere

$ mkdir -p ~/Code/myrepo && cd ~/Code/myrepo    # will hold all the clones
$ ln -s ~/Code/spork .spork                     # wires spork into the workspace

$ ./.spork/init git@github.com:me/myrepo.git
Initialized spork workspace
  Cloning mirror from origin (one-time, full history) ..... done
  Cloned p1 → main @ 9da80fe

Workspace ready. Try `just status`, then `just claude` to grab p1.

$ just clone                                    # repeat to grow the pool
Cloned p2 → main @ 9da80fe
```

`init` is safe to re-run, and everything spork creates lives inside the
workspace directory — delete the directory to undo setup entirely.

### Shell shortcuts

Add these to your shell config to jump into a free clone from
anywhere:

```bash
js () { cd ~/Code/myrepo && just sync; }
jc () {
   local p
   p=$(cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$") || return
   cd "$p"
   claude "$@"
   ( cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
jx () {
   local p
   p=$(cd ~/Code/myrepo && ./.spork/tools/claim.sh "$$" codex) || return
   cd "$p"
   codex "$@"
   ( cd ~/Code/myrepo && ./.spork/tools/release.sh "$p" "$$" )
}
```

## How it works

`just sync-setup` creates one shared mirror of your repo, and every
clone borrows its git history from it. History lives on disk once, no
matter how many clones you have. `just clone` needs no network and
almost no disk. `just sync` downloads new commits once and hands them
to every clone.

### Why full clones instead of worktrees?

The pool layer — claiming, status, sessions, sync — doesn't care what
a unit is made of. spork uses full clones because the isolation is
simpler and more complete: worktrees share branches, config, and
hooks, so several agents working at once collide, while a clone is a
full, ordinary repo — whatever an agent does in one can't affect the
others, and deleting the directory removes it entirely. And the
shared mirror means this costs no more disk than worktrees would.
A worktree backend may still be added later.

## Config

`init` fills in `.spork.local/config` for you. The one setting worth
adding by hand is `POST_CLONE`; the file's comments explain the rest.

| Setting | What it does |
| --- | --- |
| `TRUNK_BRANCH` | The branch the pool revolves around: new clones check it out, `just sync`/`just pull` fast-forward it, and a clone on any other branch counts as `parked`. `init` detects the remote's default (`main`, `master`, …) — set it by hand when your team works off something else, e.g. `TRUNK_BRANCH=dev`. |
| `CLONE_PREFIX` | Names the clones: the default `p` gives `p1`, `p2`, `p3`, … and `just clone` picks the highest existing number plus one. `CLONE_PREFIX=clone-` gives `clone-1`, `clone-2`, …. |
| `POST_CLONE` | Bash command run inside every new clone after the trunk checkout, and again when `just clean --full` wipes ignored files. Git only delivers tracked files, so this is where a clone becomes runnable — e.g. `POST_CLONE='bun install && bun run db:setup'`. |

## Commands

### use — day-to-day work

| Command | What it does |
| --- | --- |
| `just claude "hello world"` | Start a session in a free clone, with an optional prompt. |
| `just codex "hello world"` | Start a session in a free clone, with an optional prompt. |
| `just status` | Show each clone's state. |
| `just sync` | Update everything in the background. |

### manage — take care of the pool

| Command | What it does |
| --- | --- |
| `just clean <name>` | Reset a clone back to `open`. |
| `just clone [N]` | Add N clones to the pool (default 1). |
| `just pull` | Update every clean clone. |

### advanced — session history

| Command | What it does |
| --- | --- |
| `just log [N]` | List recent sessions. |
| `just next` | Print the path of the next open clone. |
| `just resume <id\|name>` | Reopen a past session. |
