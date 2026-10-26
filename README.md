# AudioRecord — local meeting recorder + transcriber for macOS

Menu-bar app that records everything you hear and say during a meeting (Zoom, Meet, Teams,
Webex, any app), then turns it into a speaker-labelled Markdown transcript. Nothing leaves
the Mac: capture, speech-to-text, speaker separation and name resolution all run locally.

## Requirements

- macOS 15+ (built and tested on macOS 27, Apple Silicon). Apple Speech engine needs macOS 26+.
- Swift toolchain from the Command Line Tools (no Xcode.app required).
- Optional: LM Studio (or any OpenAI-compatible server on localhost) for resolving real names.

## Build and install

```sh
git clone https://github.com/espa77/audio-record.git && cd audio-record
scripts/build-app.sh            # → dist/AudioRecord.app
scripts/build-app.sh --install  # also replaces /Applications/AudioRecord.app
swift build -c release          # CLI: .build/release/audiorecord
swift run -c release audiorecord-selftest   # unit checks (CLT has no XCTest)
```

First transcription downloads the models (~1.1 GB incl. the vocabulary spotter) into
`~/Library/Application Support/FluidAudio/Models/`.

## Use

1. Click the waveform icon in the menu bar → **Start Recording**. First time: allow
   Microphone and "System Audio Recording Only" (Privacy & Security → Screen & System Audio Recording).
2. **Stop Recording** → `~/Recordings/Meetings/YYYY-MM-DD_HH-MM-SS.m4a` (stereo: L = you, R = everyone else).
3. The popup asks "Transcribe now?". Yes → `YYYY-MM-DD_HH-MM-SS_meeting/` with the audio and
   `YYYY-MM-DD_HH-MM-SS.md`. Later → the file stays in the folder; **Transcribe Recording** lists it.

CLI: `audiorecord transcribe <file> [--engine parakeet|apple] [--no-llm] [--no-vocab] [--vocab <file>]`,
`audiorecord bench <file>`, `audiorecord record --seconds 30`, `audiorecord models`, `audiorecord settings`.

## How it works

| Step | Component |
|---|---|
| System audio (all apps) | Core Audio process tap → private aggregate device (`Capture/SystemAudioTap.swift`) |
| Microphone | AVAudioEngine input tap (`Capture/MicCapture.swift`) |
| Storage | lossless CAF tracks while recording → AAC M4A on stop (`Capture/AudioMixdown.swift`) |
| Stall recovery | a source silent for 4 s is restarted; the hole is padded so tracks stay aligned (`Capture/RecordingSession.swift`) |
| Speech-to-text | FluidAudio Parakeet Ultra (Core ML), or Apple SpeechAnalyzer (`Transcribe/ASREngine.swift`) |
| Who spoke when | FluidAudio offline diarizer, pyannote community-1 pipeline, on the system track only |
| Domain terms | FluidAudio CTC keyword spotter proposes, our gate applies (`Transcribe/Vocabulary.swift`) |
| Names | local LLM via OpenAI-compatible endpoint + self-introduction patterns (`Transcribe/NameResolver.swift`) |
| Output | Markdown with per-turn speaker + timestamp and a speaker map (`Transcribe/MarkdownWriter.swift`) |

Your own voice is always attributed to the configured name because it comes from the mic track;
other participants get `SPEAKER_nn` from diarization, renamed to real names only when the
conversation states them (the name must literally occur in the transcript), else `person_N`.

## Domain vocabulary (`Resources/vocabulary.txt`)

A plain-text term list that travels with the repo and is bundled into the app, so every
installation corrects the same terms. It ships with psychiatric medications (generic and brand),
diagnoses, symptoms, scales and therapies. Edit it, then `scripts/build-app.sh --install`.

- A **single word** (`sertraline`) is corrected when Parakeet mishears it: a separate CTC model
  scores the term against the audio and the correction is applied only when that score is ≥ 1.5
  (spoken terms score 1.8–7; look-alike ordinary words score below the gate).
- A **phrase** or **ACRONYM** is a hint for the Apple engine only, plus spelling of an exact
  hearing (`PHQ9` → `PHQ-9`). Put rare words of a phrase on their own line to get corrections.
- Do not list ordinary words: they only cause wrong replacements of similar-sounding words.

Every transcript footer lists the terms that were applied. Tuning: `AUDIORECORD_VOCAB_DEBUG=1`
prints each proposal with its scores; `AUDIORECORD_VOCAB_MIN_SCORE=2` raises the gate. Two
listed drugs that share most of their sound (citalopram / escitalopram) can still be confused.

## Settings (menu → Settings…)

Recordings folder, your name, engine, LLM endpoint/model (blank model = first one the server
lists), keep lossless tracks, boost domain vocabulary. Stored in the `com.esteiner.audiorecord` defaults suite (shared with the CLI).

## Licenses of bundled components

FluidAudio (Apache-2.0) and its models (MIT/Apache-2.0 per model card); tap code pattern after
AudioCap (BSD-2-Clause) and AudioTee (MIT).
