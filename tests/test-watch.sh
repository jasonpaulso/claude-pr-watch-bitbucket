#!/bin/bash
# Tests for plugins/bb-pr-watch/scripts/watch-bb-pr-activity.sh. Plain bash, no
# network, no real twg and never the real event DB: every run gets a fake twg
# (WATCH_TWG) that prints fixture JSON, and a fixture DB built with the
# webhook-receiver's schema (src/webhook_receiver/store.py), under one temp dir
# that is removed on exit. Run from anywhere:  bash tests/test-watch.sh
#
# Jobs run in parallel (each has its own dir, list and state), so the suite
# takes about as long as its slowest wait, well under 3 minutes.
#
# Watchers are started ORPHANED (reparented to launchd). The script supersedes
# any other watcher that shares its claude/node ancestor, so a watcher started
# from a Claude Code session would kill that session's live watcher. With no
# such ancestor it kills nothing.
set -u
export LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NEW="$ROOT/plugins/bb-pr-watch/scripts/watch-bb-pr-activity.sh"
# The last commit before the early-wake change: its script is 0.2.4, the
# reference for "output is unchanged" (case 1).
BASE_SHA=0136da9
SQLITE=/usr/bin/sqlite3

T=$(mktemp -d "${TMPDIR:-/tmp}/bb-pr-watch-test.XXXXXX") || exit 1
cleanup() {
  for lf in "$T"/*/*.lock; do [ -f "$lf" ] && kill "$(cat "$lf")" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Never let a run reach the real log, whatever a job forgets to set.
export WATCH_EVENT_DB="$T/none.sqlite"
unset WATCH_EVENTS WATCH_SINCE WATCH_DEBUG WATCH_MAX_CYCLES WATCH_STATE_DIR

TIP=1e4515b14820                              # PR tip as twg reports it: 12 chars
FULL=${TIP}0123456789abcdef0123456789ab       # the same commit in a status: 40 chars
OTHER=ffffffffffff0123456789abcdef0123456789ab

# ---- fakes ---------------------------------------------------------------------
# twg --output json --output-summary none bb prs get NUM -w WS -r REPO --statuses --comments
# prints $FIXDIR/NUM.<call#>.json if there is one, else NUM.json. FAKE_HOOK is
# eval'd on every call ($num, $c in scope) so a test can act "during a cycle".
cat > "$T/twg" <<'EOF'
#!/bin/bash
num=$8
c=$(( $(cat "$FIXDIR/count.$num" 2>/dev/null || echo 0) + 1 ))
echo "$c" > "$FIXDIR/count.$num"
echo "$(date +%s) $num $c" >> "$FIXDIR/calls.log"
[ -n "${FAKE_HOOK:-}" ] && eval "$FAKE_HOOK"
f="$FIXDIR/$num.$c.json"; [ -f "$f" ] || f="$FIXDIR/$num.json"
cat "$f"
EOF
# ins DB EVENT_KEY REPO PAYLOAD: append one delivery, as the receiver does.
cat > "$T/ins" <<EOF
#!/bin/bash
$SQLITE "\$1" "INSERT INTO events (delivery_id, source, event_key, received_at, repo, summary, payload) VALUES (lower(hex(randomblob(8))), 'bitbucket', '\$2', datetime('now'), '\$3', '{}', '\$4')"
EOF
chmod +x "$T/twg" "$T/ins"
export INS="$T/ins"

# The receiver's schema (store.py SCHEMA plus the migrated entity column).
mkdb() {
  "$SQLITE" "$1" <<'SQL'
CREATE TABLE events (
  delivery_id TEXT PRIMARY KEY, source TEXT NOT NULL, event_key TEXT NOT NULL, received_at TEXT NOT NULL,
  attempt INTEGER, repo TEXT, summary TEXT, payload TEXT NOT NULL, entity TEXT
);
CREATE INDEX events_received ON events(received_at);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX events_entity ON events(entity);
SQL
}
pr_ev() { printf '{"actor":{"display_name":"Brady Perry"},"pullrequest":{"id":%s},"comment":{"id":886759712},"repository":{"full_name":"%s"}}' "$1" "$2"; }
st_ev() { printf '{"commit_status":{"commit":{"hash":"%s"},"key":"pipelines","state":"FAILED"},"repository":{"full_name":"%s"}}' "$1" "$2"; }
# History that predates every watch: matches the watched PR and tip, so any wake
# it caused would show.
seed_db() {
  mkdb "$1"
  "$INS" "$1" pullrequest:comment_created busie/fe-main "$(pr_ev 1512 busie/fe-main)"
  "$INS" "$1" pullrequest:comment_created busie/fe-main "$(pr_ev 1513 busie/fe-main)"
  "$INS" "$1" pullrequest:updated busie/fe-main "$(pr_ev 1512 busie/fe-main)"
  "$INS" "$1" repo:commit_status_updated busie/fe-main "$(st_ev $FULL busie/fe-main)"
}
max_rowid() { "$SQLITE" "$1" 'SELECT max(rowid) FROM events'; }

# ---- fixtures ------------------------------------------------------------------
cmt() {  # id created updated body user type
  printf '{"id":%s,"created_on":"%s","updated_on":"%s","content":{"raw":"%s"},"user":{"display_name":"%s","type":"%s"}}' "$@"
}
pr_json() {  # state tip statuses comments reviewers title [participants]
  printf '{"state":"%s","title":"%s","source":{"commit":{"hash":"%s"}},"reviewers":%s,"participants":%s,"_statuses":%s,"_comments":%s}\n' \
    "$1" "$6" "$2" "$5" "${7:-[]}" "$3" "$4"
}
simple_pr() { pr_json OPEN "$TIP" '[]' '[]' '[]' "Trip planner" > "$1/$2.json"; }
# Four cycles that exercise every output line: WATCHING, COMMENTS (new, edited,
# review-bot, automation, own "-CC" filtered), CI, APPROVALS, WATCH ERROR,
# MERGED, DECLINED. Dates are fixed (2001 / 2099) so output never depends on the clock.
fixtures_all_events() {
  f=$1
  st() { printf '[{"commit":{"hash":"%s"},"state":"%s"}]' "$FULL" "$1"; }
  c10=$(cmt 10 2001-01-01T00:00:00+00:00 2001-01-01T00:00:00+00:00 'first look' 'Brady Perry' user)
  c10e=$(cmt 10 2001-01-01T00:00:00+00:00 2099-01-01T00:00:00+00:00 'first look EDITED' 'Brady Perry' user)
  c11=$(cmt 11 2099-01-01T00:00:00+00:00 2099-01-01T00:00:00+00:00 'Claude review: looks fine' 'Bitbucket Pipelines' app_user)
  c12=$(cmt 12 2099-01-01T00:00:00+00:00 2099-01-01T00:00:00+00:00 'done -CC' 'Claude' user)
  c13=$(cmt 13 2099-01-01T00:00:00+00:00 2099-01-01T00:00:00+00:00 'View your [CI Pipeline Execution](https://cloud.nx.app/x)' 'Brady Perry' user)
  # The approval sits in both places here: 0.2.4 read reviewers, 0.2.5 reads participants,
  # and this case compares their output byte for byte. case10 uses Bitbucket's real shape.
  appr='[{"approved":true,"display_name":"Brady Perry"}]'
  part='[{"role":"REVIEWER","approved":true,"user":{"display_name":"Brady Perry"}}]'
  pr_json OPEN "$TIP" "$(st IN_PROGRESS)" "[$c10]" '[]' 'Add trip planner' > "$f/1512.1.json"
  pr_json OPEN "$TIP" "$(st FAILED)" "[$c10e,$c11]" "$appr" 'Add trip planner' "$part" > "$f/1512.2.json"
  pr_json OPEN "$TIP" "$(st SUCCESSFUL)" "[$c10e,$c11,$c12,$c13]" "$appr" 'Add trip planner' "$part" > "$f/1512.3.json"
  pr_json MERGED "$TIP" "$(st SUCCESSFUL)" "[$c10e,$c11,$c12,$c13]" "$appr" 'Add trip planner' "$part" > "$f/1512.4.json"
  pr_json OPEN 2222222222aa '[]' '[]' '[]' 'Fix login' > "$f/1513.1.json"
  echo '{"error":{"message":"boom"}}' > "$f/1513.2.json"
  pr_json OPEN 2222222222aa '[]' '[]' '[]' 'Fix login' > "$f/1513.3.json"
  pr_json DECLINED 2222222222aa '[]' '[]' '[]' 'Fix login' > "$f/1513.4.json"
}

# ---- running watchers ----------------------------------------------------------
# launch SCRIPT OUT ERR RC: runs the script with the caller's environment,
# orphaned (see the header). OUT/ERR collect stdout/stderr, RC its exit status.
launch() {
  rm -f "$4"
  ( bash -c 'bash "$1" >>"$2" 2>>"$3" </dev/null; echo $? >"$4"' _ "$1" "$2" "$3" "$4" & )
}
wait_rc() {  # file seconds
  i=0
  while [ ! -f "$1" ]; do sleep 0.2; i=$((i + 1)); [ "$i" -ge $(($2 * 5)) ] && return 1; done
  return 0
}
ncalls() { if [ -f "$FIX/calls.log" ]; then wc -l < "$FIX/calls.log" | tr -d ' '; else echo 0; fi; }
wait_calls() {  # n seconds: until the fake twg has been called n times
  i=0
  while [ "$(ncalls)" -lt "$1" ]; do sleep 0.2; i=$((i + 1)); [ "$i" -ge $(($2 * 5)) ] && return 1; done
  return 0
}
wait_text() {  # file text seconds
  i=0
  while ! grep -qF -- "$2" "$1" 2>/dev/null; do sleep 0.2; i=$((i + 1)); [ "$i" -ge $(($3 * 5)) ] && return 1; done
  return 0
}
call_at() { sed -n "${1}p" "$FIX/calls.log" | cut -d' ' -f1; }
gap() { echo $(($(call_at "$2") - $(call_at "$1"))); }          # seconds between two calls
reasons() { sed -n 's/^bb-pr-watch: wait reason=\([a-z]*\) .*/\1/p' "$1" | tr '\n' ' '; }
max_secs() { sed -n 's/^bb-pr-watch: wait reason=[a-z]* secs=\([0-9]*\)$/\1/p' "$1" | sort -n | tail -1; }
lock_pid() { cat "$LIST.lock" 2>/dev/null; }

# Per-job sandbox: $D dir, $FIX fixtures, $DB event DB, $LIST watchlist.
setup() {
  D=$T/$JOB; mkdir -p "$D/fix"
  FIX=$D/fix; DB=$D/events.sqlite; LIST=$D/w.watchlist
  export WATCH_LIST=$LIST WATCH_TWG=$T/twg FIXDIR=$FIX
}

# ---- checks --------------------------------------------------------------------
chk() {  # description command...: PASS/FAIL line, command's output shown on FAIL
  chk_d=$1; shift
  chk_o=$("$@" 2>&1)
  if [ $? -eq 0 ]; then echo "PASS: $JOB: $chk_d"
  else echo "FAIL: $JOB: $chk_d"; [ -n "$chk_o" ] && printf '%s\n' "$chk_o" | sed 's/^/        /'; fi
}
t_eq()      { [ "$1" = "$2" ] || { echo "expected [$2], got [$1]"; return 1; }; }
t_between() { { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; } 2>/dev/null || { echo "[$1] not in $2..$3"; return 1; }; }
t_has()     { grep -qF -- "$2" "$1" || { echo "$1 lacks: $2"; sed 's/^/  | /' "$1" | head -15; return 1; }; }
t_lacks()   { ! grep -qF -- "$2" "$1" || { echo "$1 has: $2"; return 1; }; }
t_same()    { cmp -s "$1" "$2" || { diff "$1" "$2" | head -20; return 1; }; }
t_alive()   { kill -0 "$1" 2>/dev/null; }
bail()      { echo "FAIL: $JOB: $*"; }

# ===============================================================================
job_syntax() {
  chk "bash -n passes on the script" bash -n "$NEW"
  chk "reference script is the 0.2.4 plugin" \
    sh -c "git -C '$ROOT' show $BASE_SHA:plugins/bb-pr-watch/.claude-plugin/plugin.json | grep -q '\"version\": \"0.2.4\"'"
}

# Case 1: no DB, WATCH_EVENTS=0, locked DB, unreadable DB (and no sqlite3 on
# PATH): every wait ends by interval, the watcher runs to WATCH_MAX_CYCLES, and
# stdout is byte-identical to 0.2.4's for the same fixtures.
case1() {  # variant
  setup
  fixtures_all_events "$FIX"
  printf 'busie/fe-main#1512\nbusie/fe-main#1513\n' > "$LIST"
  n=4 iv=1 npr=2
  mkdir -p "$D/w.state"
  seeded=""
  case $1 in
    nodb)  export WATCH_EVENT_DB=$D/missing.sqlite ;;
    off)   seed_db "$DB"; echo 0 > "$D/w.state/event.rowid"; seeded=0
           export WATCH_EVENT_DB=$DB WATCH_EVENTS=0 ;;
    locked)
      seed_db "$DB"; echo 0 > "$D/w.state/event.rowid"; seeded=0
      mkfifo "$D/hold"; "$SQLITE" "$DB" < "$D/hold" >/dev/null 2>&1 &
      exec 9>"$D/hold"; echo 'BEGIN EXCLUSIVE;' >&9; sleep 0.5
      chk "fixture DB is really locked" sh -c "! $SQLITE -readonly -cmd '.timeout 200' '$DB' 'SELECT 1 FROM events' >/dev/null 2>&1"
      export WATCH_EVENT_DB=$DB; n=2 iv=6 ;;
    locked60)
      seed_db "$DB"; echo 0 > "$D/w.state/event.rowid"; seeded=0
      mkfifo "$D/hold"; "$SQLITE" "$DB" < "$D/hold" >/dev/null 2>&1 &
      exec 9>"$D/hold"; echo 'BEGIN EXCLUSIVE;' >&9; sleep 0.5
      chk "fixture DB is really locked" sh -c "! $SQLITE -readonly -cmd '.timeout 200' '$DB' 'SELECT 1 FROM events' >/dev/null 2>&1"
      export WATCH_EVENT_DB=$DB; n=2 iv=60 ;;
    unreadable)
      seed_db "$DB"; echo 0 > "$D/w.state/event.rowid"; seeded=0
      chmod 000 "$DB"
      chk "fixture DB is really unreadable" sh -c "! $SQLITE -readonly '$DB' 'SELECT 1 FROM events' >/dev/null 2>&1"
      export WATCH_EVENT_DB=$DB; n=2 iv=6 ;;
    nosqlite)
      seed_db "$DB"; echo 0 > "$D/w.state/event.rowid"; seeded=0
      mkdir "$D/bin"
      for tool in bash env sed grep awk sort join jq tr cat cut date ps pgrep head md5 md5sum cksum cp mv rm touch mkdir stat sleep wc; do
        p=$(command -v "$tool") && ln -s "$p" "$D/bin/$tool"
      done
      export WATCH_EVENT_DB=$DB ;;
  esac
  # Reference run: 0.2.4 on its own copy of everything.
  mkdir -p "$D/old/fix"; cp "$FIX"/*.json "$D/old/fix/"; cp "$LIST" "$D/old/w.watchlist"
  (
    export WATCH_LIST=$D/old/w.watchlist FIXDIR=$D/old/fix WATCH_INTERVAL=1 WATCH_MAX_CYCLES=$n WATCH_SINCE=2000-01-01T00:00:00
    FIX=$D/old/fix launch "$T/old/watch-bb-pr-activity.sh" "$D/old/out" "$D/old/err" "$D/old/rc"
  )
  export WATCH_INTERVAL=$iv WATCH_MAX_CYCLES=$n WATCH_SINCE=2000-01-01T00:00:00 WATCH_DEBUG=1
  if [ "$1" = nosqlite ]; then
    PATH=$D/bin launch "$NEW" "$D/out" "$D/err" "$D/rc"
  else
    launch "$NEW" "$D/out" "$D/err" "$D/rc"
  fi
  wait_rc "$D/old/rc" 60 || bail "0.2.4 run did not finish"
  wait_rc "$D/rc" 90 || { bail "watcher did not reach WATCH_MAX_CYCLES"; return; }
  case $1 in locked*) exec 9>&- ;; esac
  chk "[$1] exits 0 at WATCH_MAX_CYCLES" t_eq "$(cat "$D/rc")" 0
  chk "[$1] polled every PR every cycle" t_eq "$(ncalls)" $((n * npr))
  # Since 2026-10-22 CI moves to pending/no-build and automation comments are not emitted;
  # compare everything else byte for byte, then check those two directly.
  norm() { grep -vE '^CI: .* — now (pending|no-build) \(|^COMMENTS ' "$1"; }
  norm "$D/old/out" > "$D/old/out.norm"; norm "$D/out" > "$D/out.norm"
  chk "[$1] output equals 0.2.4's (minus pending CI and comment lines)" t_same "$D/old/out.norm" "$D/out.norm"
  chk "[$1] no CI line for a move to pending" t_lacks "$D/out" '— now pending ('
  chk "[$1] automation comments not emitted" t_lacks "$D/out" 'automation)'
  chk "[$1] review-bot comments still emitted" t_has "$D/out" 'review-bot)' 
  chk "[$1] every wait ended by interval" t_eq "$(reasons "$D/err")" "$(i=1; while [ $i -lt $n ]; do printf 'interval '; i=$((i + 1)); done)"
  # The 2 s busy timeout of a locked DB must not stretch the wait (verifier: 6 -> 8 s, 60 -> 62 s).
  chk "[$1] longest wait <= WATCH_INTERVAL + 1 s (measured $(max_secs "$D/err") s of $iv)" t_between "$(max_secs "$D/err")" 0 $((iv + 1))
  case $1 in locked*|unreadable)
    chk "[$1] cycle-to-cycle gap within WATCH_INTERVAL -1..+1 s" t_between "$(gap 2 3)" $((iv - 1)) $((iv + 1)) ;;
  esac
  if [ -n "$seeded" ]; then
    chk "[$1] saved rowid untouched by failed or disabled reads" t_eq "$(cat "$D/w.state/event.rowid")" 0
  fi
  if [ "$1" = nodb ]; then
    for tag in 'WATCHING: busie/fe-main#1512' 'COMMENTS busie/fe-main#1512' '(edited)' 'review-bot' 'automation' 'CI: busie/fe-main#1512' \
               'APPROVALS: busie/fe-main#1512' 'WATCH ERROR: busie/fe-main#1513' 'MERGED: busie/fe-main#1512' 'DECLINED: busie/fe-main#1513'; do
      chk "[nodb] 0.2.4 output exercises: $tag" t_has "$D/old/out" "$tag"
    done
    chk "[nodb] own -CC comment stays filtered" t_lacks "$D/out" 'done -CC'
  fi
}
job_case1_nodb()        { case1 nodb; }
job_case1_off()         { case1 off; }
job_case1_locked()      { case1 locked; }
job_case1_locked60()     { case1 locked60; }
job_case1_unreadable()  { case1 unreadable; }
job_case1_nosqlite()    { case1 nosqlite; }

# Cases 2 and 3: one run, two waits. Wait 1 sees rows that must NOT wake it
# (history already in the log, plus the decoys); wait 2 sees the row that must.
# The decoy block and the wake row are the only differences between the two cases.
two_waits() {  # decoy-inserting function, wake-inserting function
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=14 WATCH_MAX_CYCLES=3 WATCH_DEBUG=1
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_calls 1 15 || { bail "no first cycle"; return; }
  "$1"
  wait_calls 2 30 || { bail "no second cycle"; return; }
  "$2"
  wait_rc "$D/rc" 30 || { bail "did not finish"; return; }
  chk "wait 1 ended by interval (decoys and old rows ignored), wait 2 by event" t_eq "$(reasons "$D/err")" "interval event "
  chk "wait 1 lasted the whole interval" t_between "$(gap 1 2)" 13 16
  # 5 s floor + up to 2 s tick + 3 s batch = 10 s after the cycle started, never before 5 + 3.
  chk "event wake: no sooner than the 5 s floor plus the 3 s batch, within 5 s of the floor" t_between "$(gap 2 3)" 7 11
  chk "exits 0" t_eq "$(cat "$D/rc")" 0
}
decoys_comment() {
  "$INS" "$DB" pullrequest:comment_created busie/fe-main "$(pr_ev 9999 busie/fe-main)"   # unwatched PR
  "$INS" "$DB" pullrequest:comment_created other/repo "$(pr_ev 1512 other/repo)"        # same id, other repo
  "$INS" "$DB" repo:push busie/fe-main "$(pr_ev 1512 busie/fe-main)"                    # not a pullrequest:* event
}
wake_comment() { "$INS" "$DB" pullrequest:comment_created busie/fe-main "$(pr_ev 1512 busie/fe-main)"; }
decoys_status() {
  "$INS" "$DB" repo:commit_status_created busie/fe-main "$(st_ev $OTHER busie/fe-main)"  # another commit
  "$INS" "$DB" repo:commit_status_created other/repo "$(st_ev $FULL other/repo)"         # the tip's hash, other repo
}
wake_status() { "$INS" "$DB" repo:commit_status_updated busie/fe-main "$(st_ev $FULL busie/fe-main)"; }
job_case2_comment() { two_waits decoys_comment wake_comment; }
job_case3_status() {
  two_waits decoys_status wake_status
  chk "tips.tsv holds the tip from the payload" t_eq "$(cat "$D/w.state/tips.tsv")" "$(printf 'busie/fe-main#1512\t%s' "$TIP")"
}

# Case 4: appending to the watchlist mid-wait wakes by "watchlist", even with
# older rows for the added PR in the log; those rows never wake later waits.
job_case4_watchlist() {
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512; simple_pr "$FIX" 1513
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=600 WATCH_DEBUG=1
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_calls 1 15 || { bail "no first cycle"; return; }
  t0=$(date +%s)
  echo busie/fe-main#1513 >> "$LIST"
  wait_text "$D/out" 'WATCHING: busie/fe-main#1513' 20 || bail "no WATCHING for the added PR"
  dt=$(($(date +%s) - t0))
  # 5 s floor + 2 s tick + the cycle itself.
  chk "WATCHING within 5 s of the 5 s floor" t_between "$dt" 4 10
  chk "the wait ended by watchlist" t_eq "$(reasons "$D/err")" "watchlist "
  # Old rows for #1513 (and #1512) are in the log; none may wake the next wait.
  sleep 11
  chk "no event wake from older rows (still 1 + 2 polls)" t_eq "$(ncalls)" 3
  kill "$(lock_pid)"
  wait_rc "$D/rc" 8 || bail "watcher ignored TERM"
  chk "TERM stops the watcher cleanly" t_eq "$(cat "$D/rc" 2>/dev/null)" 0
}

# Case 5: a row inserted during a cycle wakes the next wait; one logged before
# the wake does not wake it again.
job_case5_rowid() {
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=14 WATCH_MAX_CYCLES=4 WATCH_DEBUG=1 FAKE_DB=$DB FAKE_PAYLOAD="$(pr_ev 1512 busie/fe-main)"
  export FAKE_HOOK='case $c in 1|3) "$INS" "$FAKE_DB" pullrequest:comment_created busie/fe-main "$FAKE_PAYLOAD" ;; esac'
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 90 || { bail "did not finish"; return; }
  chk "rows logged during cycles 1 and 3 woke the next waits, nothing else did" t_eq "$(reasons "$D/err")" "event interval event "
  chk "event wake after cycle 1" t_between "$(gap 1 2)" 7 11
  chk "no re-wake from the row cycle 2's wake already saved" t_between "$(gap 2 3)" 13 16
  chk "event wake after cycle 3" t_between "$(gap 3 4)" 7 11
  chk "saved rowid is the log's newest" t_eq "$(cat "$D/w.state/event.rowid")" "$(max_rowid "$DB")"
}
# ...and after a re-arm, a row from the gap wakes the first wait.
job_case5_rearm() {
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=600 WATCH_DEBUG=1 WATCH_MAX_CYCLES=1
  launch "$NEW" "$D/out1" "$D/err1" "$D/rc1"
  wait_rc "$D/rc1" 15 || { bail "first arm did not finish"; return; }
  chk "first run saved the log's newest rowid" t_eq "$(cat "$D/w.state/event.rowid")" "$(max_rowid "$DB")"
  before=$(cat "$D/w.state/event.rowid")
  wake_comment                                          # logged while no watcher runs
  export WATCH_MAX_CYCLES=2
  launch "$NEW" "$D/out2" "$D/err2" "$D/rc2"
  wait_calls 2 15 || { bail "re-arm made no first cycle"; return; }
  chk "re-arm kept the saved rowid through its first cycle" t_eq "$(cat "$D/w.state/event.rowid")" "$before"
  wait_rc "$D/rc2" 30 || { bail "re-arm did not finish"; return; }
  chk "re-arm's first wait ended by event (row from the gap)" t_eq "$(reasons "$D/err2")" "event "
  chk "the gap row woke it after floor and batch" t_between "$(gap 2 3)" 7 11
  chk "re-arm sent no second WATCHING" t_lacks "$D/out2" WATCHING
  chk "first run did print WATCHING" t_has "$D/out1" WATCHING
}

# Case 6: regressions. DUPLICATE lock exit; resume from last/prev.tsv; MAX_CYCLES.
job_case6_duplicate() {
  setup; seed_db "$DB"; echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  # Event mode on: it ticks, so TERM is handled within 2 s. With it off the wait is
  # a plain `sleep`, which (as in 0.2.4) holds the TERM trap until it ends.
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=600
  launch "$NEW" "$D/outA" "$D/errA" "$D/rcA"
  wait_calls 1 15 || { bail "watcher A made no cycle"; return; }
  a=$(lock_pid)
  launch "$NEW" "$D/outB" "$D/errB" "$D/rcB"
  wait_rc "$D/rcB" 15 || bail "second watcher did not exit"
  chk "second watcher prints DUPLICATE" t_has "$D/outB" "DUPLICATE: a watcher (pid $a) is already active"
  chk "second watcher exits 0" t_eq "$(cat "$D/rcB" 2>/dev/null)" 0
  # (0.2.4 also deletes the owner's lock file on this exit; that is unchanged and not asserted.)
  chk "first watcher still running" t_alive "$a"
  kill "$a"
  wait_rc "$D/rcA" 8 || bail "watcher A ignored TERM"
  chk "TERM stops the first watcher cleanly" t_eq "$(cat "$D/rcA" 2>/dev/null)" 0
}
job_case6_resume() {
  setup; echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_INTERVAL=1 WATCH_MAX_CYCLES=1
  launch "$NEW" "$D/out1" "$D/err1" "$D/rc1"
  wait_rc "$D/rc1" 15 || { bail "first arm did not finish"; return; }
  sleep 3
  # A comment from the gap: newer than the first run's `last`, older than the re-arm's start.
  ts=$(date -u -v-1S +%Y-%m-%dT%H:%M:%S)+00:00
  pr_json OPEN "$TIP" '[]' "[$(cmt 77 "$ts" "$ts" 'looks wrong to me' 'Brady Perry' user)]" '[]' 'Trip planner' > "$FIX/1512.json"
  launch "$NEW" "$D/out2" "$D/err2" "$D/rc2"
  wait_rc "$D/rc2" 15 || { bail "re-arm did not finish"; return; }
  chk "first run sent WATCHING" t_has "$D/out1" 'WATCHING: busie/fe-main#1512'
  chk "re-arm sent no second WATCHING" t_lacks "$D/out2" WATCHING
  chk "re-arm resumed from last: the comment from the gap arrives" t_has "$D/out2" 'COMMENTS busie/fe-main#1512 — 1 new: Brady Perry (new): looks wrong to me'
}
# Bitbucket's real shape (RC #1511, PR #1512 on 2026-10-21): reviewers carry no `approved`;
# approvals are on participants, as REVIEWER or PARTICIPANT. 0.2.4 never saw them.
job_case10_approvals() {
  setup; echo busie/fe-main#1512 > "$LIST"
  rev='[{"display_name":"Brady Perry","nickname":"Brady"}]'
  none='[{"role":"REVIEWER","approved":false,"user":{"display_name":"Brady Perry"}},{"role":"PARTICIPANT","approved":false,"user":{"display_name":"Bitbucket Pipelines"}}]'
  both='[{"role":"PARTICIPANT","approved":true,"user":{"display_name":"Jason Schulz"}},{"role":"PARTICIPANT","approved":false,"user":{"display_name":"Bitbucket Pipelines"}},{"role":"REVIEWER","approved":true,"user":{"display_name":"Brady Perry"}}]'
  pr_json OPEN "$TIP" '[]' '[]' "$rev" 'Trip planner' "$none" > "$FIX/1512.1.json"
  pr_json OPEN "$TIP" '[]' '[]' "$rev" 'Trip planner' "$both" > "$FIX/1512.2.json"
  mkdir -p "$D/old/fix"; cp "$FIX"/*.json "$D/old/fix/"; cp "$LIST" "$D/old/w.watchlist"
  export WATCH_EVENTS=0 WATCH_INTERVAL=1 WATCH_MAX_CYCLES=2
  (
    export WATCH_LIST=$D/old/w.watchlist FIXDIR=$D/old/fix
    FIX=$D/old/fix launch "$T/old/watch-bb-pr-activity.sh" "$D/old/out" "$D/old/err" "$D/old/rc"
  )
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 20 || { bail "watcher did not finish"; return; }
  wait_rc "$D/old/rc" 20 || bail "0.2.4 run did not finish"
  chk "approvals on participants are reported, both roles, sorted" t_has "$D/out" 'APPROVALS: busie/fe-main#1512 — approved by Brady Perry, Jason Schulz — Trip planner'
  chk "an unapproved participant is not listed" t_lacks "$D/out" 'Bitbucket Pipelines'
  chk "0.2.4 missed the same approvals (the bug this fixes)" t_lacks "$D/old/out" 'APPROVALS'
}
# A leading zero must not make bash read the interval as octal: 08 crashed the early
# wake's arithmetic (exit 1 at the first wait) while 0.2.4's plain `sleep 08` worked.
job_case11_leading_zero() {
  setup; seed_db "$DB"; echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=08 WATCH_MAX_CYCLES=2 WATCH_DEBUG=1
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 30 || { bail "watcher did not finish"; return; }
  chk "WATCH_INTERVAL=08 runs to WATCH_MAX_CYCLES and exits 0" t_eq "$(cat "$D/rc"):$(ncalls)" "0:2"
  chk "the wait was the 8 s interval" t_between "$(gap 1 2)" 7 9
}
# Bitbucket spells a running build INPROGRESS (no underscore): 0.2.4 matched only
# IN_PROGRESS, so a build still running rolled up as "passing" (fe-main #1531, 2026-10-22).
job_case12_inprogress() {
  setup; echo busie/fe-main#1512 > "$LIST"
  pr_json OPEN "$TIP" "[{\"commit\":{\"hash\":\"$FULL\"},\"state\":\"INPROGRESS\"}]" '[]' '[]' 'Trip planner' > "$FIX/1512.json"
  mkdir -p "$D/old/fix"; cp "$FIX"/*.json "$D/old/fix/"; cp "$LIST" "$D/old/w.watchlist"
  export WATCH_EVENTS=0 WATCH_INTERVAL=1 WATCH_MAX_CYCLES=1
  (
    export WATCH_LIST=$D/old/w.watchlist FIXDIR=$D/old/fix
    FIX=$D/old/fix launch "$T/old/watch-bb-pr-activity.sh" "$D/old/out" "$D/old/err" "$D/old/rc"
  )
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 20 || { bail "watcher did not finish"; return; }
  wait_rc "$D/old/rc" 20 || bail "0.2.4 run did not finish"
  chk "an INPROGRESS build on the tip reads pending" t_has "$D/out" 'CI: pending'
  chk "...not passing" t_lacks "$D/out" 'CI: passing'
  chk "0.2.4 called the same build passing (the bug this fixes)" t_has "$D/old/out" 'CI: passing'
}
job_case6_maxcycles() {
  setup; echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_INTERVAL=1 WATCH_MAX_CYCLES=3 WATCH_DEBUG=1
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 20 || { bail "did not stop at WATCH_MAX_CYCLES"; return; }
  chk "exits 0 after exactly WATCH_MAX_CYCLES cycles" t_eq "$(cat "$D/rc"):$(ncalls)" "0:3"
  chk "default event DB path never read: waits ended by interval" t_eq "$(reasons "$D/err")" "interval interval "
}

# Case 7: with event mode off (WATCH_EVENTS=0, or no DB) the wait is the plain
# 0.2.4 sleep: a watchlist append mid-wait does NOT end it early.
case7() {  # variant
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512; simple_pr "$FIX" 1513
  case $1 in
    off)  export WATCH_EVENT_DB=$DB WATCH_EVENTS=0 ;;
    nodb) export WATCH_EVENT_DB=$D/missing.sqlite ;;
  esac
  export WATCH_INTERVAL=12 WATCH_MAX_CYCLES=2 WATCH_DEBUG=1
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_calls 1 15 || { bail "no first cycle"; return; }
  echo busie/fe-main#1513 >> "$LIST"
  wait_rc "$D/rc" 30 || { bail "did not finish"; return; }
  chk "[$1] append mid-wait did not end the wait early" t_eq "$(reasons "$D/err")" "interval "
  chk "[$1] the wait lasted the whole interval" t_between "$(gap 1 2)" 12 13
  chk "[$1] the added PR is picked up at the next poll" t_has "$D/out" 'WATCHING: busie/fe-main#1513'
}
job_case7_off()  { case7 off; }
job_case7_nodb() { case7 nodb; }

# Case 8: when event.rowid cannot be written, the row that caused a wake must
# not wake every later wait (the last-seen rowid is also kept in memory).
job_case8_rowid_memory() {
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  mkdir -p "$D/w.state"; max_rowid "$DB" > "$D/w.state/event.rowid"; chmod 444 "$D/w.state/event.rowid"
  seeded=$(cat "$D/w.state/event.rowid")
  chk "fixture rowid file is really unwritable" sh -c "! (echo x 2>/dev/null > '$D/w.state/event.rowid')"
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=14 WATCH_MAX_CYCLES=3 WATCH_DEBUG=1 FAKE_DB=$DB FAKE_PAYLOAD="$(pr_ev 1512 busie/fe-main)"
  export FAKE_HOOK='[ "$c" = 1 ] && "$INS" "$FAKE_DB" pullrequest:comment_created busie/fe-main "$FAKE_PAYLOAD"'
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 60 || { bail "did not finish"; return; }
  chk "one event wake, then no re-wake from the same row" t_eq "$(reasons "$D/err")" "event interval "
  chk "the rowid file really stayed stale" t_eq "$(cat "$D/w.state/event.rowid")" "$seeded"
}

# Case 9: a cycle longer than the interval is never followed by an immediate
# one: the interval counts from the end of the cycle (3 s cycle, 3 s interval).
case9() {  # variant
  setup; seed_db "$DB"
  echo busie/fe-main#1512 > "$LIST"; simple_pr "$FIX" 1512
  export WATCH_EVENT_DB=$DB WATCH_INTERVAL=3 WATCH_MAX_CYCLES=3 WATCH_DEBUG=1 FAKE_HOOK='sleep 3'
  [ "$1" = off ] && export WATCH_EVENTS=0
  launch "$NEW" "$D/out" "$D/err" "$D/rc"
  wait_rc "$D/rc" 60 || { bail "did not finish"; return; }
  # 3 s cycle + >= 2 s wait; back-to-back polling would show 3.
  chk "[$1] cycle starts are at least a cycle plus most of an interval apart" t_between "$(gap 1 2)" 4 8
  chk "[$1] ...every time" t_between "$(gap 2 3)" 4 8
}
job_case9_longcycle_on()  { case9 on; }
job_case9_longcycle_off() { case9 off; }

# ---- run -----------------------------------------------------------------------
mkdir "$T/old" "$T/res"
git -C "$ROOT" show "$BASE_SHA:plugins/bb-pr-watch/scripts/watch-bb-pr-activity.sh" > "$T/old/watch-bb-pr-activity.sh" \
  || { echo "cannot read the 0.2.4 script at $BASE_SHA"; exit 1; }

JOBS="syntax case1_nodb case1_off case1_locked case1_locked60 case1_unreadable case1_nosqlite case2_comment case3_status case4_watchlist case5_rowid case5_rearm case6_duplicate case6_resume case6_maxcycles case7_off case7_nodb case8_rowid_memory case9_longcycle_on case9_longcycle_off case10_approvals case11_leading_zero case12_inprogress"
for j in $JOBS; do
  ( JOB=$j; "job_$j"; echo "DONE: $j" ) > "$T/res/$j.txt" 2>&1 &
done
wait
pass=0 fail=0
for j in $JOBS; do
  cat "$T/res/$j.txt" | grep -v '^DONE:'
  grep -q "^DONE: $j" "$T/res/$j.txt" || { echo "FAIL: $j: job did not complete"; fail=$((fail + 1)); }
  pass=$((pass + $(grep -c '^PASS' "$T/res/$j.txt")))
  fail=$((fail + $(grep -c '^FAIL' "$T/res/$j.txt")))
done
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
