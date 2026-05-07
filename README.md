# Speakword — TTS for KOReader

Pronounce selected words and sentences in [KOReader](https://koreader.rocks/).
Two providers ship in the box:

- **Android System TTS** (default — on-device, free, offline) — uses whichever
  TTS engine the device has installed (typically Speech Services by Google).
  No signup, no API key, no network round-trip, no per-call cost. The voice
  picker only shows voices with offline data already downloaded, so picking
  one always works. **Recommended for most users.**
- **ElevenLabs** (cloud, paid free tier) — **noticeably higher quality** than
  Android TTS, with neural-network voices that sound far more natural and
  expressive. Recommended if you want premium pronunciation for language
  learning. Requires an API key (10K credits/month free) and an internet
  connection.

You can switch between providers at runtime via Tools → Speakword TTS →
**Provider**. The architecture makes it straightforward to add Google Cloud
TTS, Azure, AWS Polly, etc. as additional providers.

## What it does

- Adds a **Speak** button to KOReader's dictionary popup, on its own row (so
  it doesn't collide with other plugins like `assistant.koplugin`).
- Adds a **Speak** button to the highlight dialog so phrases and full
  sentences can be spoken too.
- Caches synthesized audio per book, so re-tapping the same word never
  re-spends API credits. The cache lives next to the book file in
  `<book_dir>/<book_filename_without_extension>/`, the same convention
  `assistant.koplugin` uses for per-book notes.
- Maps every plausible failure (bad API key, quota exceeded, network down,
  malformed response, disk full, no media player) to a clear, actionable
  user message — never a bare HTTP code.

## Installation

1. Copy or clone this folder into KOReader's plugins directory:

   ```
   <koreader-data>/plugins/speakword.koplugin/
   ```

   On Android (Boox, Onyx, etc.) that's typically
   `/storage/emulated/0/koreader/plugins/`. On a desktop development build
   it's wherever `DataStorage:getDataDir()` resolves, usually `~/.config/koreader/`.

2. **For Android System TTS (default)**: just make sure your device has a TTS engine installed (most do — typically Speech Services by Google) and at least one voice pack downloaded via Android Settings → System → Languages & input → Text-to-speech output → Install voice data. No signup, no API key. Skip step 3 if you only want Android TTS — the default `configuration.sample.lua` works as-is.

   **For ElevenLabs (better quality, optional)**: sign up at [try.elevenlabs.io/anatoly314-koreader](https://try.elevenlabs.io/anatoly314-koreader) (affiliate link), then Profile → API Keys → Create new key. The free tier gives 10K credits/month — plenty for occasional word lookups.

3. Copy `configuration.sample.lua` to `configuration.lua` (in the same
   `speakword.koplugin/` folder). The default uses Android TTS — for that
   you don't need to edit anything. To use ElevenLabs, change the provider
   line and fill in the API key:

   ```lua
   provider = "android",  -- default; change to "elevenlabs" to use that
   provider_settings = {
       elevenlabs = {
           api_key = "<your-elevenlabs-key>",
           ...
       },
       android = {
           -- nothing required; engine is whatever the device has installed
       },
   },
   ```

   `configuration.lua` is gitignored. Don't commit your key.

4. Restart KOReader. You should see "Speakword TTS" under the Tools menu.
   You can switch between providers at any time via Tools → Speakword TTS →
   **Provider**.

## Configuring the voice

Tools → Speakword TTS → **Voice**. The first tap fetches the voice list
from the active provider — for ElevenLabs that means a network round-trip
to your account (the plugin will prompt to enable Wi-Fi if needed); for
the Android System TTS provider it queries the on-device engine directly.
Pick one — the choice persists across restarts.

If you switch providers later, the voice resets to "(none selected)" and
you'll need to pick again.

## Usage

- **Single word**: tap a word, the dictionary popup appears; tap "Speak"
  on the bottom row.
- **Phrase / sentence**: long-press to highlight, then tap "Speak" on the
  highlight dialog.

For ElevenLabs, the first synthesis for a given (text, voice, model) hits
the API and caches the audio. Subsequent taps replay the cached file
instantly.

For Android System TTS, there is no cache and no file — synthesis is
on-device, so re-running it costs nothing. See *Audio playback* below for
the architectural reason.

## Audio playback

The two providers take different paths:

- **Android System TTS** plays via `TextToSpeech.speak()` — the engine
  synthesizes and outputs to the speakers itself. No file, no MediaPlayer,
  no MIME-type negotiation, no cache. This bypasses Android's mediaserver
  binder pipeline entirely, which means it survives cross-plugin
  interactions that would otherwise corrupt MediaPlayer's binder transport
  (notably HTTPS streaming responses from `assistant.koplugin`'s AI
  Dictionary feature, which on some Android 13 builds — including Boox
  China firmware — causes subsequent `MediaPlayer.setDataSource` calls to
  fail with `FAILED BINDER TRANSACTION`).
- **ElevenLabs** plays via Android's `MediaPlayer`, loaded into KOReader's
  process through a small bundled `.dex` (`audio_helper.dex`). The dex
  wraps `MediaPlayer` and `TextToSpeech` and is loaded at runtime via
  `DexClassLoader`. KOReader stays foreground — no music-player overlay,
  no "open with…" chooser. **However, on Android 13 / Boox the
  `MediaPlayer` path is fragile: any `assistant.koplugin` AI Dictionary
  invocation in the same KOReader session leaves the mediaserver binder
  pool in a state that rejects subsequent setDataSource calls. Restart
  KOReader to recover.** The Android TTS provider is not affected.

The compiled `audio_helper.dex` (~10 KB) ships in the repo; only
contributors editing `speakword/android/AudioPlayer.java` or
`speakword/android/TtsHelper.java` need the Android SDK to rebuild it
via `speakword/android/build-dex.sh`.

On non-Android platforms (desktop Linux dev builds, Kobo, Kindle), the
ElevenLabs path falls back to `Device:openLink("file://...")`. You can
also force this fallback on Android via Tools → Speakword TTS → **Audio
backend** → Intent (rarely useful — most Boox firmwares ship without any
`audio/mpeg` intent handler, so the intent dispatches silently).

The MediaPlayer Java wrapper and JNI bridge are adapted from
[`audiobook.koplugin`](https://github.com/stradichenko/audiobook.koplugin)
(AGPL-3.0); license attribution lives in the source headers.

## ElevenLabs free-tier notes

- 10,000 credits/month, ~5 credits per 5 chars with `eleven_flash_v2_5`.
- 2 concurrent requests max.
- 2,500 character cap per call.
- **Commercial use is not permitted on the free tier.** If you redistribute
  audio files generated by this plugin, you must be on a paid plan.

## Android System TTS notes

The Android provider talks to whichever TTS engine the device has installed
(usually [Speech Services by Google](https://play.google.com/store/apps/details?id=com.google.android.tts)).
It uses the same in-process JNI / `.dex` mechanism as the audio player —
`com.speakword.TtsHelper` is bundled in `audio_helper.dex` and loaded on
demand on first use.

- **Free, offline-capable.** Once a voice pack is downloaded via the system
  TTS settings, no network is required. Useful on planes and on the cellular-
  free Wi-Fi-only e-readers.
- **Lower quality** than ElevenLabs. Voices are robotic compared to neural
  cloud TTS but perfectly serviceable for pronunciation lookups.
- **Voice availability depends on what's installed on the device.** Open
  Tools → Speakword TTS → Voice to see the list. If no voices appear, the
  engine is either not initialized or no voice packs are downloaded — head
  to the Android system TTS settings to install one.
- **Engine quirks.** Some engines (notably Samsung's stock TTS) report
  "voices" that are network-only and cannot synthesize offline. The provider
  filters these out where it can, but if synthesis fails with "missing voice
  data", try a different voice from the picker or install Speech Services
  by Google as the system default.

The TTS Java wrapper is adapted from
[`audiobook.koplugin`](https://github.com/stradichenko/audiobook.koplugin)
(AGPL-3.0); license attribution lives in the source headers.

## Adding a new provider

1. Create `speakword/speakword_provider_<key>.lua`. Implement two methods:

   ```lua
   function Provider:list_voices()    -- returns (true, voices) | (false, error_code[, detail])
   function Provider:synthesize(text, voice_id)  -- returns (true, audio_bytes) | (false, error_code[, detail])
   ```

   `voices` is a table of `{ id = "...", name = "..." }`. Error codes are
   the constants in `speakword/speakword_errors.lua` — map your provider's
   raw failures (HTTP status, exceptions, parser errors) onto them so the
   rest of the plugin doesn't have to know your API.

2. Add a `<key> = "Display Name"` entry to `ProviderRegistry.KNOWN` in
   `speakword/speakword_provider.lua`.

3. Add a `provider_settings.<key>` block to `configuration.sample.lua`
   showing how to configure it.

The settings UI dropdown picks up the new provider automatically.

## Credits

Plugin scaffolding and the per-book folder convention adapted from
[`assistant.koplugin`](https://github.com/omer-faruq/assistant.koplugin)
(AGPL-3.0). HTTP machinery follows the same socket.http / ltn12 / Trapper
pattern KOReader uses internally.

## License

AGPL-3.0. See `LICENSE`. The Android audio playback wrapper is adapted from [audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin) (also AGPL-3.0).
