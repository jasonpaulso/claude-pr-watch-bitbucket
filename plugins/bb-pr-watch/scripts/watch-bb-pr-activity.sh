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
#                  (edited) means the comment TEXT changed since it was last
#                  reported; a bare updated_on bump (a reaction, a re-index) is
#                  gated out on a hash of the body — see COMMENT_FILTER and the
#                  comment gate in the loop.
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
#   seen.tsv      key <TAB> comment id <TAB> hash of the comment text, for
#                 EVERY comment on the watched PRs (fingerprinted the first time
#                 it is seen, silently) — this is what says whether an (edited)
#                 event is real news or just Bitbucket moving a timestamp
#   tips.tsv      key <TAB> source.commit.hash of every watched PR's tip, rewritten
#                 each cycle from the payload already fetched (the wait below
#                 matches commit statuses against it)
#   event.rowid   the highest webhook-receiver row already accounted for
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
# THE WAIT BETWEEN CYCLES
# -----------------------
# Polling stays the source of truth; an event only makes the next poll earlier.
# Event mode needs WATCH_EVENTS != 0, the DB at WATCH_EVENT_DB and sqlite3 on
# PATH. Without it the wait is a plain `sleep $WATCH_INTERVAL` after the cycle,
# exactly as before (and a watchlist change waits for the next poll). With it,
# the wait ticks every 2 s and ends at the first of:
#   interval   WATCH_INTERVAL (default 60 s) after the previous cycle ENDED, to
#              within a second early (bash's clock is whole seconds), never late
#   watchlist  the watchlist file's size or mtime changed (a PR was added/removed)
#   event      webhook-receiver logged a row for a watched PR past event.rowid:
#              a pullrequest:* event naming it, or a commit status on its tip
# watchlist and event wakes come no sooner than 5 s after the previous cycle
# ended, and an event waits 3 s more so a burst becomes one cycle. A read of the
# log can block 2 s on a locked DB, so none starts with under ~3 s of the
# interval left and the wait never overruns the interval by more than the 0.3 s
# the closing read may take. Any failed read counts as "no event", so the worst
# case is the plain poll.
#
# Env overrides (for testing): WATCH_INTERVAL, WATCH_MAX_CYCLES (0 = forever),
# WATCH_STATE_DIR, WATCH_SINCE (comment floor), WATCH_TWG, WATCH_SIGNATURE
# (the signature your own posted comments end with; default "-CC"),
# WATCH_EVENTS (0 = plain sleep, never wake early), WATCH_EVENT_DB (default
# ~/.local/share/webhook-receiver/events.sqlite), WATCH_DEBUG (1 = log each
# wait's reason and length to stderr).
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
# Content hash for the comment gate (see COMMENT_FILTER / the comment gate below).
# Called once per comment that is either a candidate or not yet fingerprinted —
# every comment once, then only the handful that move each cycle — so one process
# per call is fine.
if command -v md5sum >/dev/null 2>&1; then
  hash_text() { md5sum | cut -d' ' -f1; }
elif command -v md5 >/dev/null 2>&1; then
  hash_text() { md5 -q; }
else
  hash_text() { cksum | cut -d' ' -f1; }
fi
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
SEEN="$STATE_DIR/seen.tsv"       # key <TAB> comment id <TAB> hash of the comment text
COLLECTED="$STATE_DIR/comments.tsv"
CAND="$STATE_DIR/cand.raw"       # this cycle's comment candidates, pre-gate
TIPS="$STATE_DIR/tips.tsv"       # key <TAB> tip commit hash of each watched PR
ROWIDF="$STATE_DIR/event.rowid"  # newest event-log rowid already accounted for
EVENT_DB="${WATCH_EVENT_DB:-${HOME:-}/.local/share/webhook-receiver/events.sqlite}"
# PREV/FAIL must exist (empty) so join and the failure-diff work on cycle one.
touch "$DONE" "$FAIL" "$PREV" "$POSTED" "$SEEN" "$TIPS"
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
  # Approvals live on participants, whatever their role: the Bitbucket reviewers list carries
  # names only, never `approved` (RC #1511: Brady approved as REVIEWER, Jason as PARTICIPANT).
  | ([.participants[]? | select(.approved == true)
     | (.user.display_name // .user.nickname // "?")] | unique | join(", ")) as $appr
  | "\($key)\t\(.state)\t\($ci)\t\($appr)\t\(.title // "" | gsub("[\\r\\n\\t]+"; " ") | .[0:120])"
'

# Same payload -> comment rows, one per live comment (see the row layout below the
# two notes).
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
#
# Every live comment is emitted, not only the recent ones: kind "-" marks the rows
# that are not candidates (nothing happened to them since the last check), and the
# comment gate in the loop fingerprints those silently. Emitting only candidates
# would leave a comment that predates the watch without a baseline, so the first
# 👍 it ever receives would read as "(edited)".
# Rows: key <TAB> comment id <TAB> kind ("new" | "edited" | "-" = neither) <TAB>
#       "author [on path] (kind, source)" <TAB> snippet <TAB> full body
#       (single line, tab-free). kind is carried separately from the display
#       label because the gate needs it to tell "report this" from "fingerprint
#       this and say nothing", and "-" rather than "" because `IFS=$'\t' read`
#       collapses runs of the delimiter and would shift every column after it.
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
     else "-" end) as $kind
  | (if ($body | test("(?i)claude review|\\x{1F916}")) then ", review-bot"
     elif ($body | test("NX_CLOUD_APP_COMMENT_END|cloud\\.nx\\.app|View your \\[CI Pipeline Execution")) then ", automation"
     elif ((.user.type // "") == "app_user") then ", app"
     else "" end) as $who
  | "\($key)\t\($cid)\t\($kind)\t\(.user.display_name // "?")\(if .inline then " on \(.inline.path // "?")" else "" end) (\($kind)\($who))\t\($body | gsub("[\\r\\n\\t]+"; " ") | .[0:140])\t\($body | gsub("[\\r\\n\\t]+"; " "))"
'

# --- the wait: poll on a timer, wake early on the receiver's event log ----------
# Variables are prefixed per function (wf_, ev_): bash functions share globals,
# and the cycle below owns keys/key/now/last.
if stat -c '%Y %s' / >/dev/null 2>&1; then
  list_sig() { stat -c '%Y %s' "$LIST" 2>/dev/null; }   # GNU
else
  list_sig() { stat -f '%m %z' "$LIST" 2>/dev/null; }   # BSD / macOS
fi
event_on() {
  [ "${WATCH_EVENTS:-1}" != 0 ] && [ -f "$EVENT_DB" ] && command -v sqlite3 >/dev/null 2>&1
}
# Every read is read-only with a busy timeout (default 2 s). A failure (locked,
# unreadable, not a database) prints nothing, which every caller treats as "no match".
event_sql() {
  sqlite3 -readonly -cmd ".timeout ${2:-2000}" "$EVENT_DB" "$1" 2>/dev/null </dev/null
}
# Remember the newest rowid, in memory as well as in the file: if the file cannot
# be written, the same row must not wake every later wait. A failed read leaves
# the saved value as it was. $1 = busy timeout in ms.
ROWID_MEM=""
save_rowid() {
  ev_max=$(event_sql 'SELECT coalesce(max(rowid), 0) FROM events' "${1:-2000}")
  case "$ev_max" in
    ''|*[!0-9]*) ;;
    *) ROWID_MEM=$ev_max; printf '%s\n' "$ev_max" 2>/dev/null > "$ROWIDF" ;;
  esac
}
# SQL that finds a row past the saved rowid that concerns a watched PR, or ""
# when there is nothing to match. Watched = this cycle's keys minus merged ones;
# keys and tips only reach SQL as quoted literals (single quotes doubled).
event_query() {
  ev_saved=$(cat "$ROWIDF" 2>/dev/null)
  case "$ev_saved" in ''|*[!0-9]*) ev_saved="" ;; esac
  # The larger of file and memory: a file that could not be updated is stale.
  if [ -n "$ROWID_MEM" ] && { [ -z "$ev_saved" ] || [ "$ROWID_MEM" -gt "$ev_saved" ]; }; then ev_saved=$ROWID_MEM; fi
  [ -z "$ev_saved" ] && return
  ev_watched=$(printf '%s\n' "$keys" | grep -vxF -f "$DONE")
  [ -z "$ev_watched" ] && return
  ev_prs=$(printf '%s\n' "$ev_watched" | awk -v q="'" \
    'NF { k = tolower($0); gsub(q, q q, k); printf "%s(%s%s%s)", sep, q, k, q; sep = "," }')
  # (repo, tip) pairs; the tip is a 12-char prefix of the status's 40-char hash.
  ev_tips=$(awk -F'\t' -v q="'" -v k="$(printf '%s' "$ev_watched" | tr '\n' ' ')" '
    BEGIN { n = split(k, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    w[$1] { r = tolower($1); sub(/#.*/, "", r); t = $2; gsub(q, q q, r); gsub(q, q q, t)
            printf "%s(%s%s%s,%s%s%s)", sep, q, r, q, q, t, q; sep = "," }
  ' "$TIPS")
  printf '%s' "WITH p(k) AS (VALUES $ev_prs), s(r, t) AS (VALUES ${ev_tips:-(NULL,NULL)})
    SELECT 1 FROM events WHERE rowid > $ev_saved AND (
      (event_key GLOB 'pullrequest:*'
        AND lower(repo) || '#' || json_extract(payload, '\$.pullrequest.id') IN (SELECT k FROM p))
      OR (event_key GLOB 'repo:commit_status_*'
        AND EXISTS (SELECT 1 FROM s WHERE s.r = lower(repo)
          AND substr(json_extract(payload, '\$.commit_status.commit.hash'), 1, length(s.t)) = s.t))
    ) LIMIT 1"
}
# Block until it is time for the next cycle; logs why when WATCH_DEBUG=1. Time
# is measured from the moment this is called, i.e. from the end of the cycle, so
# a cycle longer than the interval is never followed by an immediate one.
wait_for_wake() {
  wf_t0=$SECONDS
  wf_reason=interval
  wf_ev=0
  case "$INTERVAL" in ''|*[!0-9]*) ;; *) event_on && wf_ev=1 ;; esac
  if [ "$wf_ev" = 0 ]; then
    sleep "$INTERVAL"   # event mode off: the wait is what it always was
  else
    wf_query=$(event_query)
    while :; do
      wf_el=$((SECONDS - wf_t0))
      [ "$wf_el" -ge "$INTERVAL" ] && break
      # SECONDS counts whole seconds, so 6 is the first count that guarantees 5 real ones.
      if [ "$wf_el" -ge 6 ]; then
        if [ "$(list_sig)" != "$LIST_SIG" ]; then wf_reason=watchlist; break; fi
        # A read may block 2 s: only start one with a clear margin left.
        if [ -n "$wf_query" ] && [ $((INTERVAL - wf_el)) -ge 4 ] && [ -n "$(event_sql "$wf_query")" ]; then
          wf_reason=event
          # Let a burst of events land in one cycle, but stay inside the interval.
          wf_rem=$((INTERVAL - (SECONDS - wf_t0)))
          [ "$wf_rem" -ge 2 ] && sleep $((wf_rem - 1 < 3 ? wf_rem - 1 : 3))
          break
        fi
      fi
      # Sleep to just short of the deadline, then creep up on it: the clock is in
      # whole seconds, so a full sleep could land up to a second past it.
      wf_rem=$((INTERVAL - (SECONDS - wf_t0)))
      if [ "$wf_rem" -ge 2 ]; then sleep $((wf_rem - 1 < 2 ? wf_rem - 1 : 2)); else sleep 0.2; fi
    done
    # Every wake saves the newest rowid before the cycle's twg calls: a row
    # logged during the cycle then wakes the next wait, and rows from before
    # this moment can never wake a PR that is added later. Short timeout: this
    # read happens at the deadline.
    save_rowid 300
  fi
  [ "${WATCH_DEBUG:-0}" = 1 ] && echo "bb-pr-watch: wait reason=$wf_reason secs=$((SECONDS - wf_t0))" >&2
  return 0
}
# First run only: start from "now", so history never wakes a fresh watch. A
# re-arm keeps the saved value, and a row logged in the gap wakes its first wait.
if [ ! -s "$ROWIDF" ] && event_on; then save_rowid; fi

cycle=0
while true; do
  [ "$cycle" -gt 0 ] && wait_for_wake
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
  # The signature is taken first, so an append during this cycle wakes the next wait.
  LIST_SIG=$(list_sig)
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
  : > "$CAND"
  : > "$STATE_DIR/fail.new"
  : > "$STATE_DIR/tips.new"
  for key in $keys; do
    wsrepo=${key%#*}
    num=${key##*#}
    ws=${wsrepo%%/*}
    repo=${wsrepo##*/}

    payload=$($TWG $TWG_ARGS bb prs get "$num" -w "$ws" -r "$repo" --statuses --comments 2>/dev/null </dev/null)
    row=$(printf '%s' "$payload" | jq -r --arg key "$key" "$PR_FILTER" 2>/dev/null)

    if [ -n "$row" ]; then
      printf '%s\n' "$row" >> "$CUR"
      printf '%s' "$payload" | jq -r --arg key "$key" \
        '(.source.commit.hash // "") | select(. != "") | "\($key)\t\(.)"' >> "$STATE_DIR/tips.new" 2>/dev/null
      printf '%s' "$payload" | jq -r --arg key "$key" --arg last "$last" \
        --arg sig "$SIGNATURE" --arg posted "$posted" "$COMMENT_FILTER" \
        >> "$CAND" 2>/dev/null
    else
      # Lookup failed (bad key, no access, twg not authenticated, API blip).
      # Carry the last known row forward so a blip can't fabricate a "new PR"
      # or a CI flip, and record the failure for a once-per-streak notice.
      awk -F'\t' -v k="$key" '$1 == k {print; exit}' "$PREV" >> "$CUR"
      awk -F'\t' -v k="$key" '$1 == k {print; exit}' "$TIPS" >> "$STATE_DIR/tips.new"
      msg=$(printf '%s' "$payload" | jq -r \
        '.error.message // .error.code // "no usable response"' 2>/dev/null | head -1)
      printf '%s\t%s\n' "$key" "$(printf '%s' "$msg" | tr -d '\r\n\t' | cut -c1-120)" >> "$STATE_DIR/fail.new"
    fi
  done
  sort -o "$CUR" "$CUR"

  # Comment gate. Two kinds of noise used to reach the session as COMMENTS:
  #   * a comment nobody wrote to whose updated_on moved anyway (a 👍 landed on it,
  #     a re-index) — "updated_on > last" alone fires (edited) on it forever;
  #   * a comment that predates the watch, which fires (edited) the first time
  #     anyone reacts to it, because nothing fingerprinted it when the watch began.
  # So every comment on a watched PR is fingerprinted the first time it is seen,
  # silently, and from then on a comment is news only when its text differs from
  # the fingerprint in seen.tsv:
  #   candidate (created/updated since the last check) -> report if the hash
  #                                                         differs from seen.tsv
  #   anything else                                      -> fingerprint if unknown,
  #                                                         report nothing
  if [ -s "$CAND" ]; then
    # Trim rows that are neither candidates nor unknown — already fingerprinted
    # and nothing moved. Keeps the hashing (one process per row) to a handful.
    awk -F'\t' -v seen="$SEEN" '
      FILENAME == seen { known[$1 FS $2] = 1; next }
      $3 != "-" || !($1 FS $2 in known)
    ' "$SEEN" "$CAND" > "$STATE_DIR/trim.raw"
    while IFS=$'\t' read -r ckey ccid ckind clabel csnippet cbody; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ckey" "$ccid" "$(printf '%s' "$cbody" | hash_text)" "$ckind" "$clabel" "$csnippet"
    done < "$STATE_DIR/trim.raw" > "$STATE_DIR/hash.new"
    # NB: dispatch on FILENAME, not NR==FNR — SEEN is empty on the first cycle,
    # and the NR==FNR idiom would then swallow every row of hash.new.
    awk -F'\t' -v seen="$SEEN" '
      FILENAME == seen { prev[$1 FS $2] = $3; next }
      $4 != "-" && $3 != prev[$1 FS $2] { printf "%s\t%s\t%s\n", $1, $5, $6 }
    ' "$SEEN" "$STATE_DIR/hash.new" >> "$COLLECTED"
    # Newest hash wins per (pr, comment id); rows for PRs that left the watchlist
    # are dropped so the map cannot grow without bound. NB: `keys` is newline
    # separated and BSD awk rejects a newline in a -v value, so pass one line.
    sort -s -t "$TAB" -k1,1 -k2,2n "$STATE_DIR/hash.new" "$SEEN" \
      | awk -F'\t' -v k="$(printf '%s' "$keys" | tr '\n' ' ')" '
          BEGIN { n = split(k, a, " "); for (i = 1; i <= n; i++) watched[a[i]] = 1 }
          watched[$1] && !seen[$1 FS $2]++ { printf "%s\t%s\t%s\n", $1, $2, $3 }
        ' > "$STATE_DIR/seen.new"
    mv "$STATE_DIR/seen.new" "$SEEN"
  fi

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
  mv "$STATE_DIR/tips.new" "$TIPS"
  printf '%s\n' "$now" > "$LASTF"
  [ "$MAX_CYCLES" != 0 ] && [ "$cycle" -ge "$MAX_CYCLES" ] && exit 0
done
