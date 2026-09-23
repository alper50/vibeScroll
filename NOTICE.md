# Attribution

vibeScroll's agent event pipeline is derived from
[AgentPet](https://github.com/ntd4996/agentpet) by Nguyễn Thành Đạt, used under
the MIT License. AgentPet solves the hard, unglamorous part of this problem —
normalising eleven different agents' hook formats into one event stream — and
that work is reused here rather than reinvented.

## What was taken

Adapted with only renaming and the removal of unused branches:

| File | Origin |
| --- | --- |
| `AgentState.swift`, `AgentCatalog.swift` | `AgentPetCore` |
| `AgentHooks.swift`, `HookInstaller.swift` | `AgentPetCore` |
| `StateMapper.swift` | `AgentPetCore` |
| `HookArguments.swift`, `RunArguments.swift` | `AgentPetCore` |
| `CodexHookConfig.swift` | `AgentPetCore` |
| `TranscriptReader.swift` | `AgentPetCore` |
| `QuestionDetector.swift` | `AgentPetCore` |
| `PerKeyThrottle.swift`, `TerminalInfo.swift` | `AgentPetCore` |
| `TickerFormatter.swift`, `ModelPricing.swift` | `AgentPetCore` |
| `EventCoding.swift`, `EventSender.swift`, `EventSocketServer.swift` | `AgentPetCore` |
| `SessionStore.swift` | `AgentPetCore` (approval gate and session archive removed) |
| `ClaudeHookPayload.swift`, `HookPayloads.swift`, `AntigravityHookPayload.swift` | `AgentPetCore` |
| `RunCLI.swift`, `HookCLI.swift`, `AppDaemon.swift` | `AgentPet` app target |

## What is new

Written for this project, with no AgentPet counterpart:

| Area | Files |
| --- | --- |
| Topic model | `TopicCategory`, `CategoryResolver`, `ActivitySummary` |
| Content | `CardCategory`, `InfoCard`, `ContentStore`, and the whole `vibeScroll-backend` repository |
| Languages | `ContentLanguage`, the string catalogue and `scripts/sync-strings.sh` / `check-strings.py` |
| Pacing and presentation | `CardScheduler`, `CardController`, `CardLayout`, `CardWindowController`, `InfoCardView` |
| Typewriter reveal | `TypewriterReveal`, `TypewriterModel` |
| Sounds | `SoundSelection`, `SoundSettings` |
| Quota | `QuotaSnapshot`, `ClaudeUsageParser`, `TranscriptAPIError`, `UsageProbe` |
| Window focus | `EditorLink`, `SessionFocus`, `ProjectPath` |
| Settings | `SettingsView`, `SettingsWindowController`, `HookSetup` |

Two of these started from AgentPet and diverged far enough to count as new
rather than adapted:

- **`SessionFocus`** began as `TerminalFocus`. It keeps the Terminal.app and
  iTerm2 AppleScript, and adds host identification via `__CFBundleIdentifier`
  plus editor URL schemes — the path that matters when an agent runs as an IDE
  extension, where AgentPet's `TERM_PROGRAM` and tty are both absent.
- **`UsageProbe`** began as `NativeUsageProbe`. AgentPet reads the older
  top-level `five_hour` / `seven_day` objects; the endpoint now returns a
  `limits` array carrying the provider's own `severity`, which this reads in
  preference, falling back to the old shape.

## Bundled assets

The four sounds in `Resources/Sounds/` are cut from
[Farting sound effects](https://commons.wikimedia.org/wiki/File:Farting_sound_effects.webm),
uploaded to Wikimedia Commons by *Atsme* under the **Creative Commons CC0 1.0
Universal Public Domain Dedication**. CC0 carries no attribution requirement; it
is recorded here because knowing where a binary in the repository came from is
worth more than the obligation.

Chosen over the CC BY-SA fart recordings on Commons deliberately: share-alike on
an asset compiled into an application raises a question better not raised, and
cutting a clip out of one would not have changed its licence. The four windows,
fades and normalisation are reproducible via `scripts/make-sounds.py`.

## What was deliberately left behind

**Not wanted:** the pet sprite system, the pet gallery and its mirrored
third-party art, the tamagotchi XP economy, the public leaderboard and its sync
API, break reminders, and the in-app pet browser.

**Rejected on risk:** the approval gate (`ApprovalGateConfig`,
`PendingApprovalRegistry`). It parks a `PreToolUse` hook's open socket until the
user decides, which puts this app on the critical path of every gated tool call.

**Not yet, but tracked** in the README's "Not built yet" table: launch at login,
session history (`SessionArchive`, `SessionArchiveStore`), per-project usage
totals (`ProjectUsageStore`), auto-update (`UpdaterController` and Sparkle),
agent icons (`AgentIcons`), and localization (`AppLanguage`).
