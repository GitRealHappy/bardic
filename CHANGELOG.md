# Changelog

## 0.2.1

- Pressing Retry while still offline no longer deletes a speech or cleanup model that had finished
  downloading.

## 0.2.0

The first public release.

- **App icon** and an **About** tab (Settings › About) with the version, links and acknowledgements.
- **Copy debug info** (Settings › About) gathers what's needed for a bug report: versions, Mac model,
  model status and recent log lines. No dictated text is included.
- **Update check.** The menu shows "Bardic x.y.z is available" when a new release is out. It asks GitHub
  at launch and once a day; switch it off in Settings › General.
- **Sturdier first run:**
  - The speech model download shows a percentage.
  - A failed download offers **Retry** in the menu and the setup window.
  - Disk space is checked before downloading.
  - A half-finished or damaged download is detected and fetched again.
- If the AI cleanup model can't load, dictation keeps working and pastes the raw transcript.
- The disk image includes a "Read Me First" file with install steps.

## 0.1.0

Personal build, shared by hand.

- Push-to-talk dictation: WhisperKit (Whisper large-v3 turbo), cleaned up by Qwen 2.5 3B on MLX, then
  pasted at the cursor.
- Hands-free mode, Esc to cancel, and a menu-bar key picker (Right Option, Right Command, Right
  Control or Fn).
- Tone adapts to the app in front. There's also a personal dictionary and a local history.
- First-run setup window, and a live recording pill with level bars and a "Can't hear you" warning.
- Renamed from Whiskr Flow to Bardic.
