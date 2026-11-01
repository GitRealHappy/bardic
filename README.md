# Bardic

Local, private AI voice dictation for macOS. Hold a key, talk, and polished text appears wherever your
cursor is. Fillers are removed, self-corrections are applied ("Tuesday, no wait, Wednesday" becomes
"Wednesday"), and punctuation, lists, emails and times are formatted. Everything runs on your Mac: no
account, no cloud, and it works offline after the first model download.

```
hold ⌥ (right) ─► mic (AVAudioEngine, 16 kHz mono)
             ─► WhisperKit  (Core ML / Neural Engine)   raw transcript
             ─► Qwen 2.5 3B (MLX / GPU, 4-bit)           cleaned text, tone matched to the app
             ─► paste at cursor (clipboard restored afterwards)
```

## Requirements

- Apple Silicon Mac (M1 or later). Developed on an M1 Pro with 16 GB.
- macOS 14 or later.
- About 3 GB of free disk space for the models.
- To build: Xcode 16.3 or later. Command Line Tools alone are not enough, because MLX's Metal shaders
  need `xcodebuild`. The scripts point at `/Applications/Xcode.app` via `DEVELOPER_DIR`, so you don't
  need to run `xcode-select`.

## Build & install

```sh
scripts/build-app.sh --open      # build, sign, install to ~/Applications/Bardic.app, launch
scripts/build-app.sh --no-install   # build and sign only; output is build/Bardic.app
scripts/build-app.sh --no-install --dmg       # also package build/Bardic-<version>.dmg
scripts/build-app.sh --no-install --notarize  # DMG + Apple notarization (needs Developer ID, see below)
```

The script does the following:
1. Builds with `xcodebuild`.
2. Assembles the `.app`, including the resource bundles. `mlx-swift_Cmlx.bundle` contains the Metal
   shader library.
3. Writes `Info.plist`.
4. Signs the app with the hardened runtime and `scripts/Bardic.entitlements` (microphone access).
   It uses a "Developer ID Application" identity if your keychain has one, otherwise the first "Apple
   Development" identity, otherwise ad-hoc. Override this with `SIGN_IDENTITY="…"`. `BUNDLE_ID` and
   `VERSION` can be overridden the same way.
5. Installs the app to `~/Applications`.
6. With `--dmg`, packages the app as a drag-to-Applications disk image. With `--notarize`, it also submits
   the DMG to Apple with `notarytool` and staples the ticket. Notarization needs a Developer ID
   certificate and a stored keychain profile; create the profile once with
   `xcrun notarytool store-credentials bardic-notary --apple-id <email> --team-id <team>`.

macOS permissions (TCC) are kept across rebuilds only while the bundle ID (`com.jesseboyes.bardic`),
signing identity and install path stay the same. With ad-hoc signing, you must re-grant permissions
after every build.

### First launch

A setup window walks through the steps below. Reopen it any time with the **?** button in the menu bar
dropdown. If both permissions are already granted, for example after an upgrade, it doesn't appear.

1. Allow **Microphone**.
2. Allow **Accessibility** under System Settings › Privacy & Security › Accessibility. It's needed for the
   global hotkey and for pasting. The app picks up the change within about 2 seconds, with no relaunch.
3. Pick the dictation key and try it out in the setup window.
4. Wait for the models. The setup window and the menu bar icon show progress.
   - The first run downloads about 630 MB of Whisper and about 1.8 GB of Qwen from Hugging Face.
   - Core ML then compiles Whisper for the Neural Engine. This happens once and can take several
     minutes.
   - Later launches load from disk in about 15 s and need no network.

## Using it

| Action | How |
|---|---|
| Dictate | Hold **Right Option**, speak, release |
| Hands-free | Double-tap Right Option, speak, tap once more to finish |
| Cancel | **Esc**, or press any other key while holding (it was a shortcut) |
| Start/stop without the key | Menu bar icon › Start dictation |
| Re-copy a past dictation | Menu bar icon › Recent (click to copy), or Settings › History |
| Change the dictation key | Menu bar icon › Push-to-talk key, or Settings › General |
| Change models, language | Menu bar icon › Settings |
| Setup guide | Menu bar icon › **?** |
| Names & jargon | Settings › Dictionary. This biases both Whisper and the LLM. |

**While you're recording**, the pill at the bottom of the screen shows:
- a running timer
- level bars that follow your voice
- an orange **"Can't hear you"** if no voice has been picked up for 2.5 s

If a recording turns out to be silent, or Whisper finds no words, the pill says **"Didn't catch that"**
instead of disappearing. Raising the input level under System Settings › Sound › Input helps quiet
voices.

The trigger key can be Right Option, Right Command, Right Control, or Fn/Globe. The change applies
immediately. If you choose Fn, set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing".

The app watches only the right-hand key, so holding the left Option or Command key for shortcuts never
starts dictation. Left-side keys are deliberately not offered, because every ⌘C would briefly turn on the
mic.

**Voice commands:**
- Formatting: "new line", "new paragraph", "bullet point"
- Punctuation: "comma", "period", "question mark", "colon", "open quote"/"close quote"
- Corrections: "no wait…", "actually…", "scratch that"

**Tone by app.** Tone adapts to the app in front:
- Slack, Messages, Discord, WhatsApp and Teams get a casual tone.
- Mail, Outlook, Word and Pages get a formal tone.
- Xcode, VS Code, Cursor, Zed, JetBrains IDEs and terminals keep commands and identifiers literal.

The mapping is in `DictationStyle.forBundleID` in `Sources/BardicCore/CleanupPrompt.swift`.

**Safety net.** If the model output looks like it answered or expanded what you said, the raw Whisper
transcript is pasted instead. For example, it won't answer "what's the capital of France". The check is
in `CleanupPrompt.validate`.

## Performance (M1 Pro, 16 GB)

For a 7 s utterance, release-to-text takes about 1.65 s:
- Whisper large-v3 turbo: about 1.2 s
- Cleanup: 0.25–0.5 s

**Why cleanup is fast.** The system prompt and few-shot examples make a fixed prefix of about 700 tokens.
Its KV cache is prefilled once at load. Each dictation copies that cache and processes only its own short
suffix (see `Cleaner.buildPrefixCache`).

- Per-request inputs (app style, dictionary) go in the final user turn. **Anything you add to the system
  prompt or examples must stay request-independent, or the cache stops matching.**
- When the cache doesn't match, generation falls back to full prefill, which takes about 1.5 s per call.

**Whisper is now the bottleneck.** "Whisper Small, English" in Settings trades accuracy for speed.

The app uses roughly 1.8 GB of memory once both models are loaded.

## CLI: testing the pipeline

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme bardic-cli -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -skipMacroValidation -skipPackagePluginValidation build
CLI=build/DerivedData/Build/Products/Release/bardic-cli

$CLI eval                                   # cleanup fixtures: pass/fail + latency (currently 10/10)
$CLI clean "um so send it tuesday no wait wednesday" casual   # styles: standard|casual|formal|code
$CLI transcribe a.m4a b.wav                 # Whisper + cleanup on audio files, with speech level and timings
BARDIC_LLM=mlx-community/Qwen2.5-7B-Instruct-4bit $CLI eval   # try another cleanup model
BARDIC_NO_CACHE=1 $CLI eval                 # disable the prompt cache (A/B check)
```

Run `eval` after any prompt change. The fixtures are in `Sources/BardicCLI/main.swift`.

You can make a quick spoken test file with
`say -o test.aiff "Um, so let's meet Thursday, no wait, Friday."`.

## Code layout

- **`Sources/BardicCore`** is the pipeline, shared by the app and the CLI.
  - `AudioRecorder`: mic capture and conversion to 16 kHz mono. It also does the level maths for the
    meter, the "can't hear you" check and the silence gate.
  - `Transcriber`: WhisperKit. It loads from disk when the model is present, so it works offline.
  - `Cleaner`: the MLX LLM, with the prompt-prefix KV cache.
  - `CleanupPrompt`: the system prompt, few-shot examples, per-app styles, the output guard and the
    leading-filler stripper.
  - `Models`: model choices and paths.
- **`Sources/Bardic`** is the menu-bar app.
  - `AppState`: the dictation pipeline, settings and history.
  - `HotkeyManager`: hold, double-tap and cancel logic, using NSEvent global monitors.
  - `TextInserter`: pastes the text, then restores the clipboard.
  - `HUD`: the floating pill, with the timer, level bars, "can't hear you" warning and notices.
  - `Onboarding`: the first-run setup window.
  - `BardicApp`: the menu.
  - `SettingsView`
  - `Permissions`
- **`Sources/BardicCLI`** is the test harness and fixtures.
- **`scripts/build-app.sh`** builds, bundles, signs and installs.

## Where data lives

| What | Path |
|---|---|
| Whisper models | `~/Library/Application Support/Bardic/SpeechModels` |
| LLM models | `~/Library/Caches/models/mlx-community/…` |
| History (local only, clearable in Settings) | `~/Library/Application Support/Bardic/history.json` |
| Settings | `defaults read com.jesseboyes.bardic` |

## Troubleshooting

- **See what the app is doing:** run
  `/usr/bin/log stream --predicate 'subsystem == "com.jesseboyes.bardic"'`. Every phase change is
  logged, for example `phase: idle`. In zsh, use `/usr/bin/log` because `log` is a shell builtin.
- **Hotkey does nothing:** Accessibility isn't granted, or the grant belongs to an older signature.
  Remove Bardic from the Accessibility list and add it again. To reset it from the terminal, run
  `tccutil reset Accessibility com.jesseboyes.bardic`.
- **The pill says "Can't hear you" or "Didn't catch that":** the mic level is very low. Raise it under
  System Settings › Sound › Input. Video-call sites and apps sometimes turn it down. The log line for
  each dictation shows its levels, for example `dictation: 5.8s, speech -44 dBFS, …`. Speech below about
  -58 dBFS is treated as silence. To keep the last 20 recordings for inspection, run
  `defaults write com.jesseboyes.bardic debugSaveAudio -bool YES`. They're saved in
  `~/Library/Application Support/Bardic/DebugAudio`.
- **The orange mic dot flashes when I use Option shortcuts:** this is expected. Pressing the trigger key
  starts the mic, and a quick tap cancels it.
- **Changed models or turned AI cleanup on, but nothing happened:** press Settings › Models ›
  "Apply & reload models".
- **The first launch seems stuck on "Loading speech model":** the one-time Neural Engine compile is
  running. Give it a few minutes.

## Upgrading from Whiskr Flow

The app used to be called Whiskr Flow, with the bundle ID `com.jesseboyes.whiskrflow`. On first launch,
Bardic does the following:
- It moves `~/Library/Application Support/WhiskrFlow`, which holds the Whisper models and history, to
  `…/Bardic`, so nothing is downloaded again.
- It copies your settings, including the key, the models and the dictionary.

`scripts/build-app.sh` removes the old `~/Applications/Whiskr Flow.app`.

macOS treats Bardic as a new app, so you need to:
- Grant Microphone and Accessibility again. The setup window walks you through it.
- Re-enable "Launch at login" if you used it.

To clear the old app's leftover permission entries and settings, run:
`tccutil reset All com.jesseboyes.whiskrflow; defaults delete com.jesseboyes.whiskrflow`.

## Uninstall

```sh
rm -rf ~/Applications/"Bardic.app" ~/Library/Application\ Support/Bardic \
       ~/Library/Caches/models/mlx-community/Qwen2.5-3B-Instruct-4bit
defaults delete com.jesseboyes.bardic
tccutil reset All com.jesseboyes.bardic
```

## Version pins

`Package.swift` pins these versions:
- mlx-swift 0.31.4
- mlx-swift-lm 2.31.3
- WhisperKit 1.1.1

These are the newest versions that build with Swift 6.1 (Xcode 16.3). Newer mlx-swift needs Swift 6.3,
and newer mlx-swift-lm needs 6.2. After upgrading Xcode, these can be bumped; the newer versions have
different loading APIs. The build shows a few Swift 6 sendability warnings in `Cleaner.swift`. They are
harmless in the Swift 5 language mode the package uses.

## Credits and licenses

- [Whisper](https://github.com/openai/whisper) (OpenAI), MIT. It runs through
  [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Argmax), which is also MIT.
- [MLX Swift](https://github.com/ml-explore/mlx-swift) and mlx-swift-lm (Apple), MIT.
- Qwen 2.5 3B Instruct (Alibaba Cloud) is the default cleanup model. It is downloaded by the app from
  Hugging Face, not bundled. Qwen is licensed under the Qwen RESEARCH LICENSE AGREEMENT, Copyright (c)
  Alibaba Cloud. All Rights Reserved. **That license is non-commercial, so Bardic must stay free while
  it uses this model.**

## Status and road to sharing

This build works well on the author's Mac (M1 Pro). As of 2026-11-01 it has a menu-bar key picker,
first-run setup, live recording feedback, and DMG packaging.

**Decisions made**
- **Name:** Bardic (`com.jesseboyes.bardic`). Override it with `BUNDLE_ID` if you get your own domain.
- **Speech model:** stay with Whisper large-v3 turbo. Parakeet (via FluidAudio) was considered and set
  aside, because it would be extra complexity and an extra download.
- **Cleanup model:** keep Qwen 2.5 3B. It scores 10/10 on the eval, against 8/10 for the Apache-2.0
  1.5B model. Because of its license, the app stays free (see Credits).
- **Signing:** unsigned for now, with no paid Apple Developer Program.

**Sharing it today.** Run `scripts/build-app.sh --no-install --dmg` and send
`build/Bardic-<version>.dmg`. The app isn't notarized, so recipients need to:
1. Drag Bardic to Applications and open it. macOS will refuse the first time.
2. Go to System Settings › Privacy & Security, scroll down, click **Open Anyway** next to Bardic, and
   confirm.
3. Follow the setup window: Microphone, Accessibility, then wait for the roughly 2.5 GB model download.

They need an Apple Silicon Mac with macOS 14 or later. With each new version they repeat step 2, and
may have to switch Accessibility off and on again.

**To do**
- [ ] **GitHub.** Decide between a private or public repo, and pick a license for the code (for example
  MIT). A public repo's Releases page is an easy place to host the DMG.
- [ ] **Install notes for recipients.** Put the steps above on the release page or in a text file
  inside the DMG.
- [ ] **Distribution signing (optional, $99/yr).** The pipeline is ready: hardened runtime, the
  audio-input entitlement, `--dmg` and `--notarize`, and the full pipeline was verified under the
  hardened runtime. With a Developer ID certificate, recipients wouldn't need "Open Anyway" and would
  keep permissions across updates. `--notarize` has never been run.
- [ ] **Updates.** Either a simple "new version available" check against GitHub Releases, or Sparkle.
  Sparkle adds a dependency, and the build script doesn't copy `Contents/Frameworks` yet.
- [ ] **Hardware.** Macs with 8 GB or less already default to the 1.5B cleanup model. The binary is
  arm64-only, so Intel Macs can't open it; say "Apple Silicon only" wherever it's shared.
- [ ] **Quality.**
  - About 1 in 16 test dictations came back with no words, even though the audio wasn't silent. The
    app now says so instead of failing quietly. Watch whether it recurs.
  - A leading "So" without a comma can survive cleanup.
  - Add an eval fixture checking that questions stay questions.
  - Grow the fixtures with real usage.
- [ ] **Custom key combos**, for example ⌃⌥Space. This needs Carbon `RegisterEventHotKey` or a
  `CGEventTap`, because NSEvent monitors can't swallow the key.
- [ ] **Speed.** Whisper is about 70% of latency. Options are streaming transcription while the key is
  held, or "Whisper Small, English" in Settings.
- [x] Onboarding, menu-bar key picker, rename, live recording feedback, quiet-mic fix.
