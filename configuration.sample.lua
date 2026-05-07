-- Speakword plugin user configuration.
--
-- Copy this file to `configuration.lua` (same folder) and fill in your API key.
-- `configuration.lua` is gitignored and never committed.
--
-- The voice selection and other user-mutable preferences are NOT in this file.
-- They are managed via the Speakword settings menu (Tools → Speakword) and
-- persisted by KOReader's settings store. This file holds only secrets and
-- provider endpoint configuration.

local CONFIGURATION = {

    -- Which TTS provider to use. Supported values:
    --   "elevenlabs" — cloud TTS (paid, free tier 10K credits/month).
    --   "android"    — the device's built-in system TTS (free, on-device,
    --                  Android-only). Quality is noticeably lower than
    --                  ElevenLabs but works offline once a voice pack is
    --                  downloaded.
    -- The user can also switch providers at runtime via Tools → Speakword TTS
    -- → Provider; this `provider =` field is just the initial default.
    provider = "elevenlabs",

    -- Per-provider settings. Each key matches a provider implementation
    -- in `speakword/speakword_provider_<key>.lua`. Even providers that
    -- require no configuration must have an entry here (an empty table is
    -- fine) so the registry can identify them as enabled.
    provider_settings = {
        elevenlabs = {
            -- Get a free key at https://elevenlabs.io  (free tier: 10K
            -- credits/month, ~5 credits per 5 chars with eleven_flash_v2_5).
            api_key  = "your-elevenlabs-api-key",

            -- Base URL is rarely changed; expose it for self-hosted gateways
            -- or regional endpoints if those ever appear.
            base_url = "https://api.elevenlabs.io",

            -- Default model. eleven_flash_v2_5 is the cheapest and fastest;
            -- eleven_multilingual_v2 sounds noticeably better but costs ~2x
            -- credits. See https://elevenlabs.io/docs/models
            model_id = "eleven_flash_v2_5",
        },
        android = {
            -- Android System TTS: no API key, no base URL — the engine is
            -- whatever the device has installed (typically
            -- com.google.android.tts on Onyx/Boox devices, samsung TTS on
            -- Samsung, etc.). This block is intentionally near-empty;
            -- you only need to keep the table present.
            --
            -- Requires:
            --   1. An Android device. On non-Android platforms this provider
            --      will refuse to list voices.
            --   2. A TTS engine installed (most stock Android already has
            --      Speech Services by Google).
            --   3. At least one voice pack downloaded. On Android, this is
            --      done via Settings → System → Languages & input →
            --      Text-to-speech output → Install voice data. Without a
            --      downloaded pack, voices may exist in the picker but
            --      synthesis will fail with a "missing voice data" error.
            --
            -- Optional override: `model_id` is mixed into the per-book cache
            -- filename. If you switch TTS engines (e.g. Google -> Samsung)
            -- and want previously cached audio to be regenerated under the
            -- new voice, change this string.
            model_id = "android_default",
        },
    },
}

return CONFIGURATION
