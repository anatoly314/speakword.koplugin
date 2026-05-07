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

    -- Which TTS provider to use. Currently the only supported value is
    -- "elevenlabs". Future providers (Google Cloud TTS, Azure, Polly, ...)
    -- will be added under additional keys here.
    provider = "elevenlabs",

    -- Per-provider settings. Each key matches a provider implementation
    -- in `speakword/speakword_provider_<key>.lua`.
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
    },
}

return CONFIGURATION
