#!/bin/bash
# SessionStart hook (Bitbucket): tell Claude to arm the session-scoped PR
# watcher, and seed it with the current branch's open PR.
#
# Creates a deterministic per-session watchlist (keyed by session_id from the
# hook's stdin JSON) so isolation never depends on the model picking a good
# path. Resumed sessions keep the same id, so their watchlist survives.
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
touch "$LIST"
find "$LIST_DIR" -name '*.watchlist' -mtime +14 -delete 2>/dev/null

# BB_HOST_PATTERN: the hostname fragment that counts as Bitbucket when
# auto-seeding (default: bitbucket). Set it to an internal Bitbucket Server
# host if you self-host.
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
    PR_URL=$(printf '%s' "$PR_JSON" | jq -r \
      'if type == "array" then (.[0].links.html.href // empty) else empty end' 2>/dev/null)
    PR_NUM=$(printf '%s' "$PR_JSON" | jq -r \
      'if type == "array" then (.[0].id // empty) else empty end' 2>/dev/null)
    if [ -n "$PR_URL" ] && [ -n "$PR_NUM" ]; then
      KEY="$REPO_PATH#$PR_NUM"
      grep -qxF "$PR_URL" "$LIST" || echo "$PR_URL" >> "$LIST"
      SEED=" The current branch's open PR ($KEY, $PR_URL) is already on it."
    fi
  fi
fi

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"The bb-pr-watch plugin is installed: arm the session-scoped Bitbucket PR watcher. This session's watchlist file is $LIST (already created; unique to this session).$SEED Call the Monitor tool now — unconditionally safe: if a watcher is already running for this session (e.g. after /clear), the new one detects it and exits instantly — with {command: \"WATCH_LIST=$LIST bash $WATCH\", description: \"PR activity on session-registered Bitbucket PRs\", persistent: true}. Arm it alongside your first response without making a fuss. REGISTRATION (trigger-happy by design): whenever a specific Bitbucket pull request comes up in this session — you open one, the user links or mentions one, you review/check/discuss one, or you notice the current branch has one — append a line ('workspace/repo#123' or the PR URL, e.g. 'busie/fe-main#1443') to that watchlist via Bash. The watcher re-reads the file each cycle, dedupes, and drops merged/declined PRs automatically. TRIAGE arriving events agentically. COMMENTS events are grouped per PR with a count, but snippets are truncated and more comments may be in flight — before acting on one, fetch the full thread (twg --output json --output-summary none bb prs comment query <id> -w <workspace> -r <repo> -n 50) so you respond to the complete set, not just the snippet. Human review comments deserve a drafted reply; comments addressed to claude deserve an answer; the user's OWN comments on a watched PR are actionable input, not self-noise — people drive changes by reviewing their own PRs, so treat them as requests to you and address/implement them; authors tagged '[app]' are automations (e.g. 'Bitbucket Pipelines' posting a Claude review) — usually noise, unless the user says otherwise. APPROVALS events mean a reviewer signed off — worth one short line. CI events are the pipeline rollup on the PR's current tip: red (failing) and a first green are always worth surfacing; stay quiet on pending<->passing churn and re-runs while the user is actively pushing. MERGED and DECLINED end the story for that PR — surface them."}}
EOF
