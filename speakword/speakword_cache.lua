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
--- @return string|nil path  nil if no document context (filemanager)
function Cache.pathFor(ui, text, voice_id, model_id)
    local dir = getBookCacheDir(ui)
    if not dir then return nil end

    local readable = sanitizeForFilename(text or "")
    if readable == "" then readable = "speech" end
    local fp = fingerprint(text, voice_id, model_id)
    return dir .. readable .. "-" .. fp .. ".mp3"
end

--- Does a cached file already exist for these parameters?
function Cache.exists(ui, text, voice_id, model_id)
    local path = Cache.pathFor(ui, text, voice_id, model_id)
    if not path then return false end
    return lfs.attributes(path, "mode") == "file", path
end

--- Persist audio bytes to the cache. Creates the per-book folder if needed.
--- Returns (true, path) on success, (false, error_code) on failure.
function Cache.write(ui, text, voice_id, model_id, audio_bytes)
    local path = Cache.pathFor(ui, text, voice_id, model_id)
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
