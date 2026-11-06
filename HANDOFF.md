# Keystorm handoff (2026-10-21)

This is what is left to do. The full audit and plan are local-only on the owner's Mac: `NEXT-STEPS.md` and `Validation/Audit-2026-10-21/findings.json` (both excluded by `.git/info/exclude`). Item numbers below match `NEXT-STEPS.md`.

## Where things stand

- **Branch:** `phase-0-1-core-loop`, not merged into `main`.
- **Tests:** the full unit selection gave 1,394 passed, 0 failed, 3 opt-in skips. The UI tests were not run.
- **Not verified:** nobody has seen the new HUD on screen, and nothing has run with a real microphone, in a browser or in an Electron app.

### Done on this branch

| Item | What changed |
|---|---|
| 3 | `Keystorm/Keystorm.entitlements` with audio-input, set as `CODE_SIGN_ENTITLEMENTS` |
| 4 | `ARCHS = arm64`. App Sandbox stays off. |
| 6 | Transcription windows shed context to fit the 15 s cap. The worker trims resampling overshoot instead of throwing. |
| 9 | Finish copies the result to the clipboard when nothing was inserted. Preference `dictation.copyWhenNotInserted.v1`, on by default. |
| 11 | A second shortcut press during Starting finishes the take once recording begins. |
| 12 | HUD: Copy and Retry buttons, final text when ready, phase titles, Dismiss sticks, auto-hide after an insert. |
| 10 (half) | A failed Clean copies the raw text. It still inserts nothing. |

## What is left, in order

### Phase 0, still open
1. **Commit the docs** if they should be in git. `PLAN.md`, `NEXT-STEPS.md`, `VALIDATION.md`, `RELEASE.md`, `RESEARCH.md`, `docs/` and `Validation/` are excluded on purpose today.
2. **Accessibility grant** for `dev.mitternacht.Keystorm`. The owner does this; agents must not touch TCC.

### Phase 1: trust the core loop on a real Mac
5. **Real microphone run.** Try ten dictations each in TextEdit, Mail, Notes, Safari, Chrome, Slack and VS Code, and write down what happened. This is the biggest unknown. Browsers need the owner, because agents may not automate them.
7. **Recover from interruptions.** After a route change, sleep or stall, the take can never finish today. Keep the target, and let Resume and Finish work. Files: `WorkspaceModel.swift:822`, `DictationCoordinator.swift:918`.
8. **Stop failing on jitter.** A sample gap or 50 ms clock drift should start a new interval, not kill the take. File: `AudioCapture.swift:460-479`.
10. **Finish the Clean fallback.** When Clean fails, insert the raw text and say "cleanup failed". File: `DictationCoordinator.swift`, catch path of `finish()`.
13. **Salvage `<id>.partial.caf` after a crash.** Up to 5 s of speech is never read today. Files: `SessionStore.swift:570,633`.
14. **`CaptureSource` seam** in front of `AVAudioEngine`, so interruptions and watchdogs get unit tests. File: `AudioCapture.swift`.
- **HUD "Loading speech model…" title.** Skipped, because the coordinator cannot see model loading. It needs a backend signal from `WorkspaceModel`.

### Phase 2: speed
The targets are hotkey to listening under 300 ms and Finish to Clean under 1 s.

15. **Keep the inference worker warm** for 10 to 15 minutes, and unload only on memory pressure. Today it is killed 30 s after every job. Files: `WorkspaceModel.swift:1802`, `InferenceWorkerClient.swift:211`.
16. **Persist the model integrity hash**, keyed by inode, size and mtime. Every new worker re-hashes 3.6 GB today. File: `LocalInference.swift:869`.
17. **Cut durable saves around Start** from eight to two. File: `WorkspaceModel.swift:2848-2882`.
18. **Prewarm at the hotkey.** This needs a second work lane. Files: `WorkspaceModel.swift:990,2611`.
19. **Don't cancel prewarm on Finish.** Cancelling kills the worker. File: `WorkspaceModel.swift:2850`.
20. **Stop re-decoding the 12 s preview ring** every 500 ms. File: `WorkspaceModel.swift:1031`.
21. **Cache the prompt prefix and the grammar.** File: `LocalInference.swift:383`.
22. **Decide what Clean is for.** It returns ASR output unchanged and costs about 2 s. File: `DictationTransform.swift:217,446`.
23. **Measure in a Release build.** All numbers so far are from Debug.

### Phase 3: Mac utility polish
24. **Menu-bar app** (`LSUIElement`), with state shown in the menu-bar icon. File: `KeystormApp.swift:78,99`.
25. **Hold-to-talk for dictation.** The coordinator exists but only drives Brief takes. File: `GlobalHotkeys.swift:345`.
26. **Modifier-only and Fn shortcuts** through an `NSEvent` flags monitor. File: `GlobalHotkeys.swift:72`.
27. **Esc cancels a dictation.**
28. **Manual "Add word"** in the dictionary, with looser matching. Files: `LearningDictionaryView.swift:25`, `LearningRepository.swift:330,361`.
29. **Delete recordings, and a retention setting.** Nothing can be deleted today. File: `WorkspaceModel.swift:2153`.
30. **Undo the last insertion.** File: `DictationDelivery.swift:871`.
31. **Mic level meter in the HUD.** File: `LiveAudioBuffer.swift:87`.
32. **Mail and web editors.** The role allowlist drops them to Copy. File: `DictationDelivery.swift:238`.
33. **Resume and cancel model downloads.** File: `LocalInference.swift:94`.
34. **Check onboarding on screen.** Gate Done on readiness, add a practice field, and fix the stuck "Checking…" state. Files: `OnboardingView.swift`, `OnboardingProviders.swift:10`.
35. **Show `recoveryMessages`** in the UI. File: `WorkspaceModel.swift:252`.
36. **"No speech" is a quiet dismiss**, not a failure. File: `WorkspaceModel.swift:3075`.

### Phase 4: cut the legacy Brief
37. **Turn Brief hotkeys off by default**, and remove the Brief submenu from the menu bar. Files: `GlobalHotkeys.swift:143`, `KeystormSettings.swift:256`.
38. **Give dictation its own session type**, instead of saving every dictation as a Brief. File: `WorkspaceModel.swift:496`.
39. **Delete or quarantine the Brief code.** The dead code is in `ContentView.swift:5-333,603-740`. Also covered: `BriefWorkspaceView`, `BriefLibraryViews`, `NativeBriefEditor`, `BriefReadback`, `BriefProjectButton`, `PromptComposer`, `Evaluation.swift`.
40. **Split `WorkspaceModel.swift`** (3,357 lines), after item 38.
41. **Center Settings on dictation.** Drop the Read-back and telemetry tabs.

### Phase 5: ship (needs the owner)
42. **Developer ID certificate and notarytool profile.**
43. **Export, notarize, staple and DMG scripts** in `Release/`.
44. **Sparkle** for updates.
45. **Quarantined install on a second Mac**, then ten dictations.
46. **Pick a license.**

## Decisions only the owner can make

- What Clean should do (item 22).
- Whether Keystorm becomes a menu-bar app (item 24).
- How long to keep audio (item 29).
- Whether the Brief is deleted or only hidden (items 38 and 39).

## Gotchas

- **Xcode MCP `AddEntitlement` turned on App Sandbox** and created no file. Sandbox must stay off, because Accessibility insertion and Cmd-V posting break inside it. After any Xcode MCP project edit, check that `ENABLE_APP_SANDBOX = NO` is still in `project.pbxproj`.
- **A new bundle ID needs one Accessibility re-grant.** Stable signing (team `84PD63F63N`) keeps the grant across rebuilds.
- **Opt-in tests need environment variables.** Hardware, installed-model and desktop tests skip by default (`KEYSTORM_RUN_*`). The scheme's test action reuses the launch environment.
- **Test rigs use a private pasteboard** (`DictationCoordinator.pasteboard`), so tests never touch the user's clipboard. Keep it that way in new tests.
- **Keep agent runs small.** A 370-agent audit ran into the usage limit partway through; stay at about 10 to 20 agents.
