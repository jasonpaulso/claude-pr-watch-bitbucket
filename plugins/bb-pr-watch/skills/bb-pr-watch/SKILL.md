---
description: Arm (or re-arm) the session-scoped Bitbucket PR watcher, or register a PR with it. Use when the user asks to watch a Bitbucket pull request, asks what happened on a PR, or the auto-armed watcher was stopped or timed out and should be restarted.
---

# Session-scoped Bitbucket PR watcher

The watcher monitors only the PRs **this session registers** — not all of the user's open PRs. Events (new and edited comments, approvals, CI/pipeline changes, merges/declines) arrive as notifications in this session. All Bitbucket access goes through the `twg` CLI (`twg bb ...`).

## Arming

1. Check dependencies: `twg` (installed, authenticated against the user's Atlassian site) and `jq` on PATH. If missing, tell the user and stop.
2. Find the watchlist path. The SessionStart hook normally names it in your context (`.../bb-pr-watch/<session-id>.watchlist`). **If it isn't there, the plugin was installed after this session began — that is expected, not broken.** Create one yourself in your scratchpad, named after the session.
3. Call the Monitor tool with:
   - `command`: `WATCH_LIST=<absolute watchlist path> bash "${CLAUDE_PLUGIN_ROOT}/scripts/watch-bb-pr-activity.sh"`
   - `description`: `PR activity on session-registered Bitbucket PRs`
   - `timeout_ms`: `1800000`

`timeout_ms: 1800000` (30 minutes) is the maximum this Monitor accepts — there is **no `persistent` option**, so don't pass it. Every watch dies at that deadline and you get `[Monitor timed out — re-arm if needed]`.

**Re-arming is cheap, so do it.** State lives in a fixed directory beside the watchlist (`<watchlist>.state`: `prev.tsv`, `last`, `done.keys`, `fail.keys`, `posted.ids`) — never a fresh temp dir. A re-arm with the same command resumes from the last check, so nothing that landed in the gap is missed and PRs already being watched are not re-confirmed. Re-arm whenever you see the expiry notice and the watch is still wanted (i.e. always, unless the user stopped it). Delete the state dir only when the watchlist is retired.

## Registering PRs — be trigger-happy

Append a line (`workspace/repo#123` or the PR URL) to the watchlist whenever a specific pull request comes up:

- you open or update a PR
- the user links, mentions, or asks about one
- you review one, check its pipeline, or discuss it
- the current branch has an open PR

Examples: `busie/fe-main#1443`, `https://bitbucket.org/busie/fe-main/pull-requests/1443`. The watcher re-reads the file every cycle: registration takes effect within one interval, duplicates are deduped, and merged/declined PRs are dropped automatically (a `WATCHING:` confirmation fires once per new PR, and is not re-sent on a re-arm).

## Handling events

Triage agentically — surface and act on what matters, stay quiet on noise.

A COMMENTS event is grouped per PR with a count. Each entry is labelled
`author (kind, source)`. **The label tells you what to do:**

| Label | What it is | Treatment |
| --- | --- | --- |
| `(new)` | a human posted since the last check | draft a reply where sensible |
| `(edited)` | a human **edited** an existing comment (text really changed, not just `updated_on`) | **this is news, not noise.** Fetch and read it. |
| `(new/edited, review-bot)` | an AI reviewer — the "🤖 Claude review", posted under *Bitbucket Pipelines* | treat exactly like a human reviewer |
| `(new/edited, automation)` | automation notice posted under a **human** name | ignore |
| `(new/edited, app)` | some other app/bot account | ignore unless unactioned |

Why the tags matter, concretely:

- **Edited is a real channel.** The CI Claude review edits its single comment instead of posting a new one, so a fresh finding arrives as `(edited, review-bot)` with an old `created_on`. A watcher that only looked at creation times would never surface it. Same for the Nx Cloud comment. Timestamps only pick candidates: every comment is fingerprinted (body hash, `<state>/seen.tsv`) the first time it is seen, and a candidate fires only if its text differs from the fingerprint — so a moved `updated_on` with unchanged text, including the first reaction to a comment that predates the watch, fires nothing.
- **`review-bot` is a reviewer, not noise.** The "🤖 Claude review" posted under *Bitbucket Pipelines* has caught genuine regressions. Every finding must be fixed, refuted with evidence, or tracked — never skipped because a bot wrote it.
- **`automation` is not a human speaking.** Nx Cloud posts "View your [CI Pipeline Execution ↗](https://cloud.nx.app/...)" under **Brady Perry's** name, so it reads like review feedback from a person. It is automation: don't reply, don't act, unless nobody has dispositioned it.

Other events:

- `APPROVALS: ... approved by X` — a reviewer signed off. One short line, then silence.
- `CI: ... now failing` — surface it, and diagnose. First green after a failure — surface it. `pending`↔`passing` churn and re-runs while the user is actively pushing — stay quiet.
- `MERGED` / `DECLINED` — end of the story for that PR; surface it.
- `WATCH ERROR: <key> — <message>` — the lookup failed (bad key, no access, `twg` not authenticated). Already deduped: you get one line per failure streak, so if you see one, say something rather than shrugging.
- `DUPLICATE: a watcher (pid N) is already active` — harmless: you tried to arm twice; events continue from the existing watcher. Don't re-arm again.

Before acting on a COMMENTS event, fetch the whole thread — snippets are truncated:

```
twg --output json --output-summary none bb prs comment query <id> -w <workspace> -r <repo> -n 50
```

## Your own comments

Comments ending in `-CC` are your own posted words and are filtered out by the watcher, as are any ids listed in `<state>/posted.ids`. If you post a comment **without** the `-CC` signature, append its comment id (from the create call's JSON output) to `<state>/posted.ids` — otherwise it comes back to you as new input, and you can end up answering yourself in a loop.

## Tuning

Env vars: `WATCH_INTERVAL` (poll seconds, default 60), `WATCH_STATE_DIR` (defaults to `<watchlist>.state` — leave it alone unless testing), `WATCH_MAX_CYCLES` and `WATCH_SINCE` (testing/backfill), `WATCH_TWG` (path to the binary), `WATCH_SIGNATURE` (the signature your own comments end with, default `-CC`). The comment stream is deliberately unfiltered beyond the tags — triage is the consuming session's job.
