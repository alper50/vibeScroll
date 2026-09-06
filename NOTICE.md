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

`TopicCategory`, `CategoryResolver`, `InfoCard`, `CardScheduler`,
`ActivitySummary`, `ProjectPath`, `ContentStore`, `CardController`,
`CardWindowController`, `InfoCardView` and the entire `server/` backend.

## What was deliberately left behind

The pet sprite system, the pet gallery and its mirrored third-party art, the
tamagotchi XP economy, the public leaderboard and its sync API, and the
subscription-limit probe that reads provider OAuth tokens out of the Keychain.
