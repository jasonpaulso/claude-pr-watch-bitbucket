# bb-pr-watch

Live **Bitbucket** PR watching **inside your Claude Code session**. Each session registers the PRs it actually touches — ones you open, link, review, or discuss — and a background monitor pushes their events into the running session. Claude wakes on each one, with your full working context, and triages:

- 💬 **Comments** — new general and inline comments, grouped into one event per PR per cycle with a count (a five-comment review arrives as one event saying five). Claude drafts replies to human review comments, treats your own comments as change requests (reviewing your own PR is a great way to drive Claude), answers anything addressed to it, and quietly ignores bot noise.
- 👍 **Approvals** — one line when a reviewer signs off.
- 🚦 **CI (Bitbucket Pipelines)** — the rollup over the build statuses attached to the PR's *current* tip commit: `passing` / `failing` / `pending` / `no-build`. Red is always surfaced; pending↔passing flapping while you push is self-throttled.
- 🎉 **Merges and declines** — detected from PR state, then the PR drops off the watchlist automatically.
- 👀 **WATCHING confirmations** — one event when a PR joins the list.
- ⚠️ **WATCH ERROR** — a PR lookup failed (bad key, no access, `twg` not authenticated). Reported once per failure streak, not once per poll.

A `SessionStart` hook arms the watcher automatically in every session and tells Claude to register PRs liberally as they come up. It also checks whether your current branch has an open PR (`twg bb prs query --source <branch>`) and seeds the watchlist with it — so the PR you're working on is watched from the first minute, zero-touch.

## Why session-scoped?

Watching *all* your open PRs sounds nice and is mostly noise: with dozens of PRs across repos you drown in bot chatter and CI flaps from work you're not thinking about. Scoping to the PRs this session has interacted with keeps events relevant to what you and Claude are actually doing.

## Why this instead of the Bitbucket app / webhooks?

Nothing event-driven can reach a local process, and the web UI responds with fresh context. This plugin is the "push into the session that has my context" equivalent: polling under the hood (one `twg` call per PR per cycle), push from the session's perspective.

## Requirements

- [`twg`](https://Atlassian) — the Atlassian Teamwork Graph CLI, installed and authenticated against your site (it fronts Bitbucket Cloud). Check with `twg bb inbox -w <workspace>`.
- `jq`
- `git` (used only to detect the current branch/remote for seeding)
- macOS or Linux (the scripts are bash-3.2 compatible)

## Install

In Claude Code:

```
/plugin marketplace add <owner>/claude-pr-watch-bitbucket
/plugin install bb-pr-watch@bb-pr-watch
```

## Usage

- It just runs: mention a PR, open a PR, review a PR — Claude registers it, and its events appear in your session as they happen.
- Ask Claude to "watch this PR" / "watch busie/fe-main#1443" to register one explicitly.
- `/bb-pr-watch` — arm manually (e.g. after stopping it, or if you disable the auto-arm hook).
- Each session gets its own watchlist (`$TMPDIR/bb-pr-watch/<session-id>.watchlist`, created by the hook) — sessions never see each other's PRs, and a resumed session keeps its list. It's a plain text file (one `workspace/repo#num` or PR URL per line), re-read every cycle — you can edit it yourself.

## Tuning

Environment variables read by `scripts/watch-bb-pr-activity.sh`:

| Var | Default | Purpose |
| --- | --- | --- |
| `WATCH_LIST` | — (required) | Path to the watchlist file |
| `WATCH_INTERVAL` | `60` | Poll interval in seconds |
| `WATCH_STATE_DIR` | temp dir | Persistent state dir (pre-seeded state diffs on the first cycle) |
| `WATCH_MAX_CYCLES` | `0` (forever) | Stop after N cycles — useful for testing |
| `WATCH_SINCE` | now | ISO-8601 UTC floor for comments — set in the past to replay today's discussion on the first cycle |
| `WATCH_TWG` | `twg` | Path to the `twg` binary |

`BB_HOST_PATTERN` (read by the SessionStart hook) sets which git remote host counts as Bitbucket when auto-seeding — default `bitbucket`, set it to your Bitbucket Server hostname if you self-host.

## How it calls twg

One call per watched PR per cycle, which returns state, build statuses and comments in a single payload:

```
twg --output json --output-summary none bb prs get <id> \
    -w <workspace> -r <repo> --statuses --comments
```

`--output-summary none` matters: it keeps stdout as pure JSON (fed straight to `jq`) and stops `twg` from writing a per-run payload file for every poll. At ~1.3s per call, a 60s interval with a handful of PRs costs a few API calls per cycle.

## Limitations

- **Session-scoped**: nothing watches while no Claude Code session is open. For always-on coverage, pair with a webhook-backed bot.
- **Bitbucket Cloud**: keys are `workspace/repo#id`. Fork-based PRs (`project/repo (fork)`) need the fork's `workspace/repo`.
- A PR whose comment count exceeds what one `bb prs get --comments` call returns (the hydration page) may report late — keep discussions under ~50 comments per PR, or re-arm with `WATCH_SINCE` to replay them.
- Review-level "LGTM" approvals with no comment *are* covered (via the approvals set); unapproved-but-commented PRs show up as COMMENTS.
- Polling: comments/CI can lag up to one interval (~60s).

## License

MIT
