# bb-pr-watch

Live **Bitbucket** PR watching **inside your Claude Code session**. Each session registers the PRs it actually touches — ones you open, link, review, or discuss — and a background monitor pushes their events into the running session. Claude wakes on each one, with your full working context, and triages:

- 💬 **Comments** — new *and edited* comments, grouped into one event per PR per cycle with a count (a five-comment review arrives as one event saying five). Each entry is labelled so Claude knows whose voice it is and whether it is news — see [Event tags](#event-tags).
- 👍 **Approvals** — one line when a reviewer signs off.
- 🚦 **CI (Bitbucket Pipelines)** — the rollup over the build statuses attached to the PR's *current* tip commit: `passing` / `failing` / `pending` / `no-build`. Red is always surfaced; pending↔passing flapping while you push is self-throttled.
- 🎉 **Merges and declines** — detected from PR state, then the PR drops off the watchlist automatically.
- 👀 **WATCHING confirmations** — one event when a PR joins the list, and *only* then: a monitor re-arm does not re-confirm.
- ⚠️ **WATCH ERROR** — a PR lookup failed (bad key, no access, `twg` not authenticated). Reported once per failure streak, not once per poll.

A `SessionStart` hook arms the watcher automatically in every session and tells Claude to register PRs liberally as they come up. It also checks whether your current branch has an open PR (`twg bb prs query --source <branch>`) and seeds the watchlist with it — so the PR you're working on is watched from the first minute, zero-touch.

## Why session-scoped?

Watching *all* your open PRs sounds nice and is mostly noise: with dozens of PRs across repos you drown in bot chatter and CI flaps from work you're not thinking about. Scoping to the PRs this session has interacted with keeps events relevant to what you and Claude are actually doing.

## Requirements

- [`twg`](https://Atlassian) — the Atlassian Teamwork Graph CLI, installed and authenticated against your site (it fronts Bitbucket Cloud). Check with `twg bb inbox -w <workspace>`.
- `jq`
- `git` (used only to detect the current branch/remote for seeding)
- macOS or Linux (the scripts are bash-3.2 compatible)

## Install

In Claude Code:

```
/plugin marketplace add jasonpaulso/claude-pr-watch-bitbucket
/plugin install bb-pr-watch@bb-pr-watch
```

Then **start a new session** so the `SessionStart` hook runs. If you install mid-session, the hook never fires and there is no watchlist path in your context — that's expected, not broken; ask Claude to `/bb-pr-watch` and it will create one in its scratchpad and arm it.

## How the watch is armed, and what happens at 30 minutes

The Claude Code Monitor tool has **no `persistent` option** in current builds: it takes `timeout_ms`, defaulting to 5 minutes and capped at **30 minutes** (`1800000`). Every watch therefore dies on that deadline and you get `[Monitor timed out — re-arm if needed]`.

The plugin is built so that re-arming is cheap and lossless:

- The hook asks for `timeout_ms: 1800000` — the maximum.
- State is **durable and in a fixed location** derived from the watchlist: `<watchlist>.state/` holding `prev.tsv` (diff baseline), `last` (time of the last check), `done.keys`, `fail.keys`, `posted.ids`. Never a fresh `mktemp` dir.
- A re-arm resumes from `last`, so **nothing that landed in the gap between watches is missed**, and PRs already being watched are **not** re-confirmed — no second `WATCHING:` banner every half hour.
- A per-watchlist lock makes a double-arm harmless: the newcomer prints `DUPLICATE: a watcher (pid N) is already active` and exits, leaving the live one alone.
- After `/clear` the session id changes, so the lock can't see the pre-clear watcher; the script then *supersedes* it (same claude/node ancestor → kill it, newest wins), and never kills a process in its own ancestry.

Delete the state dir only when you retire the watchlist.

## Usage

- It just runs: mention a PR, open a PR, review a PR — Claude registers it, and its events appear in your session as they happen.
- Ask Claude to "watch this PR" / "watch busie/fe-main#1443" to register one explicitly.
- `/bb-pr-watch` — arm manually, or re-arm after a timeout.
- Each session gets its own watchlist (`$TMPDIR/bb-pr-watch/<session-id>.watchlist`) — sessions never see each other's PRs, and a resumed session keeps its list. It's a plain text file (one `workspace/repo#num` or PR URL per line), re-read every cycle — you can edit it yourself.

## Event tags

Every entry inside a `COMMENTS` event carries a `(kind, source)` label, because *who* said it decides what Claude should do:

Each entry inside a `COMMENTS` event is labelled `author (kind, source)`:

| Label | Meaning | Treatment |
| --- | --- | --- |
| `(new)` | a human posted since the last check | judge by author |
| `(edited)` | a human **edited** an existing comment — the text really changed, not just Bitbucket's `updated_on` — **this is news** | fetch and read it |
| `(new/edited, review-bot)` | an AI reviewer — the "🤖 Claude review", posted under *Bitbucket Pipelines* | treat exactly like a human reviewer: fix, refute with evidence, or track every finding |
| `(new/edited, automation)` | automation notice posted under a **human** name (Nx Cloud "View your CI Pipeline Execution" links land as Brady Perry) | ignore |
| `(new/edited, app)` | some other app/bot account | ignore unless unactioned |

`edited` matters more than it looks: the CI Claude review edits its single comment rather than posting a new one, so a fresh finding arrives with an old `created_on` and a new `updated_on`. A watcher that only polled creation time would never surface it.

Bitbucket also moves `updated_on` when nothing was written — a 👍 landing on an old comment, a re-index. So timestamps only pick **candidates**; every comment is fingerprinted (a hash of its body) the first time the watcher sees it, into `<state>/seen.tsv`, and a candidate fires only when its text differs from that fingerprint. Comments that predate the watch are fingerprinted silently, so the first reaction to an old comment is not reported as an edit.

Comments ending in `-CC` are your own posted words and are filtered out, as are ids listed in `<state>/posted.ids` — otherwise Claude answers itself in a loop.

## How it calls twg

One call per watched PR per cycle returns state, pipeline statuses and comments:

```
twg --output json --output-summary none bb prs get <id> \
    -w <workspace> -r <repo> --statuses --comments
```

`--output-summary none` matters twice over: stdout stays pure JSON (fed straight to `jq`), and `twg` writes no per-run payload file — which a long-lived poller would otherwise accumulate by the thousand. At ~1.3s per call, a 60s interval with a handful of PRs costs a few API calls per cycle.

CI is rolled up over the build statuses attached to the PR's **current tip** (`source.commit.hash` is a 12-char abbreviation, status hashes are full 40-char, so they're matched by prefix). Rolling up *all* statuses instead would let an old commit's `FAILED` pin the rollup forever.

## Tuning

Environment variables read by `scripts/watch-bb-pr-activity.sh`:

| Var | Default | Purpose |
| --- | --- | --- |
| `WATCH_LIST` | — (required) | Path to the watchlist file |
| `WATCH_INTERVAL` | `60` | Poll interval in seconds |
| `WATCH_STATE_DIR` | `<watchlist>.state` | State dir. Leave alone unless testing — a custom path must stay fixed across re-arms or you lose the gap |
| `WATCH_MAX_CYCLES` | `0` (forever) | Stop after N cycles — useful for testing |
| `WATCH_SINCE` | the stored `last`, else now | ISO-8601 UTC floor for comments — set in the past to replay recent discussion |
| `WATCH_TWG` | `twg` | Path to the `twg` binary |
| `WATCH_SIGNATURE` | `-CC` | Signature your own posted comments end with; those are filtered out |

`BB_HOST_PATTERN` (read by the SessionStart hook) sets which git remote host counts as Bitbucket when auto-seeding — default `bitbucket`; set it to your Bitbucket Server hostname if you self-host.

## Limitations

- **Session-scoped**: nothing watches while no Claude Code session is open. For always-on coverage, pair with a webhook-backed bot.
- **Bitbucket Cloud**: keys are `workspace/repo#id`. Fork-based PRs need the fork's `workspace/repo`.
- Comments beyond the hydration page of one `bb prs get --comments` call may report late — keep discussions under ~50 comments per PR.
- Polling: comments/CI can lag up to one interval (~60s).
- The Monitor's ceiling is 30 minutes, so a watch is a chain of re-arms, not one continuous process.

## Credits

Port of [`claude-pr-watch`](https://github.com/RobHannay/claude-pr-watch) (MIT) by **Rob Hannay** — the GitHub watcher this Bitbucket version is derived from. Same architecture (a `SessionStart` hook arms a per-session `Monitor` that polls and pushes events into the session); all forge access goes through the `twg` CLI instead of `gh`, and the polling, key format, CI rollup, and event taxonomy are rebuilt for Bitbucket Cloud.

## License

MIT
