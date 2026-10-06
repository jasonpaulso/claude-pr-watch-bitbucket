#!/bin/bash
# Watch a session-registered list of Bitbucket pull requests and emit one line
# per event on stdout (consumed by a Claude Code Monitor):
#   WATCHING   — a PR was added to the watchlist (confirmation, emitted once)
#   COMMENTS   — new comments, grouped per PR per cycle with a count
#                (unfiltered snippets; the consuming Claude session should fetch
#                the full thread before acting)
#   APPROVALS  — the set of approvals on a PR changed
#   CI         — the pipeline rollup on the PR's current tip changed
#                (passing / failing / pending / no-build)
#   MERGED / DECLINED — the PR's state changed (watching then stops)
#
# WATCH_LIST (required): path to the watchlist file. One PR per line, either
#   workspace/repo#123   or   https://bitbucket.org/workspace/repo/pull-requests/123
# The file is re-read every cycle, so appending a line starts watching that PR
# within one interval — no restart needed. Duplicates are fine.
#
# Every lookup goes through the twg CLI (Atlassian Teamwork Graph):
#   twg --output json --output-summary none bb prs get <id> -w <ws> -r <repo> \
#       --statuses --comments
# One call per PR per cycle covers state, pipeline statuses and comments
# (~1.3s each). `--output-summary none` keeps stdout as pure JSON and stops
# twg from writing per-run payload files.
#
# Env overrides (for testing): WATCH_INTERVAL, WATCH_MAX_CYCLES (0 = forever),
# WATCH_STATE_DIR (pre-seeded state diffs on the first cycle), WATCH_SINCE
# (comment floor), WATCH_TWG (path to the twg binary).
set -u
# Byte-wise collation everywhere: `sort` and `join` must agree, and the
# watchlist keys are ASCII. Without this, a non-C locale can make join treat
# sorted input as unsorted and silently drop rows.
export LC_ALL=C

LIST="${WATCH_LIST:?set WATCH_LIST to the watchlist file path}"
INTERVAL="${WATCH_INTERVAL:-60}"
MAX_CYCLES="${WATCH_MAX_CYCLES:-0}"
TWG="${WATCH_TWG:-twg}"
TWG_ARGS="--output json --output-summary none"
STATE_DIR="${WATCH_STATE_DIR:-}"
CLEANUP=0
if [ -z "$STATE_DIR" ]; then
  STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bb-pr-watch.XXXXXX") || exit 1
  CLEANUP=1
else
  mkdir -p "$STATE_DIR"
fi
trap '[ "$CLEANUP" = 1 ] && rm -rf "$STATE_DIR"' EXIT

PREV="$STATE_DIR/prev.tsv"   # lines: key <TAB> state <TAB> ci <TAB> approvals <TAB> title
CUR="$STATE_DIR/cur.tsv"
DONE="$STATE_DIR/done.keys"  # merged/declined keys — skipped on every later cycle
touch "$DONE" "$PREV"   # PREV must exist (empty) so join works on the first cycle
TAB=$(printf '\t')

# Singleton per watchlist: /clear re-fires the SessionStart hook while the old
# monitor is still running, so a duplicate watcher may get armed. The lock makes
# that harmless — the newcomer sees a live owner and exits immediately.
LOCK="$LIST.lock"
if ! ( set -C; echo $$ > "$LOCK" ) 2>/dev/null; then
  owner=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$owner" ] && ps -p "$owner" -o command= 2>/dev/null | grep -q watch-bb-pr-activity; then
    echo "DUPLICATE: a watcher (pid $owner) is already active for this watchlist — exiting; events continue from the existing one."
    exit 0
  fi
  rm -f "$LOCK"
  # Can't create a lock (e.g. unwritable dir): run unlocked rather than not at all.
  ( set -C; echo $$ > "$LOCK" ) 2>/dev/null || LOCK=""
fi
trap '[ "$CLEANUP" = 1 ] && rm -rf "$STATE_DIR"; [ -n "$LOCK" ] && rm -f "$LOCK"' EXIT
trap 'exit 0' TERM   # superseded watchers stop cleanly, not as failures

# /clear hands the SAME session process a NEW session_id — new watchlist, new
# lock — so the per-watchlist lock can't see the pre-clear watcher. Supersede
# instead: stop any other watcher descended from the same claude session
# process (newest wins). Watchers of other sessions have different ancestors
# and are left alone.
claude_ancestor() {
  ca_pid=$1
  while [ -n "$ca_pid" ] && [ "$ca_pid" != "1" ] && [ "$ca_pid" != "0" ]; do
    ca_cmd=$(ps -p "$ca_pid" -o comm= 2>/dev/null | tr -d ' ')
    [ -z "$ca_cmd" ] && return 1
    case "$ca_cmd" in *claude*|*node*) echo "$ca_pid"; return 0 ;; esac
    ca_pid=$(ps -p "$ca_pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}
MY_ANC=$(claude_ancestor $$)
is_ancestor() {   # is_ancestor <candidate-pid> — true if it's in our own ancestry
  ia_pid=$1
  ia_cur=$$
  while [ -n "$ia_cur" ] && [ "$ia_cur" != "1" ]; do
    [ "$ia_cur" = "$ia_pid" ] && return 0
    ia_cur=$(ps -p "$ia_cur" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}
if [ -n "$MY_ANC" ]; then
  for opid in $(pgrep -f 'watch-bb-pr-activity[.]sh' 2>/dev/null | sort -u); do
    [ "$opid" = "$$" ] && continue
    is_ancestor "$opid" && continue   # never kill the wrapper that spawned us
    oanc=$(claude_ancestor "$opid") || continue
    if [ "$oanc" = "$MY_ANC" ]; then
      kill "$opid" 2>/dev/null && echo "SUPERSEDED: stopped an older watcher (pid $opid) from before a /clear of this session."
    fi
  done
fi

# One PR -> TSV row: key <TAB> state <TAB> ci <TAB> approvals <TAB> title.
# CI is rolled up over the build statuses attached to the PR's *current* tip
# commit (status hashes are full 40-char, source.commit.hash is the 12-char
# abbreviation, so match on prefix). Emits nothing when the lookup failed.
PR_FILTER='
  select(.state != null)
  | (.source.commit.hash // "") as $tip
  | ([._statuses[]? | select((.commit.hash // "") | startswith($tip))
     | (.state // "PENDING" | ascii_upcase)]) as $s
  | (if ($s | length) == 0 then "no-build"
     elif ($s | any(. == "FAILED" or . == "ERROR" or . == "STOPPED")) then "failing"
     elif ($s | any(. == "IN_PROGRESS" or . == "BUILDING" or . == "PENDING"
                   or . == "HALTED" or . == "QUEUED" or . == "IN_QUEUE")) then "pending"
     else "passing" end) as $ci
  | ([.reviewers[]? | select(.approved == true)
     | (.display_name // .nickname // "?")] | unique | join(", ")) as $appr
  | "\($key)\t\(.state)\t\($ci)\t\($appr)\t\(.title // "" | gsub("[\\r\\n\\t]+"; " ") | .[0:120])"
'

# Same payload -> comment rows: key <TAB> author[ on path] <TAB> snippet.
# Timestamps come back UTC ("...+00:00"); truncating to seconds keeps plain
# string comparison equivalent to time comparison here.
COMMENT_FILTER='
  (.["_comments"] // [])[]
  | select((.deleted // false) | not)
  | select((.pending // false) | not)
  | select((.created_on // "")[0:19] > $last)
  | "\($key)\t\(.user.display_name // "?")\(if .inline then " on \(.inline.path // "?")" else "" end)\t\((.content.raw // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:140])"
'

cycle=0
# WATCH_SINCE (testing/backfill): ISO-8601 UTC, e.g. 2026-10-06T00:00:00.
# Default is "now", so a fresh watcher reports only what happens after it is
# armed; set it in the past to replay today's comments on the first cycle.
last="${WATCH_SINCE:-$(date -u +%Y-%m-%dT%H:%M:%S)}"

while true; do
  [ "$cycle" -gt 0 ] && sleep "$INTERVAL"
  cycle=$((cycle + 1))
  now=$(date -u +%Y-%m-%dT%H:%M:%S)

  # Normalize the watchlist (URLs -> workspace/repo#num), dedupe, drop finished.
  keys=""
  if [ -f "$LIST" ]; then
    keys=$(sed -E 's|^(https?://)?(www\.)?bitbucket\.org/([^/]+)/([^/]+)/pull-requests/([0-9]+).*|\3/\4#\5|' "$LIST" \
      | grep -E '^[^/ ]+/[^# ]+#[0-9]+$' | sort -u | grep -vxF -f "$DONE" || true)
  fi
  if [ -z "$keys" ]; then
    [ "$MAX_CYCLES" != 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ] && exit 0
    continue
  fi

  : > "$CUR"
  : > "$STATE_DIR/comments.tsv"
  for key in $keys; do
    wsrepo=${key%#*}
    num=${key##*#}
    ws=${wsrepo%%/*}
    repo=${wsrepo##*/}

    payload=$($TWG $TWG_ARGS bb prs get "$num" -w "$ws" -r "$repo" --statuses --comments 2>/dev/null </dev/null)

    row=$(printf '%s' "$payload" | jq -r --arg key "$key" "$PR_FILTER" 2>/dev/null)
    if [ -n "$row" ]; then
      printf '%s\n' "$row" >> "$CUR"
      printf '%s' "$payload" | jq -r --arg key "$key" --arg last "$last" "$COMMENT_FILTER" \
        >> "$STATE_DIR/comments.tsv" 2>/dev/null
    else
      # Transient/API failure: carry the last known row forward so a flaky
      # lookup can't fabricate a "new PR" or a CI flip.
      awk -F'\t' -v k="$key" '$1 == k {print; exit}' "$PREV" >> "$CUR"
    fi
  done
  sort -o "$CUR" "$CUR"

  # --- emit this cycle's events (PREV is empty on the first cycle, so every
  # key there counts as newly watched and gets a WATCHING confirmation) ---
  if [ -s "$CUR" ]; then
    JOINED="$STATE_DIR/joined.tsv"   # key, prev-state, prev-ci, prev-appr, prev-title, cur-state, cur-ci, cur-appr, cur-title
    join -t "$TAB" -j 1 "$PREV" "$CUR" 2>/dev/null > "$JOINED"

    # Newly watched PRs (in cur, not prev)
    join -t "$TAB" -j 1 -v 2 "$PREV" "$CUR" 2>/dev/null \
      | awk -F'\t' '{printf "WATCHING: %s — %s (%s, CI: %s)\n", $1, $5, tolower($2), $3}'

    # State transitions, CI changes, new approvals
    awk -F'\t' '$2 == "OPEN" && $6 == "MERGED" {printf "MERGED: %s — %s\n", $1, $9}
                $2 == "OPEN" && $6 == "DECLINED" {printf "DECLINED: %s — %s\n", $1, $9}
                $2 == "OPEN" && $6 == "OPEN" && $3 != $7 {printf "CI: %s — now %s (was %s) — %s\n", $1, $7, $3, $9}
                $2 == "OPEN" && $6 == "OPEN" && $4 != $8 && $8 != "" {printf "APPROVALS: %s — approved by %s — %s\n", $1, $8, $9}' "$JOINED"

    # New comments — collected above, emitted as ONE event line per PR so a
    # burst of review comments can't split across notifications.
    awk -F'\t' '
      { c[$1]++; if (t[$1] != "") t[$1] = t[$1] " ¦ "; t[$1] = t[$1] $2 ": " $3 }
      END { for (k in c) printf "COMMENTS %s — %d new: %s\n", k, c[k], substr(t[k], 1, 500) }
    ' "$STATE_DIR/comments.tsv"
  fi

  # Anything not OPEN is finished: skip it on all later cycles.
  awk -F'\t' '$2 != "OPEN" {print $1}' "$CUR" >> "$DONE"
  sort -u -o "$DONE" "$DONE"

  cp "$CUR" "$PREV"
  last=$now
  [ "$MAX_CYCLES" != 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ] && exit 0
done
