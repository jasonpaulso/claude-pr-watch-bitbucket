#!/bin/bash
# Watch a session-registered list of Bitbucket pull requests and emit one line
# per event on stdout (consumed by a Claude Code Monitor):
#
#   WATCHING     — a PR was added to the watchlist (confirmation, emitted once)
#   COMMENTS     — new *and edited* comments, grouped per PR per cycle with a
#                  count. Each entry is labelled "author (kind, source)": (new) /
#                  (edited) plus a source suffix — (…, review-bot) AI reviewer,
#                  (…, automation) dashboard/bot notice posted under a human name,
#                  (…, app) other automation; no suffix means a human.
#   APPROVALS    — the set of approvals on a PR changed (a reviewer signed off)
#   CI           — the pipeline rollup on the PR's current tip changed
#                  (passing / failing / pending / no-build)
#   MERGED       — the PR was merged
#   DECLINED     — the PR was declined
#   WATCH ERROR  — a PR lookup failed, reported once per failure streak
#
# WATCH_LIST (required): path to the watchlist file. One PR per line, either
#   workspace/repo#123   or   https://bitbucket.org/workspace/repo/pull-requests/123
# The file is re-read every cycle, so appending a line starts watching that PR
# within one interval — no restart needed. Duplicates and blank lines are fine.
#
# STATE IS DURABLE, AND IT HAS TO BE
# ------------------------------------
# The Monitor tool has no `persistent` option in current Claude Code: every
# watch dies at `timeout_ms` (max 30 minutes) and you re-arm it with the same
# command. So state lives next to the watchlist, in a path derived from it
# (<watchlist>.state), never in a fresh mktemp dir:
#   prev.tsv      last snapshot (diffing baseline for every event above)
#   last          the timestamp of the last check — a re-arm resumes from HERE,
#                 so nothing in the gap between watches is lost, and a re-arm
#                 does not re-send WATCHING for PRs that were already watched.
#   done.keys     merged/declined PRs, never looked at again
#   fail.keys     lookups that failed last cycle (for once-per-streak notices)
#   posted.ids    comment ids this session posted itself — never echoed back
# Delete the state dir when you retire the watchlist; until then it survives
# every re-arm.
#
# Each cycle makes one twg call per PR (~1.3s) returning state + pipeline
# statuses + comments:
#   twg --output json --output-summary none bb prs get <id> -w <ws> -r <repo> \
#       --statuses --comments
# `--output-summary none` matters: stdout stays pure JSON (fed straight to jq)
# and twg writes no per-run payload file, which a long-lived poller would
# otherwise accumulate by the thousand.
#
# Env overrides (for testing): WATCH_INTERVAL, WATCH_MAX_CYCLES (0 = forever),
# WATCH_STATE_DIR, WATCH_SINCE (comment floor), WATCH_TWG, WATCH_SIGNATURE
# (the signature your own posted comments end with; default "-CC").
set -u

# Byte-wise collation everywhere: `sort` and `join` must agree, and the keys are
# ASCII. Under a non-C locale join can treat sorted input as unsorted and
# silently drop rows.
export LC_ALL=C

LIST="${WATCH_LIST:?set WATCH_LIST to the watchlist file path}"
INTERVAL="${WATCH_INTERVAL:-60}"
MAX_CYCLES="${WATCH_MAX_CYCLES:-0}"
TWG="${WATCH_TWG:-twg}"
TWG_ARGS="--output json --output-summary none"
SIGNATURE="${WATCH_SIGNATURE:--CC}"
# Must be normalised: the hook never sets it, and a bare "$WATCH_SINCE" under
# `set -u` aborts the whole watcher on cycle one — which is every cycle.
SINCE="${WATCH_SINCE:-}"

# Derived, not mktemp: a re-arm after timeout must land on the same state.
STATE_DIR="${WATCH_STATE_DIR:-${LIST%.watchlist}.state}"
mkdir -p "$STATE_DIR" || exit 1

PREV="$STATE_DIR/prev.tsv"       # key <TAB> state <TAB> ci <TAB> approvals <TAB> title
CUR="$STATE_DIR/cur.tsv"
DONE="$STATE_DIR/done.keys"      # merged/declined keys — skipped on every later cycle
FAIL="$STATE_DIR/fail.keys"      # keys whose lookup failed last cycle
LASTF="$STATE_DIR/last"          # time of the last check (survives re-arms)
POSTED="$STATE_DIR/posted.ids"   # comment ids this session posted — never echoed back
COLLECTED="$STATE_DIR/comments.tsv"
# PREV/FAIL must exist (empty) so join and the failure-diff work on cycle one.
touch "$DONE" "$FAIL" "$PREV" "$POSTED"
TAB=$(printf '\t')
# Lock is removed on exit; state is NOT (it must outlive every re-arm).
trap '[ -n "${LOCK:-}" ] && rm -f "$LOCK"' EXIT

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
trap '[ -n "${LOCK:-}" ] && rm -f "$LOCK"' EXIT
trap 'exit 0' TERM   # superseded watchers stop cleanly, not as failures

# /clear hands the SAME session process a NEW session_id — new watchlist, new
# lock — so the per-watchlist lock can't see the pre-clear watcher. Supersede
# instead: stop any other watcher descended from the same claude/node session
# process (newest wins). Watchers of other sessions have different ancestors and
# are left alone, and a process in our own ancestry is never killed (that would
# be the wrapper still delivering *our* stdout).
ancestor_session() {
  aa_pid=$1
  while [ -n "$aa_pid" ] && [ "$aa_pid" != "1" ] && [ "$aa_pid" != "0" ]; do
    aa_cmd=$(ps -p "$aa_pid" -o comm= 2>/dev/null | tr -d ' ')
    [ -z "$aa_cmd" ] && return 1
    case "$aa_cmd" in *claude*|*node*) echo "$aa_pid"; return 0 ;; esac
    aa_pid=$(ps -p "$aa_pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}
in_own_ancestry() {
  ia_pid=$1
  ia_cur=$$
  while [ -n "$ia_cur" ] && [ "$ia_cur" != "1" ]; do
    [ "$ia_cur" = "$ia_pid" ] && return 0
    ia_cur=$(ps -p "$ia_cur" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}
MY_ANC=$(ancestor_session $$)
if [ -n "$MY_ANC" ]; then
  killed=""
  for opid in $(pgrep -f 'watch-bb-pr-activity[.]sh' 2>/dev/null | sort -u); do
    [ "$opid" = "$$" ] && continue
    in_own_ancestry "$opid" && continue
    oanc=$(ancestor_session "$opid") || continue
    [ "$oanc" = "$MY_ANC" ] || continue
    kill "$opid" 2>/dev/null
    case "$killed" in *" $opid"*) ;; *) killed="$killed $opid";; esac
  done
  [ -n "$killed" ] && echo "SUPERSEDED: stopped older watcher(s) from before a /clear of this session:$killed"
fi

# One PR payload -> one TSV row: key <TAB> state <TAB> ci <TAB> approvals <TAB> title.
# CI is rolled up over the build statuses attached to the PR's *current* tip
# commit (status hashes are full 40-char, source.commit.hash is the 12-char
# abbreviation, so match on prefix). Emits nothing when the lookup failed, which
# the caller turns into a carried-forward row + a WATCH ERROR.
PR_FILTER='
  select(.state != null)
  | (.source.commit.hash // "") as $tip
  | ([._statuses[]?
     | select((.commit.hash // "") | startswith($tip))
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

# Same payload -> comment rows: key <TAB> "author [on path] (kind, source)" <TAB> snippet
#
# Two things this must catch that a naive "created since last poll" does not:
#   * EDITED comments. The CI Claude review edits its own comment instead of
#     posting a new one, so a fresh finding arrives with a new updated_on and an
#     old created_on. Watch both, and label which one it is.
#   * Our own posts. Comments this session posted (signed "-CC", or recorded in
#     posted.ids) are our own words — echoing them back as "new comments" would
#     be an instruction loop, not news.
# Timestamps come back UTC ("...+00:00"); truncating both sides to seconds keeps
# plain string comparison equivalent to time comparison here.
COMMENT_FILTER='
  (._comments // [])[]
  | select((.deleted // false) | not)
  | select((.pending // false) | not)
  | ((.id // 0) | tostring) as $cid
  | select(($posted | index(" " + $cid + " ")) == null)
  | ((.content.raw // "") | sub("\\s+$"; "")) as $body
  | select(($body | endswith($sig)) | not)
  | (if ((.created_on // "")[0:19] > $last) then "new"
     elif ((.updated_on // "")[0:19] > $last) then "edited"
     else empty end) as $kind
  | (if ($body | test("(?i)claude review|\\U0001F916")) then ", review-bot"
     elif ($body | test("NX_CLOUD_APP_COMMENT_END|cloud\\.nx\\.app|View your \\[CI Pipeline Execution")) then ", automation"
     elif ((.user.type // "") == "app_user") then ", app"
     else "" end) as $who
  | "\($key)\t\(.user.display_name // "?")\(if .inline then " on \(.inline.path // "?")" else "" end) (\($kind)\($who))\t\($body | gsub("[\\r\\n\\t]+"; " ") | .[0:140])"
'

cycle=0
while true; do
  [ "$cycle" -gt 0 ] && sleep "$INTERVAL"
  cycle=$((cycle + 1))
  now=$(date -u +%Y-%m-%dT%H:%M:%S)

  # Floor for THIS cycle: where the previous check left off. It is written to
  # last/ at the end of every cycle, so a re-arm resumes instead of replaying,
  # and a long-running watch never re-sends the same comments. WATCH_SINCE
  # overrides it on the first cycle only — it is a backfill switch, not a filter.
  if [ "$cycle" -eq 1 ] && [ -n "$SINCE" ]; then
    last="$SINCE"
  else
    last=$(cat "$LASTF" 2>/dev/null)
    [ -z "$last" ] && last="$now"
  fi
  # Never look into the future if a stale/invalid value got in.
  [ "$last" \> "$now" ] && last="$now"
  # Re-read every cycle: the session appends ids as it posts comments.
  posted=" $(tr -d ' \t' < "$POSTED" | tr '\n' ' ')"

  # Normalize the watchlist (URLs -> workspace/repo#num), dedupe, drop finished.
  keys=""
  if [ -f "$LIST" ]; then
    keys=$(sed -E 's|^(https?://)?(www\.)?bitbucket\.org/([^/]+)/([^/]+)/pull-requests/([0-9]+).*|\3/\4#\5|' "$LIST" \
      | grep -E '^[^/ ]+/[^# ]+#[0-9]+$' | sort -u | grep -vxF -f "$DONE" || true)
  fi
  if [ -z "$keys" ]; then
    printf '%s\n' "$now" > "$LASTF"
    [ "$MAX_CYCLES" != 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ] && exit 0
    continue
  fi

  : > "$CUR"
  : > "$COLLECTED"
  : > "$STATE_DIR/fail.new"
  for key in $keys; do
    wsrepo=${key%#*}
    num=${key##*#}
    ws=${wsrepo%%/*}
    repo=${wsrepo##*/}

    payload=$($TWG $TWG_ARGS bb prs get "$num" -w "$ws" -r "$repo" --statuses --comments 2>/dev/null </dev/null)
    row=$(printf '%s' "$payload" | jq -r --arg key "$key" "$PR_FILTER" 2>/dev/null)

    if [ -n "$row" ]; then
      printf '%s\n' "$row" >> "$CUR"
      printf '%s' "$payload" | jq -r --arg key "$key" --arg last "$last" \
        --arg sig "$SIGNATURE" --arg posted "$posted" "$COMMENT_FILTER" \
        >> "$COLLECTED" 2>/dev/null
    else
      # Lookup failed (bad key, no access, twg not authenticated, API blip).
      # Carry the last known row forward so a blip can't fabricate a "new PR"
      # or a CI flip, and record the failure for a once-per-streak notice.
      awk -F'\t' -v k="$key" '$1 == k {print; exit}' "$PREV" >> "$CUR"
      msg=$(printf '%s' "$payload" | jq -r \
        '.error.message // .error.code // "no usable response"' 2>/dev/null | head -1)
      printf '%s\t%s\n' "$key" "$(printf '%s' "$msg" | tr -d '\r\n\t' | cut -c1-120)" >> "$STATE_DIR/fail.new"
    fi
  done
  sort -o "$CUR" "$CUR"

  # --- emit this cycle's events -------------------------------------------------
  # Newly watched PRs (in cur, not prev). PREV is empty on the very first cycle,
  # so every seeded PR gets a WATCHING confirmation there — and on every re-arm
  # after a timeout, nothing does, because PREV survived.
  join -t "$TAB" -j 1 -v 2 "$PREV" "$CUR" 2>/dev/null \
    | awk -F'\t' '{printf "WATCHING: %s — %s (%s, CI: %s)\n", $1, $5, tolower($2), $3}'

  # State transitions, CI changes, new approvals. A carried-forward row is
  # byte-identical to last cycle's, so a failed lookup fires nothing.
  join -t "$TAB" -j 1 "$PREV" "$CUR" 2>/dev/null > "$STATE_DIR/joined.tsv"
  awk -F'\t' '$2 == "OPEN" && $6 == "MERGED"   {printf "MERGED: %s — %s\n", $1, $9}
              $2 == "OPEN" && $6 == "DECLINED"  {printf "DECLINED: %s — %s\n", $1, $9}
              $2 == "OPEN" && $6 == "OPEN" && $3 != $7 {printf "CI: %s — now %s (was %s) — %s\n", $1, $7, $3, $9}
              $2 == "OPEN" && $6 == "OPEN" && $4 != $8 && $8 != "" {printf "APPROVALS: %s — approved by %s — %s\n", $1, $8, $9}' \
    "$STATE_DIR/joined.tsv"

  # Lookups that started failing this cycle (one line per PR, not per cycle).
  # NB: `grep -v -f emptyfile` prints everything, which is exactly what we want
  # on the first cycle; the NR==FNR awk idiom would silently swallow it.
  grep -vxF -f "$FAIL" "$STATE_DIR/fail.new" 2>/dev/null \
    | awk -F'\t' '{printf "WATCH ERROR: %s — %s\n", $1, $2}'

  # New/edited comments — grouped per PR into ONE event line so a burst of
  # review comments can't split across notifications.
  awk -F'\t' '
    { c[$1]++; if (t[$1] != "") t[$1] = t[$1] " ¦ "; t[$1] = t[$1] $2 ": " $3 }
    END { for (k in c) printf "COMMENTS %s — %d new: %s\n", k, c[k], substr(t[k], 1, 500) }
  ' "$COLLECTED"

  # Anything not OPEN is finished: skip it on all later cycles.
  awk -F'\t' '$2 != "OPEN" {print $1}' "$CUR" >> "$DONE"
  sort -u -o "$DONE" "$DONE"

  cp "$CUR" "$PREV"
  cp "$STATE_DIR/fail.new" "$FAIL"
  printf '%s\n' "$now" > "$LASTF"
  [ "$MAX_CYCLES" != 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ] && exit 0
done
