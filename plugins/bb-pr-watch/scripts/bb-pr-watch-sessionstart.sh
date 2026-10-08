#!/bin/bash
# SessionStart hook (Bitbucket): tell Claude to arm the session-scoped PR
# watcher, and seed it with the current branch's open PR.
#
# Creates a deterministic per-session watchlist (keyed by session_id from the
# hook's stdin JSON) so isolation never depends on the model picking a good
# path. Resumed sessions keep the same id, so their watchlist — and the
# watcher's state dir beside it — survive a /clear or a monitor re-arm.
#
# Seeds from the git remote of the checkout the session starts in: if the
# remote is a Bitbucket repository and its branch has an open PR, that PR goes
# on the list before Claude says a word (zero-touch).
#
# All Bitbucket access goes through the twg CLI (`twg bb ...`), which must be
# installed and authenticated against the user's Atlassian site.
#
# Output shape: a single JSON object on stdout, per the Claude Code hooks spec.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WATCH="$SCRIPT_DIR/watch-bb-pr-activity.sh"
TWG="${WATCH_TWG:-twg}"

if ! command -v "$TWG" >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"The bb-pr-watch plugin is installed but its dependencies are missing (needs the twg CLI, authenticated against your Atlassian site, and jq). Do not arm the watcher. If the user asks about PR watching, tell them to install/authenticate twg and install jq."}}
EOF
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
[ -z "$SESSION_ID" ] && SESSION_ID="fallback-$$-$(date +%s)"
LIST_DIR="${TMPDIR:-/tmp}/bb-pr-watch"
mkdir -p "$LIST_DIR"
LIST="$LIST_DIR/$SESSION_ID.watchlist"
STATE="$LIST_DIR/$SESSION_ID.state"
mkdir -p "$STATE"
touch "$LIST"
# Sweep long-dead sessions' watchlists and state.
find "$LIST_DIR" -maxdepth 1 \( -name '*.watchlist' -o -name '*.state' \) -mtime +14 -exec rm -rf {} + 2>/dev/null

# Which git remote host counts as Bitbucket when auto-seeding (default:
# bitbucket). Set BB_HOST_PATTERN to an internal Bitbucket Server host.
BB_HOST_PATTERN="${BB_HOST_PATTERN:-bitbucket}"

# --- Seed: the open PR for the branch this checkout is on, if any -----------
# Derive workspace/repo from the origin remote so the twg call does not depend
# on cwd or on twg re-detecting the remote.
SEED=""
ORIGIN=$(git config --get remote.origin.url 2>/dev/null)
REPO_PATH=""
case "$ORIGIN" in
  "") ;;
  *"$BB_HOST_PATTERN"*)
    # Strip .git, any scheme, any user@, then the host and its separator:
    #   git@bitbucket.org:busie/fe-main.git      -> busie/fe-main
    #   https://bitbucket.org/busie/fe-main.git   -> busie/fe-main
    REPO_PATH=$(printf '%s' "$ORIGIN" | sed -E \
      -e 's#\.git/?$##' -e 's#^[a-zA-Z+]+://##' -e 's#^[^@/]+@##' -e 's#^[^:/]+[:/]##')
    ;;
esac
if [ -n "$REPO_PATH" ] && printf '%s' "$REPO_PATH" | grep -qE '^[^/ ]+/[^/ ]+$'; then
  WS=${REPO_PATH%%/*}
  REPO=${REPO_PATH##*/}
  BRANCH=$(git branch --show-current 2>/dev/null)
  [ -z "$BRANCH" ] && BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ]; then
    PR_JSON=$($TWG --output json --output-summary none bb prs query \
      --source "$BRANCH" --state OPEN -n 5 -w "$WS" -r "$REPO" 2>/dev/null </dev/null)
    PR_NUM=$(printf '%s' "$PR_JSON" | jq -r \
      'if type == "array" then (.[0].id // empty) else empty end' 2>/dev/null)
    PR_URL=$(printf '%s' "$PR_JSON" | jq -r \
      'if type == "array" then (.[0].links.html.href // empty) else empty end' 2>/dev/null)
    if [ -n "$PR_NUM" ] && [ -n "$PR_URL" ]; then
      grep -qxF "$PR_URL" "$LIST" || echo "$PR_URL" >> "$LIST"
      SEED=" It already contains $REPO_PATH#$PR_NUM ($PR_URL) — the open PR for the current branch."
    fi
  fi
fi

# Keep this text in sync with skills/bb-pr-watch/SKILL.md.
# The Monitor tool here has NO `persistent` option: timeout_ms defaults to
# 5 minutes and caps at 30 (1800000). Ask for the cap, and re-arm on expiry —
# state lives in $STATE, so a re-arm is gap-free and does not re-confirm.
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"The bb-pr-watch plugin is installed: arm the session-scoped Bitbucket PR watcher. This session's watchlist is $LIST (created now, unique to this session; its state dir is $STATE).$SEED Arm it with the Monitor tool: {command: \"WATCH_LIST=$LIST bash $WATCH\", description: \"PR activity on session-registered Bitbucket PRs\", timeout_ms: 1800000}. Ask for timeout_ms 1800000 — that is the maximum (30 min); there is no persistent option. When you see '[Monitor timed out — re-arm if needed]' and the watch is still wanted, call Monitor again with the same arguments: state persists in $STATE, so a re-arm covers the gap without missing events and does not re-send WATCHING for PRs already being watched. Arm it alongside your first response without making a fuss. REGISTRATION (trigger-happy by design): whenever a specific Bitbucket pull request comes up — you open one, the user links or mentions one, you review/check/discuss one, or you notice the current branch has one — append a line ('workspace/repo#123' or the PR URL, e.g. 'busie/fe-main#1443') to $LIST via Bash. The watcher re-reads the file each cycle, dedupes, and drops merged/declined PRs automatically. TRIAGE arriving events agentically. COMMENTS events are grouped per PR with a count, and each entry is labelled 'author (kind, source)': (new) or (edited) — an EDITED comment is news, the CI Claude review edits one comment rather than posting a new one, so a fresh finding arrives as (edited); (edited) is hash-gated on the comment body, so it means the text changed, never just a moved updated_on; the optional source suffix names who really spoke — (…, review-bot) is an AI reviewer (handle it like a human reviewer: every finding gets fixed, refuted with evidence, or tracked — never dismissed because it is a bot), (…, automation) is a machine notice posted under a human name (Nx Cloud's 'View your CI Pipeline Execution' links land as Brady Perry) — ignore it, (…, app) is another app/bot account, same treatment; a label with no suffix is a human. Snippets are truncated and more may be in flight — before acting on a COMMENTS event, fetch the full thread (twg --output json --output-summary none bb prs comment query <id> -w <workspace> -r <repo> -n 50). Human review comments deserve a drafted reply; anything addressed to claude deserves an answer. Comments ending in '-CC' are your own posted words and are already filtered out — if you post a comment WITHOUT that signature, append its comment id (from the create call's JSON) to $STATE/posted.ids so it is never echoed back to you. APPROVALS means a reviewer signed off — one short line, then silence. CI events are the pipeline rollup on the PR's current tip: red (failing) and a first green are worth surfacing; stay quiet on pending<->passing churn and re-runs while the user is actively pushing. MERGED and DECLINED end the story for that PR — surface them."}}
EOF
