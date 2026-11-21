# CleanVoice

> **Public mirror.** A sanitised copy of a private working repo, updated by a one-way sync. Fork it and experiment freely. Issues and pull requests are welcome: accepted changes are folded into the private repo by hand and reappear here on the next sync. MIT licensed; the bundled RNNoise and DNSMOS models keep their own licences.
>
> The app looks for the engine at `~/Tools/cleanvoice/engine`, so clone this repo to `~/Tools/cleanvoice` (or change the path in `app/Sources/CleanVoice/Settings.swift`), run `cd engine && uv sync`, then `app/build-app.sh`.

Removes hum, rumble and background noise from film dialogue, lets you compare and fine-tune, then exports everything into simple folders for DaVinci Resolve. Runs entirely on this Mac. No tokens are used unless you type into the optional "Ask Claude" box.

**Clean source clips, not a finished mix.** The speech models remove anything that isn't voice, including music, footsteps and doors. Your originals are never modified.

## Using the app

Open **CleanVoice** from `~/Applications` (or Spotlight).

1. **Add clips.** Drag a folder in, or press ⌘O. Subfolders are included. Each clip is cleaned automatically: Auto tries every model and keeps the best-scoring one.
2. **Review.**
   - The video plays with the cleaned sound.
   - Press **A** to flip between Original and Cleaned. "Match loudness" keeps the comparison fair.
   - **↑ / ↓** move between clips. **Space** plays and pauses.
   - Adjust with Strength (Gentle, Balanced or Maximum), Clarity and Loudness. **Advanced** has the model, hum, low cut, warmth and evenness controls.
   - "All clips / This clip only" decides whether a change affects the whole project or one clip.
3. **Export for DaVinci** (⌘E). By default you get:
   ```
   <your folder>/Cleaned for DaVinci/Video/...   same names, same timecode, clean audio
   <your folder>/Cleaned for DaVinci/Audio/...   24-bit WAVs
   ```
   - **New edit:** drag the Video folder into the Media Pool.
   - **Existing edit:** select the clips in the Media Pool, right-click › **Change Source Folder…**, and point it at the Video folder.
   - Re-exporting replaces CleanVoice's own earlier exports, so you never get duplicates. MOV files get uncompressed 24-bit audio; MP4 files get AAC 320k.

Settings are remembered per folder (in `~/Library/Application Support/CleanVoice`). Use **Advanced › Defaults** to save your own starting settings.

## Cleaning models

| Model | Character |
|---|---|
| Auto (default) | Runs all of the models below, scores each with Microsoft DNSMOS, keeps the best. Clips over 60 s are scored on a 45 s speech sample. |
| DeepFilterNet 3 | Strongest AI speech enhancement (48 kHz) |
| DeepFilterNet 2 | Alternative AI model, often slightly cleaner on heavy noise |
| RNNoise | Light AI model |
| Spectral | Classic noise reduction: most natural, keeps non-voice sounds, removes less |

## Ask Claude (optional)

Describe what you hear ("muffled", "robotic", "too much room") and Claude moves the sliders. You can undo the change. It uses your Claude subscription through Claude Code, at about 1-2k tokens per request (Haiku by default). One-time setup in Terminal:

```
curl -fsSL https://claude.ai/install.sh | bash
claude        # sign in once, then quit
```

## Terminal use (no app)

```
~/Tools/cleanvoice/engine/.venv/bin/python ~/Tools/cleanvoice/engine/cleanvoice.py process "<folder>" [options]
```

Options: `--model auto|deepfilternet3|deepfilternet2|rnnoise|spectral`, `--noise-reduction 28`, `--full`, `--hum auto|50|60|off`, `--low-cut 80`, `--clarity 2`, `--warmth -2`, `--evenness 0.5`, `--loudness -24|off`, `--flat`, `--suffix`, `--no-wav-stem`, `--out DIR`, `--json`.

## Rebuilding

- **App:** `app/build-app.sh` builds and reinstalls it. Only the Command Line Tools are needed, not Xcode.
- **Engine environment:** `cd engine && uv sync`.
- **Self-test:** `open -n -a ~/Applications/CleanVoice.app --args --selftest <folder> <report-dir>`. It loads the folder, plays clips, flips A/B, moves settings and exports. It writes `report.json` and screenshots to the report directory.

## Files

- `engine/cleanvoice.py`: all audio processing. It runs as a background worker for the app and as the CLI.
- `engine/models/`: the RNNoise model and the DNSMOS scorer. The DeepFilterNet weights are in `~/Library/Caches/DeepFilterNet`.
- `app/`: the SwiftUI app source.
- `samples/`: deliberately bad test clips and the listening test.
