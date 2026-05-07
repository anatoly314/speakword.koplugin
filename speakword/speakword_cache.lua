-- speakword_cache: per-book on-disk cache for synthesized audio.
--
-- Cache layout follows assistant.koplugin's convention for per-book artifacts:
-- given a document at /books/MyBook.epub, the per-book folder is
-- /books/MyBook/. Audio files live directly inside there with a deterministic
-- filename derived from (text, voice_id, model_id).
--
-- We deliberately do NOT use a hash; the user benefits from being able to
-- inspect the folder and see which words got synthesized. We do sanitize and
-- truncate the human-readable portion, then append a short fingerprint so
-- "the the" with two different voices doesn't collide.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Errors = require("speakword/speakword_errors")

local Cache = {}

-- Length cap for the readable portion of the filename. Keep well under
-- typical filesystem limits (eCryptfs on some Android setups truncates at
-- 143 bytes including extension).
local MAX_READABLE_LEN = 60

--- Sniff a synthesized audio buffer's container format from its magic bytes
--- and return the matching file extension (with leading dot). Different TTS
--- providers hand us different containers — ElevenLabs returns real MP3,
--- Android's TextToSpeech.synthesizeToFile always emits WAV/PCM — and the
--- on-disk extension has to match, otherwise Android MediaPlayer's content
--- sniffer rejects the file with status=0x80000000.
---
--- Falls back to ".audio" for anything we can't identify, which is still
--- safer than a confidently-wrong extension: most players will at least
--- attempt content-based detection on an unknown extension.
---
--- Exported so the ephemeral and preview write paths in main.lua /
--- speakword_settings.lua can reuse this without duplicating the table of
--- magic numbers.
--- @param bytes string  raw audio buffer (only first ~12 bytes inspected)
--- @return string  one of ".mp3", ".wav", ".ogg", ".audio"
function Cache.audioExtensionFor(bytes)
    if not bytes or #bytes < 4 then return ".audio" end
    local b = bytes:sub(1, 4)
    -- "RIFF...." container header — WAV (also AVI, but TTS won't emit that).
    if b == "RIFF" then return ".wav" end
    -- "ID3" tag prefix marks a tagged MP3 file.
    if b:sub(1, 3) == "ID3" then return ".mp3" end
    -- Bare MPEG audio frame sync: 0xFF followed by one of 0xFB / 0xF3 / 0xF2
    -- (MPEG-1 / MPEG-2 / MPEG-2.5 Layer III, the variants real TTS APIs emit).
    local b1, b2 = bytes:byte(1), bytes:byte(2)
    if b1 == 0xFF and (b2 == 0xFB or b2 == 0xF3 or b2 == 0xF2) then
        return ".mp3"
    end
    -- "OggS" page header — Ogg (Vorbis or Opus payload).
    if b == "OggS" then return ".ogg" end
    return ".audio"
end

local function sanitizeForFilename(s)
    -- Strip control chars and characters that are illegal on FAT/exFAT/NTFS
    -- (Boox SD cards may be exFAT).
    s = s:gsub("[/\\:%*%?\"<>|%c]", "_")
    s = s:gsub("%s+", "_")
    if #s > MAX_READABLE_LEN then
        s = s:sub(1, MAX_READABLE_LEN)
    end
    return s
end

-- Deterministic short fingerprint of (text, voice_id, model_id). djb2 hash
-- truncated to 8 hex chars: collisions are astronomically unlikely for the
-- per-book set sizes we care about, and the fingerprint is human-grep-able.
local function fingerprint(text, voice_id, model_id)
    local h = 5381
    local payload = (text or "") .. "|" .. (voice_id or "") .. "|" .. (model_id or "")
    for i = 1, #payload do
        h = (h * 33 + payload:byte(i)) % 0x100000000
    end
    return string.format("%08x", h)
end

--- Derive the per-book audio directory for a given KOReader UI.
--- Returns nil when the UI has no document open (e.g. file manager) — the
--- caller should fall back to a global cache or refuse to cache.
--- @param ui table  KOReader's reader UI
--- @return string|nil book_dir absolute path ending with "/"
local function getBookCacheDir(ui)
    local doc_path = ui and ui.document and ui.document.file
    if not doc_path then return nil end

    local book_dir      = doc_path:match("(.*/)") or "./"
    local book_filename = doc_path:match("([^/\\]+)$") or "book"
    local book_stem     = book_filename:gsub("%.[^.]*$", "")

    -- Same convention as assistant.koplugin/assistant_utils.lua:saveWordNote
    -- so notes and audio sit side by side in the same folder.
    return book_dir .. book_stem .. "/"
end

--- Make sure the directory exists. Returns true on success, false + error
--- code on failure.
local function ensureDir(dir)
    local attr = lfs.attributes(dir)
    if attr then
        if attr.mode == "directory" then return true end
        return false, Errors.CODE.DISK
    end
    local ok, err = lfs.mkdir(dir)
    if not ok then
        logger.warn("speakword_cache: mkdir failed", dir, err)
        return false, Errors.CODE.DISK
    end
    return true
end

--- Compute the full cache path for the given (ui, text, voice_id, model_id).
--- This does NOT touch the filesystem. Use exists() / read() / write() for I/O.
---
--- The extension argument is optional and defaults to ".mp3" so existing
--- callers (and existing on-disk files) keep working. write() overrides this
--- by sniffing the actual audio bytes — so an Android-TTS WAV gets ".wav"
--- and an ElevenLabs MP3 gets ".mp3", same fingerprint, no collision since
--- the suffix differs.
--- @param extension string|nil  e.g. ".wav" / ".mp3" / ".ogg" / ".audio"
--- @return string|nil path  nil if no document context (filemanager)
function Cache.pathFor(ui, text, voice_id, model_id, extension)
    local dir = getBookCacheDir(ui)
    if not dir then return nil end

    local readable = sanitizeForFilename(text or "")
    if readable == "" then readable = "speech" end
    local fp = fingerprint(text, voice_id, model_id)
    local ext = extension or ".mp3"
    return dir .. readable .. "-" .. fp .. ext
end

--- Peek the first 12 bytes of a file. Returns "" on any error.
--- Used to validate that a cached file's content actually matches its
--- extension before we trust the cache hit.
local function peekMagic(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local head = f:read(12) or ""
    f:close()
    return head
end

--- Does a cached file already exist for these parameters?
---
--- We don't know which extension the bytes will demand until we've seen them,
--- so we probe each known audio extension. The fingerprint stays stable
--- across formats, so at most one of these *should* match — and we further
--- validate the file's magic against the extension to skip stale entries
--- left behind by the old "always .mp3" code path (a WAV-content file sitting
--- under an .mp3 name is treated as a miss so it gets re-synthesized).
function Cache.exists(ui, text, voice_id, model_id)
    for _, ext in ipairs({ ".mp3", ".wav", ".ogg", ".audio" }) do
        local path = Cache.pathFor(ui, text, voice_id, model_id, ext)
        if path and lfs.attributes(path, "mode") == "file" then
            local actual = Cache.audioExtensionFor(peekMagic(path))
            -- ".audio" is our unknown-format fallback — accept whatever's
            -- there, since we can't do better than the file we wrote.
            if actual == ext or ext == ".audio" then
                return true, path
            end
        end
    end
    return false
end

--- Persist audio bytes to the cache. Creates the per-book folder if needed.
--- The on-disk extension is derived from the bytes' magic header — see
--- audioExtensionFor — so providers that emit different containers
--- (Android TTS = WAV, ElevenLabs = MP3) get correctly-typed files instead
--- of mislabeled blobs that MediaPlayer rejects.
--- Returns (true, path) on success, (false, error_code) on failure.
function Cache.write(ui, text, voice_id, model_id, audio_bytes)
    local ext = Cache.audioExtensionFor(audio_bytes)
    local path = Cache.pathFor(ui, text, voice_id, model_id, ext)
    if not path then return false, Errors.CODE.DISK end

    local dir = path:match("(.*/)")
    local ok, code = ensureDir(dir)
    if not ok then return false, code end

    local f, err = io.open(path, "wb")
    if not f then
        logger.warn("speakword_cache: open for write failed", path, err)
        return false, Errors.CODE.DISK
    end

    local ok_write, write_err = pcall(function() f:write(audio_bytes) end)
    f:close()
    if not ok_write then
        logger.warn("speakword_cache: write failed", path, write_err)
        os.remove(path) -- don't leave a half-written file as a "valid" cache hit
        return false, Errors.CODE.DISK
    end

    return true, path
end

return Cache
