-- speakword_player: hand off an mp3 file to the system to play.
--
-- KOReader does not expose an in-process audio API on Android (no MediaPlayer
-- binding, no SDL_mixer in the standard build). The cleanest device-supported
-- path is `Device:openLink("file:///<path>")`, which dispatches an Android
-- VIEW intent and lets the OS pick a media player. On the Boox Note X5 this
-- typically means a brief overlay from the system music player.
--
-- TODO: ASK ORCHESTRATOR — investigate whether KOReader on the user's Boox
-- exposes any in-process audio playback (custom build? android.lua extension?)
-- so the user doesn't have to leave the reader for each pronunciation. If
-- not, document the limitation in the README.

local Device  = require("device")
local logger  = require("logger")
local Errors  = require("speakword/speakword_errors")

local Player = {}

--- Play an audio file at `path`.
--- Returns (true) on success, (false, error_code) on failure.
function Player.play(path)
    if not path or path == "" then
        return false, Errors.CODE.PLAYBACK
    end

    if not Device.canOpenLink or not Device:canOpenLink() then
        logger.warn("speakword_player: Device:openLink unavailable on this platform")
        return false, Errors.CODE.PLAYBACK
    end

    -- file:// URI so Android's Intent system treats it as a file with a
    -- detectable MIME type (audio/mpeg via the .mp3 extension).
    local uri = "file://" .. path
    local ok, err = pcall(function() Device:openLink(uri) end)
    if not ok then
        logger.warn("speakword_player: openLink threw", err)
        return false, Errors.CODE.PLAYBACK
    end

    return true
end

return Player
