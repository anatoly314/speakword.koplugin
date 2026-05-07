-- speakword_provider_elevenlabs: TTS via ElevenLabs.
--
-- Endpoints:
--   GET  /v1/voices                            -> JSON voice list
--   POST /v1/text-to-speech/{voice_id}         -> audio/mpeg body
--
-- Auth header: xi-api-key. See https://elevenlabs.io/docs/api-reference

local http       = require("socket.http")
local https      = require("ssl.https")
local ltn12      = require("ltn12")
local socket     = require("socket")
local socketutil = require("socketutil")
local json       = require("json")
local logger     = require("logger")

local Errors = require("speakword/speakword_errors")

local ElevenLabs = {}
ElevenLabs.__index = ElevenLabs

-- Default per-request timeouts (seconds). The synthesize call is allowed
-- noticeably longer because the server holds the connection open until the
-- mp3 is ready; voice listing is small and fast.
local TIMEOUT_LIST_VOICES = { connect = 15, total = 30 }
local TIMEOUT_SYNTHESIZE  = { connect = 30, total = 90 }

--- Construct a new ElevenLabs provider from a config block:
---   { api_key = "...", base_url = "...", model_id = "..." }
function ElevenLabs.new(provider_settings)
    local self = setmetatable({}, ElevenLabs)
    self.api_key  = provider_settings.api_key
    self.base_url = provider_settings.base_url or "https://api.elevenlabs.io"
    self.model_id = provider_settings.model_id or "eleven_flash_v2_5"
    return self
end

--- Internal: perform an HTTP request and return (success, code, body).
--- Mirrors the pattern used in assistant.koplugin/api_handlers/base.lua so
--- behaviour is consistent across the two plugins on the same device.
local function doRequest(url, method, headers, body, timeout)
    if url:sub(1, 8) == "https://" then
        -- Same trade-off as assistant.koplugin: many e-readers ship outdated
        -- root CAs; verifying often breaks things. The API key alone gates
        -- access. If your threat model needs MitM resistance, override this
        -- in a fork.
        https.cert_verify = false
    end

    socketutil:set_timeout(timeout.connect, timeout.total)

    local sink = {}
    local request = {
        url     = url,
        method  = method,
        headers = headers or {},
        sink    = ltn12.sink.table(sink),
    }
    if body then
        request.source = ltn12.source.string(body)
    end

    -- socket.skip(1, ...) drops the boolean in slot 1 of http.request's
    -- multi-return; we only care about (code, response_headers, status).
    local code, response_headers, status_line = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE
    then
        return false, "timeout", nil
    end

    -- response_headers is nil when the request never reached an HTTP server
    -- (DNS failure, no route, refused, ...). We treat that as "network".
    if response_headers == nil then
        return false, "network", status_line
    end

    return true, code, content
end

--- GET /v1/voices.
--- Returns (true, voices_table) | (false, error_code[, detail]).
function ElevenLabs:list_voices()
    if not self.api_key or self.api_key == "" or self.api_key == "your-elevenlabs-api-key" then
        return false, Errors.CODE.NOT_CONFIGURED
    end

    local url = self.base_url .. "/v1/voices"
    local headers = {
        ["xi-api-key"] = self.api_key,
        ["Accept"]     = "application/json",
    }

    local ok, code, body = doRequest(url, "GET", headers, nil, TIMEOUT_LIST_VOICES)
    if not ok then
        if code == "timeout" or code == "network" then
            return false, Errors.CODE.NETWORK
        end
        return false, Errors.CODE.UNKNOWN
    end

    if code ~= 200 then
        logger.warn("speakword/elevenlabs: list_voices non-200", code)
        return false, Errors.fromHttpStatus(code)
    end

    local ok_parse, parsed = pcall(json.decode, body or "")
    if not ok_parse or type(parsed) ~= "table" or type(parsed.voices) ~= "table" then
        return false, Errors.CODE.MALFORMED_RESPONSE
    end

    local voices = {}
    for _, v in ipairs(parsed.voices) do
        if type(v) == "table" and type(v.voice_id) == "string" then
            table.insert(voices, {
                id   = v.voice_id,
                name = v.name or v.voice_id,
            })
        end
    end
    table.sort(voices, function(a, b) return (a.name or "") < (b.name or "") end)

    return true, voices
end

--- POST /v1/text-to-speech/{voice_id}.
--- Returns (true, audio_bytes) | (false, error_code[, detail]).
function ElevenLabs:synthesize(text, voice_id)
    if not text or text == "" then
        return false, Errors.CODE.EMPTY_INPUT
    end
    if not voice_id or voice_id == "" then
        return false, Errors.CODE.NO_VOICE_SELECTED
    end
    if not self.api_key or self.api_key == "" or self.api_key == "your-elevenlabs-api-key" then
        return false, Errors.CODE.NOT_CONFIGURED
    end

    local url = self.base_url .. "/v1/text-to-speech/" .. voice_id
    local request_body = json.encode({
        text     = text,
        model_id = self.model_id,
    })

    local headers = {
        ["xi-api-key"]     = self.api_key,
        ["Content-Type"]   = "application/json",
        ["Accept"]         = "audio/mpeg",
        ["Content-Length"] = tostring(#request_body),
    }

    local ok, code, body = doRequest(url, "POST", headers, request_body, TIMEOUT_SYNTHESIZE)
    if not ok then
        if code == "timeout" or code == "network" then
            return false, Errors.CODE.NETWORK
        end
        return false, Errors.CODE.UNKNOWN
    end

    if code ~= 200 then
        -- On error responses ElevenLabs returns JSON with a `detail` field
        -- even when the request asked for audio/mpeg. Try to surface it.
        logger.warn("speakword/elevenlabs: synthesize non-200", code)
        local parsed_ok, parsed = pcall(json.decode, body or "")
        local detail
        if parsed_ok and type(parsed) == "table" then
            if type(parsed.detail) == "table" then
                detail = parsed.detail.message or parsed.detail.status
            elseif type(parsed.detail) == "string" then
                detail = parsed.detail
            end
        end
        return false, Errors.fromHttpStatus(code), detail
    end

    if not body or #body == 0 then
        return false, Errors.CODE.EMPTY_RESPONSE
    end

    return true, body
end

return ElevenLabs
