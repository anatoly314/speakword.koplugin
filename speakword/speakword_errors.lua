-- speakword_errors: translate provider/HTTP/network failures into a single,
-- short, user-actionable string. Keep all user-facing copy in one file so a
-- translator (or a future i18n PR) only has to touch one module.
--
-- Every public entry returns a localized string. Callers should pass the
-- result straight to InfoMessage:new{ text = ... }.

local _ = require("gettext")
local T = require("ffi/util").template

local Errors = {}

-- Stable error codes used throughout the plugin. Providers map their
-- raw failures (HTTP status, socket errno, decoder error) to one of these,
-- so the player/cache/UI never has to reason about provider-specific quirks.
Errors.CODE = {
    UNAUTHORIZED       = "unauthorized",        -- 401 / 403
    QUOTA              = "quota",               -- 429 / payment_required
    SERVER             = "server",              -- 5xx
    NETWORK            = "network",             -- DNS, no route, timeout
    EMPTY_RESPONSE     = "empty_response",      -- 200 but no audio bytes
    MALFORMED_RESPONSE = "malformed_response",  -- non-JSON where JSON expected, etc.
    DISK               = "disk",                -- write failure, ENOSPC
    PLAYBACK           = "playback",            -- cannot launch a player
    NO_VOICE_SELECTED  = "no_voice_selected",   -- user hasn't picked one yet
    NOT_CONFIGURED     = "not_configured",      -- API key missing
    EMPTY_INPUT        = "empty_input",         -- nothing to speak
    UNKNOWN            = "unknown",
}

-- Human messages keyed by code. The orchestrator's spec demands wording that
-- tells the user what to do next, not just what failed.
local MESSAGES = {
    [Errors.CODE.UNAUTHORIZED]       = _("API key invalid or revoked. Open Settings → Speakword to update."),
    [Errors.CODE.QUOTA]              = _("Quota or rate limit hit. Try again later, or top up your ElevenLabs account."),
    [Errors.CODE.SERVER]             = _("ElevenLabs server error. Try again in a moment."),
    [Errors.CODE.NETWORK]            = _("No internet connection (or the TTS server is unreachable)."),
    [Errors.CODE.EMPTY_RESPONSE]     = _("Unexpected response from TTS provider (no audio returned)."),
    [Errors.CODE.MALFORMED_RESPONSE] = _("Unexpected response from TTS provider."),
    [Errors.CODE.DISK]               = _("Couldn't save audio file (disk full or path not writable)."),
    [Errors.CODE.PLAYBACK]           = _("Couldn't play audio (no media player available)."),
    [Errors.CODE.NO_VOICE_SELECTED]  = _("No voice selected. Open Settings → Speakword and pick one."),
    [Errors.CODE.NOT_CONFIGURED]     = _("Speakword is not configured. Copy configuration.sample.lua to configuration.lua and add your API key."),
    [Errors.CODE.EMPTY_INPUT]        = _("Nothing to speak."),
    [Errors.CODE.UNKNOWN]            = _("Speakword failed (unknown error). Check the logs."),
}

--- Map an HTTP status code to one of our stable codes.
--- @param http_status number|string|nil
--- @return string code
function Errors.fromHttpStatus(http_status)
    local n = tonumber(http_status)
    if not n then return Errors.CODE.UNKNOWN end
    if n == 401 or n == 403 then return Errors.CODE.UNAUTHORIZED end
    if n == 402 or n == 429 then return Errors.CODE.QUOTA end
    if n >= 500 and n < 600 then return Errors.CODE.SERVER end
    return Errors.CODE.UNKNOWN
end

--- Get the user-facing message for a code. Falls back to UNKNOWN if the code
--- is not one we know about, so a stray return value never crashes the UI.
--- @param code string
--- @param detail string|nil  optional extra context appended on a new line
--- @return string
function Errors.message(code, detail)
    local base = MESSAGES[code] or MESSAGES[Errors.CODE.UNKNOWN]
    if detail and detail ~= "" then
        return T("%1\n\n%2", base, detail)
    end
    return base
end

return Errors
