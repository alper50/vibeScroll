# vibeScroll

A macOS menu bar app that watches your AI coding agents and, while they work,
hands you something short to read: a true, one-glance fact about one of twenty
TV shows — from Game of Thrones and Breaking Bad to Dark, Medcezir and Behzat Ç.
`CardCategory` has the full list.

What the agent is doing sets the rhythm — a card waits until an agent has
settled into one kind of work, and the same kind of work does not trigger
another for a while. The shows take turns. The card never takes focus, never
blocks the agent, and paces itself so it stays pleasant instead of chatty.

The interface and the cards follow the Mac's language: English and Turkish.

Supports 12 agents through their own hook systems, plus a universal wrapper for
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
                                                        │  (when: what the agent is doing)
                                   CardScheduler (dwell + cooldown gates)
                                                        │
                          ContentStore (cached catalogue, in the device's language)
                                                        │  (which: least recently shown, any show)
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
| `Resources/Localization/` | The interface's string catalogue (English source, Turkish translations). |
| `Tests/` | 389 tests over the core. |

The cards are served by a separate repository,
[vibeScroll-backend](../vibeScroll-backend). The two are coupled only by an
HTTP contract and two shared lists — `CardCategory` and `ContentLanguage` — so
either can be deployed, rebuilt or replaced without touching the other.

## Running it

**Backend** — the app ships pointing at the hosted catalogue and needs nothing
set up. To run your own, see [vibeScroll-backend](../vibeScroll-backend):

```bash
cd ../vibeScroll-backend
npm install
npm start            # http://127.0.0.1:8787
```

Then point Settings → Content at that address.

The default origin is **https**, and not by preference: the bundle ships
`NSAllowsLocalNetworking`, so App Transport Security allows plain HTTP to
loopback and the local network and refuses it anywhere else. Loopback is still
permitted, which is why the local address above works unchanged.

**App**

```bash
./scripts/build-app.sh
open build/vibeScroll.app
```

Then open **Settings → Integrations** and install the hook for each agent you
use. The first launch opens this window by itself: a menu bar app that starts
with no visible result is a poor place to guess from.

The hook command points at the app bundle's binary by absolute path, so moving
the app disconnects every hook — silently, because the hook fails open and the
agent carries on exactly as before while vibeScroll goes blind. Each launch
checks where the installed hooks point and rewrites them if the binary they
name is gone. A path that still exists is left alone: that is a second copy the
hooks may be aimed at deliberately, and two installs rewriting each other on
every launch would be worse than the problem.

For an agent with no hook system, wrap it:

```bash
vibescroll run -- <your command>
```

## Sounds

Three alerts, set independently in Settings → General: one when an agent
finishes, one when it needs your input, one when you run out of quota. Each can
be silenced, set to any of the 14 sounds macOS ships, set to a sound bundled
with the app, or pointed at a file of your own. The defaults are all bundled and
distinct on purpose — Fart 1 when an agent finishes, Fart 3 when it needs input,
Fart 4 when quota runs out — so the three are tellable apart without looking.
They apply only until a sound is picked; a stored choice always wins.

vibeScroll plays these itself rather than attaching them to the notification.
That means they are heard even with notifications turned off, and the app owns
the choice — but it also means they ignore Focus. The notification banners are
sent deliberately silent so nothing is ever announced twice.

Four sounds are bundled, cut from one CC0 recording on Wikimedia Commons (see
[NOTICE.md](NOTICE.md)). `build-app.sh` copies them into the bundle, where
`NSSound(named:)` finds them alongside the system set — the same call resolves
both, which is the whole integration.

CC0 specifically, not merely "free": on Freesound and Commons alike the licence
varies per file, and trimming one changes nothing about it — a third of a second
of a CC BY-SA recording is still CC BY-SA, still share-alike, still a question
to answer about an asset compiled into an application. Filtering by licence
first is what avoids that; editing afterwards is not.
`scripts/make-sounds.py` records the source, the licence and the exact windows
kept, so the assets can be rebuilt rather than merely trusted.

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

## Task queue

A rate-limit window that expires unused is gone. Settings → Tasks holds a list
of prompts to spend one on.

Each task runs in its own git worktree under `~/.vibescroll/worktrees/`, on a
`vibescroll/<slug>` branch cut from the project's HEAD. A worktree *is* a
branch, so nothing is given up: `git log`, `git diff main..vibescroll/<slug>`
and `cherry-pick` all work from the main repository. What is gained is that the
branch somebody left checked out is never touched — which matters because a
task can still be running when they come back. A clean run is committed; a
failed one is left as it fell, where the working tree shows how far it got.
Nothing is ever pushed or merged.

Deleting a task removes its checkout and its log, and the cleanup runs on git's
own terms rather than on invented rules. `git worktree remove` without
`--force` refuses a checkout holding uncommitted changes, so a failed run
cannot be swept away by accident — the row turns into an explicit *Delete
anyway*. `git branch -d` (never `-D`) refuses a branch holding unmerged
commits, so a finished task's work survives while the empty branch left by a
task that changed nothing is cleared. The bulk *Clean up finished* button never
forces: it reports what it kept back and why.

Two windows are spent for opposite reasons, so `TaskRunway` gates them
differently:

| Window | Why | Gate |
| --- | --- | --- |
| Session (5h) | Expires whether or not it was spent, so filling it is the point | A ceiling only, high enough to avoid walking into a rate limit |
| Weekly | The scarce one; filling every session window exhausts it by midweek | Pace — usage against how far through the week we are — plus a reserve held back until the remainder would expire anyway |

The pace rule is the whole idea. At 85% spent with 67% of the week gone, the
queue holds: that spending is running ahead of the clock and comes out of days
still to be worked. At 88% with three hours left, it runs: that quota is about
to expire regardless.

Only Claude Code has a verified headless invocation, so it is the only agent a
task launches today; `AgentLaunch` returns `nil` for the rest rather than
guessing at an invocation and spending a window on it. The isolation is plain
git, so nothing about it is Claude-specific.

**Not automatic yet.** Tasks run when you press *Run now*. The gate above is
computed and displayed but nothing acts on it — the mechanism is worth proving
with a person pressing the button before it is trusted to start work at 03:00.

## The face

A small face lives in its own window on the desktop, and the card panel hangs
off it when there is a card. Two windows because the two have opposite
lifetimes: the face is continuous and the card is occasional. Sharing one meant
the card's size dictated the face's, and dismissing either had to argue about
the other.

The face grows while the pointer is over it, and shows a session-count badge
there. The *window* never resizes — only the blob inside it does. Resizing the
window is the obvious approach and it flickers: shrinking moves the frame out
from under the pointer, which ends the hover, which grows it again. Holding the
frame at the larger size means the hover target only ever gains area, so there
is nothing to oscillate.

By default it stays out even when nothing is running, asleep — which is still
information: vibeScroll is up and no agent is. Settings turns that off, in
which case the face arrives with the first session and leaves with the last.

It is drawn on a circle of the system's own material rather than bare on the
wallpaper. The features are drawn in the accent colour; on a wallpaper near that
colour they would simply disappear, and the material handles light and dark for
free.

It exists because the card pool is finite and the signals worth showing are not.
Four things drive it, and none of them is visible anywhere else:

| Signal | Read from | What it does |
| --- | --- | --- |
| Agent state | `AgentState` | Sets the resting face. `waiting` is the most alert one — being noticed is the point of that state. |
| Weekly pace | `QuotaPace.overspend` | Spending ahead of the clock furrows the brow. 85% spent is alarming on Tuesday and fine on Sunday night, so the percentage alone is not the signal. |
| Thrash | `topicSince` | An agent circling one topic for forty minutes. Only `working` sessions count: a session parked in `waiting` has held its topic for as long as *you* took to answer. |
| Fatigue | `createdAt`, `TranscriptAPIError` | Session length and recent rate limits, whichever is worse. Three limits in an hour shows immediately rather than waiting for the clock. |

The expression is five numbers — brow angle, eye openness, mouth curve, strain,
energy — rather than a named mood. Named moods have to be resolved against each
other the moment two signals disagree, and every answer is arbitrary: a face
that is both tired and over budget is neither "tired" nor "worried". Numbers
add, so it lands between them, and the drawing interpolates instead of cutting.
Pressures accumulate freely and are clamped once at the end, so the order they
are applied in cannot matter.

An unmeasured budget is neutral, not alarmed. `TaskRunway` refuses to launch
without a quota reading because the risk there is spending unsupervised; here
the only risk is a wrong face, and looking worried about a budget nobody
measured would be a lie.

Everything is drawn with SwiftUI shapes — no sprite, no asset, no licence. That
is deliberate: AgentPet's pet gallery was left behind partly over exactly that
question.

The drawing follows small-icon rules rather than chasing realism, because the
face is about 50pt on screen and an eye is a few points across. No feature ends
in a point — every line has round caps and joins — lines never go below about
1.7pt, and there is one layer of ink with no outline or engraving. An earlier
version tapered brows and mouth to tips and gave the eyes almond corners; at
this size every one of those details fell below a pixel and came out as
jaggies. Strain only hints in colour: above half strain the accent colour
turns at most a quarter of the way round the hue wheel towards orange — a
violet — because each pressure already has a feature of its own and a face that
went fully orange read as an alarm. The turn is in OKLCH rather than RGB, where
a mix of two near-complements passes through grey. Blinking is skipped entirely under Reduce Motion rather than slowed,
the same call `TypewriterReveal` makes about its reveal.

The tongue — out when the agents are burning tokens fast — is not held still
either. How far out it is belongs to the mood; where the tip is belongs to
`TongueMotion`, which every few seconds picks a short gesture: creep to a
corner of the mouth and stay, work the tip side to side, or draw it in and push
it back out. Each is under a second and then it holds, because any animation
over the face re-blurs the orb behind it for as long as it runs — the blink's
trade, made again. It comes out over the lower lip from under the upper one,
rather than sitting inside the mouth as a pink patch.

`vibescroll face` opens a window for tuning it: sliders for the five numbers,
and ten scenarios that run real input through the real pipeline, so what appears
there is what the desktop would show.

## Content

Cards are authored and served by [vibeScroll-backend](../vibeScroll-backend);
its README covers the card format and the validator.

What matters on this side is the contract:

- The client fetches `/v1/catalog` once at launch and every six hours, sending
  `If-None-Match` so an unchanged catalogue costs a 304 instead of a download.
- The request carries `Accept-Language` for the device's language (see
  *Languages*), and each language is cached to its own
  `~/.vibescroll/cache/catalog-<lang>.json`, so the app keeps showing cards
  with the backend unreachable. A failed refresh is silent by design —
  yesterday's cards beat an empty surface.
- A deployed backend can require a signed request. `ClientSignature` adds an
  HMAC over `<timestamp>\n<path>` when the build carries a secret, and sends
  nothing when it does not — so an unconfigured app and an unconfigured server
  work together out of the box. Set one with
  `python3 scripts/make-secret.py <secret>`, and the same value in the
  backend's `VIBESCROLL_SECRETS`.

  This is a turnstile, not a lock: the secret ships inside a downloadable app,
  so anyone willing to run `strings` on the binary has it. It keeps the endpoint
  uninteresting to scrapers and labels every request with a client version. The
  cards are public content; there is nothing here worth pretending otherwise
  about. A 401 is the one refresh failure reported by name rather than
  swallowed, because it is the only one that will never resolve itself.
- `CardCategory` is the shared content vocabulary. Adding a category means
  adding it there **and** in the backend's `CATEGORIES`. Server-first is safe:
  an older client skips a card whose category it does not know rather than
  failing the decode, so the app never has to ship in lockstep with content.
- `TopicCategory` is *not* shared. It is what an agent is doing — reading,
  testing, version control — and it only decides when a card may appear. It
  never reaches the backend, so the catalogue can be about anything.

## Languages

English and Turkish, for both the interface and the cards, chosen by the Mac:
System Settings → Language & Region, including the per-app override there.
There is no language setting in vibeScroll — one would only be a second place
for the two to disagree.

- **Cards.** `ContentLanguage.resolve` takes the first supported language from
  `Locale.preferredLanguages` — the same list AppKit picks the interface's
  `.lproj` from — and `ContentStore` sends it as `Accept-Language`. The server
  answers in that language and says so; the answer is cached under the language
  the server *actually* used, so a backend without Turkish yet cannot leave an
  English catalogue filed as Turkish.
- **Interface.** `Resources/Localization/Localizable.xcstrings` is a standard
  String Catalog, editable in Xcode. Nobody maintains its keys by hand: the
  compiler finds every `String(localized:)` and SwiftUI literal, interpolations
  included, and `xcstringstool` merges them in.

  ```bash
  ./scripts/sync-strings.sh     # after changing any user-facing text
  python3 scripts/check-strings.py
  ```

  The check fails on an untranslated string and on a translation whose format
  specifiers do not match the source — a `%@` where the code passes a number
  reads garbage at runtime. `build-app.sh` compiles the catalogue into
  `en.lproj` / `tr.lproj`; without Xcode's `xcstringstool` it still builds, in
  English.

A few things are deliberately left alone: show titles (proper nouns, shipped
under the same name in both languages — except Money Heist, which Turkey knows
as La Casa de Papel, and Muhteşem Yüzyıl, which abroad is Magnificent Century), agent and brand names, the
`vibescroll face` developer window, CLI usage text, task logs, and the
instructions appended to queued prompts — those are read by a model, not a
person.

A string that reads the same in English but not in Turkish gets its own key.
Topic names are `topic.*` for that reason: "Testing" is a noun on a topic
("Test") and a verb in the activity line ("Test ediliyor").

## Tuning what you see

Settings → General has three pacing presets. They set four coupled numbers that
only make sense together:

| Preset | Dwell | Global gap | Same-activity gap |
| --- | --- | --- | --- |
| Calm | 15s | 5 min | 1 hr |
| Normal | 8s | 90s | 15 min |
| Eager | 4s | 30s | 5 min |

*Dwell* is how long an agent must stay on one kind of work before it counts —
it is what stops the card strobing while an agent fires tool calls several
times a second. The same-activity gap belongs to the work, not the show: an
hour of debugging is one card per gap, whichever show it came from.

A card stays until you dismiss it with the **×**. The **›** button appears once
the text has finished writing, and advances to
the next one: unseen material in the current show first, then other shows,
and once you have seen everything it cycles the oldest card rather than going
inert. The show badge in the card's header opens a picker for jumping to a
show directly. Browsing suppresses automatic cards until you dismiss — pressing Next
means you are reading, and the surface should not replace itself under you.
Cards you browse to count as seen, so they will not resurface on their own.

What has been read survives a relaunch: when each card was last shown is kept
in the user defaults (pruned after 90 days), so quitting and reopening carries
on through the catalogue instead of opening on the card you read ten minutes
ago. Among cards not yet seen, the show seen longest ago goes next, so shows
alternate; within a show the order is shuffled once per install — stable, but
not alphabetical.

Card text is revealed character by character, locally — there is no streaming
involved, just a timed reveal. Click the card to skip to the end, and the effect
is disabled entirely when the system asks for reduced motion.

The panel is as tall as the card's text, between 120pt and 200pt. It is sized
once, when the card arrives, by laying the card's own view out off screen with
the finished text (`CardMeasure`) — so it never grows while the text is still
writing, and the measurement cannot drift from what is drawn. A fixed 200pt
used to leave the average card about a quarter empty.

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

For the editors, the click opens the session's *workspace* — the folder it
started in, recovered from where Claude Code files the transcript — rather than
the agent's current directory, which wanders the moment it `cd`s into a
subfolder. The link also carries `windowId=_blank`. Without it, an editor
handed a folder no window has open loads it into the last active window,
reloading that window and closing whatever agent session was running there; a
click meant to find one session could end another. With it, an open folder is
still simply focused, and anything else gets a window of its own.

Token counts come from the agent's own transcript and are read incrementally
from a stored byte offset, so repeated scans never double-count. Only Claude
Code and Codex write a transcript we can read; the other ten agents show no
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

## Not built yet

Tracked here so the absences are choices on record rather than things nobody
noticed. Roughly in the order they are worth doing:

| Gap | Why it matters |
| --- | --- |
| **Agent icons in the session list** | Rows read as text labels today. Brand marks would make a six-session list scannable at a glance. |
| **Session history** | `prune` deletes a session ten minutes after it goes idle. Nothing about what you worked on survives a restart, and it cannot be backfilled — the data you do not record today is gone. |
| **Per-project usage totals** | Tokens are counted per session and then discarded. Rolled up per project and per day they would answer "where did this week go", which nothing else can. |
| **Auto-update** | Deferred on purpose: it needs a distribution story first — Developer ID signing, notarization and somewhere to host an appcast. Premature before there is anything to update from. |
| **More languages** | English and Turkish today. A language is three lists — `ContentLanguage`, the backend's `LANGUAGES`, `CFBundleLocalizations` — plus its translations. |

Deliberately **not** planned:

- **The approval gate.** AgentPet can hold a `PreToolUse` hook's socket open and
  block the tool call until you allow or deny it from the UI. It is clever, and
  it puts this app on the critical path of every gated tool call — a bug there
  stalls your agent. A monitoring tool should not be able to do that.
- **Cloud sync, leaderboards, the tamagotchi economy, the pet gallery.** Out of
  scope, and the gallery's art carries licence questions this project has no
  reason to inherit.

## Attribution

The event pipeline is derived from [AgentPet](https://github.com/ntd4996/agentpet)
(MIT). See [NOTICE.md](NOTICE.md) for exactly what was taken, what is new, and
what was deliberately left behind.
