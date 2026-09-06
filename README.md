# vibeScroll

A macOS menu bar app that watches your AI coding agents and teaches you
something relevant to whatever they are doing right now.

When an agent runs `git rebase`, you get a card about rebasing. When it edits a
lockfile, you get a card about lockfiles. The card never takes focus, never
blocks the agent, and paces itself so it stays useful instead of chatty.

Supports 11 agents through their own hook systems, plus a universal wrapper for
anything else.

## How it works

```
Agent (Claude Code / Codex / Cursor / …)
  │  runs the hook command it was configured with
  ▼
vibescroll hook --agent <kind>          ← same binary, CLI role. Always exits 0.
  │  decodes that agent's payload shape → AgentEvent (tool name + target)
  ▼
~/.vibescroll/vibescroll.sock           ← queued to disk if the app is closed
  ▼
AppDaemon  →  SessionStore  →  CategoryResolver  →  TopicCategory
                                                        │
                          ContentStore (cached catalogue from the backend)
                                                        │
                                   CardScheduler (dwell + cooldown gates)
                                                        ▼
                                              the floating card
```

Two rules the whole design follows:

- **The hook never blocks the agent.** It exits 0 on every path, including an
  unparseable payload. A non-zero exit is read by some agents as "deny this
  tool" or "keep working", so a monitoring hook that can fail closed is a bug.
- **Core logic reads no clock.** `SessionStore`, `CategoryResolver` and
  `CardScheduler` all take `now` as a parameter, which is why time-dependent
  behaviour (cooldowns, staleness, dwell) is directly testable.

## Layout

| Path | What |
| --- | --- |
| `Sources/VibeScrollCore/` | Pure logic: event decoding, state machine, category resolution, pacing. No AppKit, fully tested. |
| `Sources/App/` | The macOS app: daemon, menu bar, card panel, settings — plus the `hook` and `run` CLI roles. |
| `Tests/` | 127 tests over the core. |

The teaching content is served by a separate repository,
[vibeScroll-backend](../vibeScroll-backend). The two are coupled only by an
HTTP contract and the shared `TopicCategory` vocabulary, so either can be
deployed, rebuilt or replaced without touching the other.

## Running it

**Backend** — see [vibeScroll-backend](../vibeScroll-backend):

```bash
cd ../vibeScroll-backend
npm install
npm start            # http://127.0.0.1:8787
```

The app defaults to that address and can be pointed elsewhere in
Settings → Content.

**App**

```bash
./scripts/build-app.sh
open build/vibeScroll.app
```

Then open **Settings → Integrations** and install the hook for each agent you
use. The hook command points at the app bundle's binary, so rebuilding to a
different location means reinstalling the hooks.

For an agent with no hook system, wrap it:

```bash
vibescroll run -- <your command>
```

## Sounds

Two alerts, set independently in Settings → General: one when an agent finishes,
one when it needs your input. Each can be silenced, set to any of the 14 sounds
macOS ships, or pointed at a file of your own.

vibeScroll plays these itself rather than attaching them to the notification.
That means they are heard even with notifications turned off, and the app owns
the choice — but it also means they ignore Focus. The notification banners are
sent deliberately silent so nothing is ever announced twice.

No sounds are bundled and none are downloaded. The system set costs nothing to
ship and raises no licensing question; a file you pick is your own, so the same
holds. Sourcing a curated pack was considered and deferred — on Freesound the
licence varies per sound, and the CC-BY portion would require shipping
attribution for what amounts to a few chimes. If a pack is ever added, CC0-only
sources (Kenney, Pixabay, Freesound filtered to CC0) avoid that entirely.

A burst is throttled to one sound every two seconds. Four agents finishing
together should be one chime, not four overlapping ones.

## Quota

There are two ways to learn you have run out, and they answer different
questions.

**Reactive, always on.** Claude Code records API failures in its transcript —
the same file already read for token counts, so this costs one extra check per
scan and no new permissions:

```json
{"type":"system","subtype":"api_error","level":"error",
 "error":{"message":"429 {…\"type\":\"rate_limit_error\"…}"},
 "retryAttempt":10,"maxRetries":10,"retryInMs":39653}
```

The alert fires only on a rate limit, and only on the final attempt. Both
filters matter: a 529 `overloaded_error` means the provider is busy rather than
that your quota is gone, and a single stall produces up to ten records of which
nine resolve themselves. Announcing every one would be noise, and announcing an
overload as a quota failure would be wrong.

**Proactive, opt-in.** Settings → General → Quota reads the sign-in Claude Code
keeps in the Keychain and asks Anthropic how much of the plan is left, every
five minutes. It reports per window:

```
limits[0]  kind=session     percent=73  severity=normal   is_active=false
limits[1]  kind=weekly_all  percent=77  severity=warning  is_active=true
```

Severity comes from the provider, so no threshold is invented here; exhaustion
is keyed off `percent >= 100`, which cannot drift when they rename a label. An
unrecognised severity is treated as unknown rather than critical, so a field
added later cannot trigger false alarms.

This probe is off by default and is the only part of vibeScroll that reads a
credential or contacts a provider. It is read-only — the token is never written
back or refreshed — but the endpoint is not a published API and the request
identifies itself as Claude Code, so it can stop working without notice. That
trade is stated in the Settings footer too, so it can be judged without reading
the source.

## Content

Cards are authored and served by [vibeScroll-backend](../vibeScroll-backend);
its README covers the card format and the validator.

What matters on this side is the contract:

- The client fetches `/v1/catalog` once at launch and every six hours, sending
  `If-None-Match` so an unchanged catalogue costs a 304 instead of a download.
- The whole catalogue is cached to `~/.vibescroll/cache/catalog.json`, so the
  app keeps showing cards with the backend unreachable. A failed refresh is
  silent by design — yesterday's cards beat an empty surface.
- `TopicCategory` is the shared vocabulary. Adding a category means adding it
  here **and** in the backend's `CATEGORIES`. Server-first is safe: an unknown
  category degrades to `generic` on an older client rather than failing the
  decode, so the app never has to ship in lockstep with content.

## Tuning what you see

Settings → General has three pacing presets. They set four coupled numbers that
only make sense together:

| Preset | Dwell | Global gap | Same-topic gap |
| --- | --- | --- | --- |
| Calm | 15s | 5 min | 1 hr |
| Normal | 8s | 90s | 15 min |
| Eager | 4s | 30s | 5 min |

*Dwell* is how long an agent must stay on one topic before it counts — it is
what stops the card strobing while an agent fires tool calls several times a
second.

A card stays until you dismiss it with the **×**. The **›** button appears once
the text has finished writing, and advances to
the next one: unseen material in the current topic first, then other topics,
and once you have seen everything it cycles the oldest card rather than going
inert. Browsing suppresses automatic cards until you dismiss — pressing Next
means you are reading, and the surface should not replace itself under you.
Cards you browse to count as seen, so they will not resurface on their own.

Card text is revealed character by character, locally — there is no streaming
involved, just a timed reveal. Click the card to skip to the end, and the effect
is disabled entirely when the system asks for reduced motion.

The **list** button in the card header (and *Show all sessions* in the menu bar)
switches the same panel to every live session: a status dot, the agent, the
project, tokens burned, and how long it has been in that state. The panel grows with the number
of sessions, capped so an ambient surface never takes over the screen.

Clicking a session opens the window it is running in. How precisely that lands
depends on the host, and the row only becomes clickable when it can do
something:

| Host | Where the click lands |
| --- | --- |
| Terminal.app, iTerm2 | The exact window **and tab** (both publish a per-tab tty over AppleScript) |
| Warp | The exact pane, via `WARP_FOCUS_URL` |
| VS Code, Cursor, Windsurf | The **window** holding that project — these expose no API for selecting a terminal tab |
| Anything else | The app is brought to the front |

Token counts come from the agent's own transcript and are read incrementally
from a stored byte offset, so repeated scans never double-count. Only Claude
Code and Codex write a transcript we can read; the other nine agents show no
count at all rather than a misleading zero. A session that was already running
when the app starts banks its whole history on the first scan, which is what
makes the figure a session total rather than "since launch".

Cost is accumulated alongside but deliberately not displayed. `ModelPricing`
matches model families by substring against hardcoded per-million rates, and on
a cache-heavy Claude Code session it produced $213 for a single conversation —
a number that is both unverified and meaningless to anyone on a subscription
plan, who pays a flat fee regardless. It stays in the data for a future view
that can explain it; it does not go on a card.

For an agent running as an IDE extension there is no `TERM_PROGRAM` and no tty
at all, so the host is identified by `__CFBundleIdentifier`, which Launch
Services sets on GUI-started processes and children inherit.

## Attribution

The event pipeline is derived from [AgentPet](https://github.com/ntd4996/agentpet)
(MIT). See [NOTICE.md](NOTICE.md) for exactly what was taken, what is new, and
what was deliberately left behind.
