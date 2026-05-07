-- speakword_provider: provider registry + abstract base.
--
-- A provider is any module that implements the following two methods:
--
--   provider:list_voices()
--       returns (true, voices_table) on success
--       returns (false, error_code, optional_detail) on failure
--       voices_table = { { id = "...", name = "..." }, ... }  (alphabetically sorted)
--
--   provider:synthesize(text, voice_id)
--       returns (true, audio_bytes) on success
--       returns (false, error_code, optional_detail) on failure
--
-- Adding a new provider:
--   1. Drop a `speakword_provider_<key>.lua` next to this file.
--   2. Make it `return` a module exposing `new(provider_settings)` and the
--      two methods above.
--   3. Add a `provider_settings.<key>` block to configuration.lua.
--   4. The settings UI dropdown will pick it up automatically.

local logger = require("logger")

local ProviderRegistry = {}

-- Map of stable key -> human-displayed name. The settings UI uses this to
-- render the provider dropdown. New providers must register here.
ProviderRegistry.KNOWN = {
    elevenlabs = "ElevenLabs",
}

--- Instantiate the provider named by `key` from the user's CONFIGURATION
--- table. Returns (provider_instance) on success, (nil, reason_string) on
--- failure. The reason_string is logged-grade, not user-facing.
function ProviderRegistry.create(key, configuration)
    if not key or key == "" then
        return nil, "no provider key supplied"
    end
    if not ProviderRegistry.KNOWN[key] then
        return nil, "unknown provider: " .. tostring(key)
    end

    local provider_settings = configuration
        and configuration.provider_settings
        and configuration.provider_settings[key]
    if not provider_settings then
        return nil, "no provider_settings entry for " .. tostring(key)
    end

    local module_name = "speakword/speakword_provider_" .. key
    local ok, mod = pcall(require, module_name)
    if not ok then
        logger.warn("speakword_provider: failed to load", module_name, mod)
        return nil, "failed to load provider module: " .. tostring(mod)
    end

    local instance = mod.new(provider_settings)
    return instance
end

return ProviderRegistry
