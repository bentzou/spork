#!/bin/bash
# claude_session_test.sh — tests for the Claude-session readers in _lib.sh:
#   claude_session_title  — pull the latest ai-title out of a session jsonl
#   claude_newest_session — newest jsonl (by mtime) for a clone, "<epoch>|<title>"
#
# These drive the SESSION column in `just status`. Both are exercised against a
# fixture projects dir via the CLAUDE_PROJECTS_DIR override, so no real
# ~/.claude state is touched.
#
#   tools/tests/claude_session_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# Minimal workspace so _lib.sh sources cleanly (it requires .spork.local/config),
# plus a fixture projects root the readers will look in.
WS=$(mktemp -d)
PROJ="$WS/projects"
cleanup() { [[ -d "$WS" ]] && rm -rf "$WS"; rm -f "$FAILFILE"; }
trap cleanup EXIT

ln -s "$SPORK_REPO" "$WS/.spork"
mkdir -p "$WS/.spork.local" "$PROJ"
cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=test:claude/fixture.git
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF

export CLAUDE_PROJECTS_DIR="$PROJ"
# shellcheck source=/dev/null
( cd "$WS" && . ./.spork/tools/_lib.sh ) >/dev/null 2>&1 || { echo "lib failed to source" >&2; exit 1; }
# Re-source into THIS shell so the functions are callable below.
cd "$WS" || exit 1
# shellcheck source=/dev/null
. ./.spork/tools/_lib.sh

# An ai-title record line. Args: title.
title_rec() { printf '{"type":"ai-title","aiTitle":"%s","sessionId":"sid-1"}\n' "$1"; }
# A timestamped user record. Args: ISO-8601 UTC timestamp.
ts_rec() { printf '{"type":"user","timestamp":"%s","sessionId":"sid-1"}\n' "$1"; }
# ISO -> epoch, the same conversion the reader must land on.
iso_epoch() { TZ=UTC0 date -j -f '%Y-%m-%dT%H:%M:%S' "${1:0:19}" +%s; }

# ---------------------------------------------------------------------------
echo "claude_session_title: latest ai-title wins, parses unicode + escapes"

f="$PROJ/a.jsonl"
{
    echo '{"type":"user","sessionId":"sid-1"}'
    title_rec "First title"
    echo '{"type":"assistant","sessionId":"sid-1"}'
    title_rec "p3 — tenancy spec iteration"
} > "$f"
check "last title wins, em-dash preserved" "p3 — tenancy spec iteration" "$(claude_session_title "$f")"

printf '{"type":"ai-title","aiTitle":"fix \\"auth\\" bug","sessionId":"sid-1"}\n' > "$f"
check "escaped quotes unescaped" 'fix "auth" bug' "$(claude_session_title "$f")"

echo '{"type":"user","sessionId":"sid-1"}' > "$f"
check "no ai-title record -> empty" "" "$(claude_session_title "$f")"

check "missing file -> empty" "" "$(claude_session_title "$PROJ/nope.jsonl")"

# ---------------------------------------------------------------------------
echo
echo "claude_session_last_ts: last timestamped record wins; mtime is ignored"

f="$PROJ/ts.jsonl"
{
    ts_rec "2026-01-01T00:00:00.000Z"
    ts_rec "2026-01-02T03:04:05.678Z"
    # A trailing record with no timestamp (e.g. file-history-snapshot) must
    # not blank the answer — the scan looks for the last record that HAS one.
    echo '{"type":"file-history-snapshot","messageId":"m1"}'
} > "$f"
check "last timestamped record wins" "$(iso_epoch 2026-01-02T03:04:05)" "$(claude_session_last_ts "$f")"

# An embedded, string-escaped copy (tool output quoting a record) is not a
# real record field and must not shadow the actual last timestamp.
{
    ts_rec "2026-01-01T00:00:00.000Z"
    printf '{"type":"user","toolUseResult":"saw \\"timestamp\\":\\"2027-09-09T09:09:09.000Z\\" in a log","sessionId":"sid-1"}\n'
} > "$f"
check "escaped timestamp in content ignored" "$(iso_epoch 2026-01-01T00:00:00)" "$(claude_session_last_ts "$f")"

printf '{"type":"summary","summary":"no timestamps here"}\n' > "$f"
check "no timestamped records -> empty" "" "$(claude_session_last_ts "$f")"

check "missing file -> empty" "" "$(claude_session_last_ts "$PROJ/nope2.jsonl")"

# ---------------------------------------------------------------------------
echo
echo "claude_newest_session: newest jsonl across encoded dir + subdir sessions"

# Encode a repo path the way Claude Code names project dirs: abs path, / -> -.
repo="$WS/p1"
enc="${repo//\//-}"
mkdir -p "$PROJ/$enc" "$PROJ/$enc-src-app"

old="$PROJ/$enc/old.jsonl"
new="$PROJ/$enc-src-app/new.jsonl"   # a subdir session, and the newest one
title_rec "Old work" > "$old"
title_rec "Newest work" > "$new"
touch -t 202601010000 "$old"
touch -t 202601020000 "$new"

got=$(claude_newest_session "$repo")
check "title comes from newest file (subdir counts)" "Newest work" "${got#*|}"
check "epoch is the newest file's mtime" "$(stat -f %m "$new")" "${got%%|*}"

# Flip mtimes: the other file is now newest.
touch -t 202601030000 "$old"
check "newest re-evaluated by mtime" "Old work" "$(claude_newest_session "$repo" | sed 's/^[^|]*|//')"

# A clone with no sessions at all.
check "no sessions -> empty pair" "|" "$(claude_newest_session "$WS/p2")"

# The epoch prefers the last in-file timestamp over mtime: an idle claude
# rewrites its jsonl on every system wake without appending records, so
# mtime says "minutes ago" while the conversation is days old.
{
    ts_rec "2026-01-01T00:00:00.000Z"
    title_rec "Wake-touched work"
} > "$PROJ/$enc/old.jsonl"
touch "$PROJ/$enc/old.jsonl"   # fresh mtime, like a wake-time rewrite
rm "$PROJ/$enc-src-app/new.jsonl"
got=$(claude_newest_session "$repo")
check "epoch from last record timestamp, not mtime" "$(iso_epoch 2026-01-01T00:00:00)" "${got%%|*}"
check "title still read alongside" "Wake-touched work" "${got#*|}"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
