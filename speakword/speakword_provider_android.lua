--[[--
speakword_provider_android: TTS via Android's built-in TextToSpeech engine.

Free, on-device, offline-capable (once a language pack is downloaded). The
quality is significantly lower than ElevenLabs but works without an API key
and without an internet connection — useful for casual word lookups, and the
only sensible option on a device that's mostly offline (e.g. an e-ink reader
on a long flight).

This module mirrors speakword_provider_elevenlabs.lua's interface (list_voices
and synthesize) but instead of HTTPS calls, it talks to the Java
TextToSpeech API via the same JNI/.dex pattern speakword_player.lua already
uses for the in-process MediaPlayer.

Both com.speakword.AudioPlayer (used by speakword_player) and
com.speakword.TtsHelper (used here) live in the same audio_helper.dex.
We re-bootstrap a DexClassLoader here rather than sharing one with
speakword_player; classloading is cheap, the classloader is per-module
state, and avoiding cross-module state coupling keeps the failure modes
local.

The synth interface is bytes-in / bytes-out, so we synthesize to a temp WAV
on the device, read the bytes back, and return them. The caller (main.lua)
handles cache persistence vs ephemeral storage uniformly across providers.

The JNI plumbing (DexClassLoader bootstrap, method-id caching, GlobalRef
lifetime management, polling-friendly init) is adapted from
  https://github.com/stradichenko/audiobook.koplugin (AGPL-3.0)
specifically `androidtts.lua`.

Copyright (C) 2026 Speakword contributors
Copyright (C) 2025 audiobook.koplugin contributors

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, version 3 of the License, or (at your
option) any later version.
--]]--

local Device      = require("device")
local DataStorage = require("datastorage")
local logger      = require("logger")
local Errors      = require("speakword/speakword_errors")

local AndroidTts = {}
AndroidTts.__index = AndroidTts

-- Path to the precompiled .dex helper (shared with speakword_player).
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/speakword.koplugin"
local DEX_PATH   = PLUGIN_DIR .. "/speakword/android/audio_helper.dex"

-- Single shared scratch path for the WAV that TextToSpeech.synthesizeToFile
-- writes. Lives in koreader's cache dir so it never pollutes the user's
-- library, and is overwritten on every synth (the cache layer in main.lua
-- copies the bytes into a per-book file when caching is enabled).
local TEMP_WAV_PATH = DataStorage:getDataDir() .. "/cache/speakword-android-tts.tmp.wav"

-- Default time we wait for the engine to finish loading on first call.
-- Engines like com.google.android.tts can take 2-4s on a cold start; on
-- a Boox Note X5 it's typically <1s after the first use.
local INIT_TIMEOUT_MS = 8000

-- Default time we wait for a single synthesizeToFile() to finish. Words
-- and short sentences usually return in under a second; longer highlights
-- can take a few seconds depending on the engine.
local SYNTH_TIMEOUT_MS = 30000

-- Module-scope JNI cache. Lives across all provider instances (only one
-- TextToSpeech engine per process makes sense; the engine itself is a
-- singleton-like resource). We init lazily on first list_voices/synthesize.
local _state = {
    initialized   = false,   -- dex loaded + helper instantiated
    failed        = false,   -- short-circuit further attempts after a fatal init error
    helper_ref    = nil,     -- GlobalRef to TtsHelper instance
    helper_class  = nil,     -- GlobalRef to TtsHelper class
    method        = {},      -- cached jmethodID values
    android       = nil,     -- the `android` Lua module
}

-- ----------------------------------------------------------------------------
-- JNI helpers
-- ----------------------------------------------------------------------------

--- Check for a pending JNI exception, log it, and clear it.
--- @return boolean true if an exception was pending
local function checkException(env)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        return true
    end
    return false
end

--- Resolve the app's cache dir from the activity Context. Used by
--- DexClassLoader to deposit its optimized-dex output.
local function getCacheDir(android)
    return android.jni:context(android.app.activity.vm, function(jni)
        local cache_file = jni:callObjectMethod(
            android.app.activity.clazz,
            "getCacheDir",
            "()Ljava/io/File;"
        )
        if cache_file == nil then return nil end
        local abs_path = jni:callObjectMethod(
            cache_file, "getAbsolutePath", "()Ljava/lang/String;"
        )
        jni.env[0].DeleteLocalRef(jni.env, cache_file)
        if abs_path == nil then return nil end
        local result = jni:to_string(abs_path)
        jni.env[0].DeleteLocalRef(jni.env, abs_path)
        return result
    end)
end

--- Lazy initialization of the Android TTS helper. Loads the .dex via
--- DexClassLoader, instantiates `com.speakword.TtsHelper`, caches method
--- IDs and GlobalRefs, then waits up to INIT_TIMEOUT_MS for the engine
--- itself to finish loading. Returns true on success, false on permanent
--- failure (in which case `_state.failed` is set so further calls
--- short-circuit instead of timing out again).
local function initTts()
    if _state.initialized then return true end
    if _state.failed then return false end

    if not Device:isAndroid() then
        logger.warn("speakword/android-tts: not running on Android")
        _state.failed = true
        return false
    end

    local ok, android = pcall(require, "android")
    if not ok then
        logger.warn("speakword/android-tts: cannot load android module:", android)
        _state.failed = true
        return false
    end
    _state.android = android

    -- Sanity check: dex shipped with the plugin?
    local f = io.open(DEX_PATH, "r")
    if not f then
        logger.warn("speakword/android-tts: audio_helper.dex not found at", DEX_PATH)
        _state.failed = true
        return false
    end
    f:close()

    local cache_dir = getCacheDir(android)
    if not cache_dir then
        logger.warn("speakword/android-tts: cannot resolve cache dir")
        _state.failed = true
        return false
    end

    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env

        -- 1. Activity ClassLoader (the parent for our DexClassLoader).
        local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
        if checkException(env) or ctx_class == nil then
            logger.warn("speakword/android-tts: GetObjectClass(activity) failed")
            return
        end
        local get_cl_id = env[0].GetMethodID(env, ctx_class,
            "getClassLoader", "()Ljava/lang/ClassLoader;")
        env[0].DeleteLocalRef(env, ctx_class)
        if checkException(env) or get_cl_id == nil then
            logger.warn("speakword/android-tts: getClassLoader methodID missing")
            return
        end
        local parent_cl = env[0].CallObjectMethod(env,
            android.app.activity.clazz, get_cl_id)
        if checkException(env) or parent_cl == nil then
            logger.warn("speakword/android-tts: getClassLoader returned null")
            return
        end

        -- 2. DexClassLoader pointing at our .dex.
        local dcl_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        if checkException(env) or dcl_class == nil then
            logger.warn("speakword/android-tts: DexClassLoader not found")
            env[0].DeleteLocalRef(env, parent_cl)
            return
        end
        local dcl_init = env[0].GetMethodID(env, dcl_class, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        if checkException(env) or dcl_init == nil then
            logger.warn("speakword/android-tts: DexClassLoader.<init> missing")
            env[0].DeleteLocalRef(env, parent_cl)
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end
        local j_dex_path = env[0].NewStringUTF(env, DEX_PATH)
        local j_opt_dir  = env[0].NewStringUTF(env, cache_dir)
        local dcl_obj = env[0].NewObject(env, dcl_class, dcl_init,
            j_dex_path, j_opt_dir, nil, parent_cl)
        env[0].DeleteLocalRef(env, j_dex_path)
        env[0].DeleteLocalRef(env, j_opt_dir)
        env[0].DeleteLocalRef(env, parent_cl)
        if checkException(env) or dcl_obj == nil then
            logger.warn("speakword/android-tts: DexClassLoader instantiation failed")
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        -- 3. Resolve loadClass() and load TtsHelper.
        local load_class_id = env[0].GetMethodID(env, dcl_class,
            "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        env[0].DeleteLocalRef(env, dcl_class)
        if checkException(env) or load_class_id == nil then
            logger.warn("speakword/android-tts: loadClass methodID missing")
            env[0].DeleteLocalRef(env, dcl_obj)
            return
        end
        local j_class_name = env[0].NewStringUTF(env, "com.speakword.TtsHelper")
        local helper_class = env[0].CallObjectMethod(env,
            dcl_obj, load_class_id, j_class_name)
        env[0].DeleteLocalRef(env, j_class_name)
        env[0].DeleteLocalRef(env, dcl_obj)
        if checkException(env) or helper_class == nil then
            logger.warn("speakword/android-tts: TtsHelper class not found in .dex")
            return
        end

        -- 4. Instantiate TtsHelper(Context).
        local helper_init = env[0].GetMethodID(env, helper_class,
            "<init>", "(Landroid/content/Context;)V")
        if checkException(env) or helper_init == nil then
            logger.warn("speakword/android-tts: TtsHelper.<init>(Context) missing")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end
        local helper_obj = env[0].NewObject(env, helper_class, helper_init,
            android.app.activity.clazz)
        if checkException(env) or helper_obj == nil then
            logger.warn("speakword/android-tts: TtsHelper instantiation failed")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 5. Cache method IDs.
        local m = _state.method
        m.isInitialized      = env[0].GetMethodID(env, helper_class, "isInitialized", "()Z")
        m.getInitStatus      = env[0].GetMethodID(env, helper_class, "getInitStatus", "()I")
        m.listVoices         = env[0].GetMethodID(env, helper_class, "listVoices", "()Ljava/lang/String;")
        m.synthesizeToFile   = env[0].GetMethodID(env, helper_class, "synthesizeToFile",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z")
        m.isSynthesisDone    = env[0].GetMethodID(env, helper_class, "isSynthesisDone", "()Z")
        m.wasSynthesisError  = env[0].GetMethodID(env, helper_class, "wasSynthesisError", "()Z")
        m.shutdown           = env[0].GetMethodID(env, helper_class, "shutdown", "()V")
        if checkException(env)
                or m.isInitialized      == nil
                or m.getInitStatus      == nil
                or m.listVoices         == nil
                or m.synthesizeToFile   == nil
                or m.isSynthesisDone    == nil
                or m.wasSynthesisError  == nil
                or m.shutdown           == nil then
            logger.warn("speakword/android-tts: failed to resolve TtsHelper method IDs")
            env[0].DeleteLocalRef(env, helper_obj)
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 6. Promote refs to GlobalRefs so they outlive this JNI context.
        _state.helper_ref   = env[0].NewGlobalRef(env, helper_obj)
        _state.helper_class = env[0].NewGlobalRef(env, helper_class)
        env[0].DeleteLocalRef(env, helper_obj)
        env[0].DeleteLocalRef(env, helper_class)

        load_ok = true
        logger.dbg("speakword/android-tts: TtsHelper loaded from .dex")
    end)

    if not load_ok then
        _state.failed = true
        return false
    end
    _state.initialized = true
    return true
end

-- Wall-clock millisecond timestamp. KOReader bundles luasocket so socket
-- is available; we fall back to os.clock() (process-CPU, but fine as a
-- coarse polling timer) on the off-chance it isn't loadable here.
local _socket_ok, _socket = pcall(require, "socket")
local function nowMs()
    if _socket_ok and _socket and _socket.gettime then
        return _socket.gettime() * 1000
    end
    return os.clock() * 1000
end

--- Poll TtsHelper.isInitialized() / getInitStatus() until the engine reports
--- ready or the timeout elapses. Returns true on success.
--- @param timeout_ms number
--- @return boolean
local function waitForEngineReady(timeout_ms)
    if not _state.initialized or not _state.helper_ref then return false end
    local android = _state.android

    local deadline = nowMs() + timeout_ms
    while nowMs() < deadline do
        local ready = android.jni:context(android.app.activity.vm, function(jni)
            local r = jni.env[0].CallBooleanMethod(jni.env,
                _state.helper_ref, _state.method.isInitialized)
            if checkException(jni.env) then return false end
            return r ~= 0
        end)
        if ready then return true end

        -- Engine could have failed init outright (status > 0). If so, bail
        -- early so we don't burn the whole timeout on a doomed wait.
        local status = android.jni:context(android.app.activity.vm, function(jni)
            local r = jni.env[0].CallIntMethod(jni.env,
                _state.helper_ref, _state.method.getInitStatus)
            if checkException(jni.env) then return -2 end
            return r
        end)
        -- status conventions: -1 pending, 0 success, anything else = error.
        -- (Java's TextToSpeech.SUCCESS == 0, TextToSpeech.ERROR == -1; our
        -- helper's "pending" is also -1, so we treat 0 = ready and any
        -- positive value as a hard failure. -1 means "still loading".)
        if status ~= -1 and status ~= 0 then
            logger.warn("speakword/android-tts: engine init failed, status=", status)
            return false
        end

        os.execute("usleep 50000")  -- 50 ms
    end
    logger.warn("speakword/android-tts: engine init timed out after", timeout_ms, "ms")
    return false
end

-- ----------------------------------------------------------------------------
-- Provider methods
-- ----------------------------------------------------------------------------

--- Construct a new Android TTS provider. provider_settings may be empty —
--- this provider has no configuration knobs (the engine itself is configured
--- via the Android system settings UI).
--- @param provider_settings table
function AndroidTts.new(provider_settings)
    local self = setmetatable({}, AndroidTts)
    -- model_id is part of the cache fingerprint. The engine package isn't
    -- trivially exposed via TtsHelper (it would require another JNI call),
    -- but a stable string is all we need; if a user switches engines (e.g.
    -- com.google.android.tts -> Samsung TTS) and wants the cache invalidated
    -- they can set provider_settings.model_id = "android_<engine>" manually.
    self.model_id = (provider_settings and provider_settings.model_id)
        or "android_default"
    return self
end

--- List the voices the system TTS engine has installed.
--- Returns (true, voices_table) | (false, error_code[, detail]).
function AndroidTts:list_voices()
    if not Device:isAndroid() then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS provider only works on Android devices."
    end
    if not initTts() then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS engine could not be loaded. " ..
            "Check that a TTS engine (e.g. com.google.android.tts) is installed."
    end
    if not waitForEngineReady(INIT_TIMEOUT_MS) then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS engine did not finish initializing."
    end

    local android = _state.android
    local raw = android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local jstr = env[0].CallObjectMethod(env,
            _state.helper_ref, _state.method.listVoices)
        if checkException(env) then return nil end
        if jstr == nil then return nil end
        local s = jni:to_string(jstr)
        env[0].DeleteLocalRef(env, jstr)
        return s
    end)

    if raw == nil then
        return false, Errors.CODE.MALFORMED_RESPONSE,
            "TtsHelper.listVoices() threw or returned null."
    end

    local voices = {}
    -- Each row: name|displayLocale|languageTag
    -- We expose name as the id (stable across runs per Voice.getName() docs)
    -- and "displayLocale - shortName" as the human label. The shortName at
    -- the end disambiguates voices for the same language (e.g. multiple
    -- en-US voices on com.google.android.tts).
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            local name, disp, _tag = line:match("^([^|]*)|([^|]*)|([^|]*)$")
            if name and name ~= "" then
                local label
                if disp and disp ~= "" then
                    -- "English (United States) — en-us-x-iol-network"
                    label = disp .. " — " .. name
                else
                    label = name
                end
                table.insert(voices, { id = name, name = label })
            end
        end
    end
    table.sort(voices, function(a, b) return (a.name or "") < (b.name or "") end)

    if #voices == 0 then
        return false, Errors.CODE.MALFORMED_RESPONSE,
            "Android TTS engine reported no installed voices. " ..
            "Open the system TTS settings and download a voice pack."
    end

    return true, voices
end

--- Synthesize `text` to a WAV file via Android TTS, then read the bytes back.
--- Returns (true, audio_bytes) | (false, error_code[, detail]).
function AndroidTts:synthesize(text, voice_id)
    if not text or text == "" then
        return false, Errors.CODE.EMPTY_INPUT
    end
    if not voice_id or voice_id == "" then
        return false, Errors.CODE.NO_VOICE_SELECTED
    end
    if not Device:isAndroid() then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS provider only works on Android devices."
    end
    if not initTts() then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS engine could not be loaded."
    end
    if not waitForEngineReady(INIT_TIMEOUT_MS) then
        return false, Errors.CODE.NOT_CONFIGURED,
            "Android TTS engine did not finish initializing."
    end

    -- Best-effort: remove any stale temp file so a partial read can't be
    -- mistaken for a fresh synth result.
    os.remove(TEMP_WAV_PATH)

    local android = _state.android

    -- Dispatch the async synth.
    local dispatch_ok = android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_text  = env[0].NewStringUTF(env, text)
        local j_voice = env[0].NewStringUTF(env, voice_id)
        local j_path  = env[0].NewStringUTF(env, TEMP_WAV_PATH)
        local r = env[0].CallBooleanMethod(env,
            _state.helper_ref, _state.method.synthesizeToFile,
            j_text, j_voice, j_path)
        env[0].DeleteLocalRef(env, j_text)
        env[0].DeleteLocalRef(env, j_voice)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then return false end
        return r ~= 0
    end)

    if not dispatch_ok then
        return false, Errors.CODE.UNKNOWN,
            "TtsHelper.synthesizeToFile() refused the request " ..
            "(voice not found, file unwritable, or engine not ready)."
    end

    -- Poll for completion. The synth is genuinely asynchronous on the
    -- TTS engine's worker thread, so we have to poll. Same usleep cadence
    -- as the init wait.
    local deadline = nowMs() + SYNTH_TIMEOUT_MS
    local done, errored = false, false
    while nowMs() < deadline do
        local d, e = android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            local jd = env[0].CallBooleanMethod(env,
                _state.helper_ref, _state.method.isSynthesisDone)
            if checkException(env) then return true, true end
            if jd ~= 0 then
                local je = env[0].CallBooleanMethod(env,
                    _state.helper_ref, _state.method.wasSynthesisError)
                if checkException(env) then return true, true end
                return true, je ~= 0
            end
            return false, false
        end)
        done    = d
        errored = e
        if done then break end
        os.execute("usleep 50000")  -- 50 ms
    end

    if not done then
        return false, Errors.CODE.NETWORK,
            "Android TTS synthesis timed out. " ..
            "The engine may need a voice pack downloaded for offline use."
    end
    if errored then
        return false, Errors.CODE.UNKNOWN,
            "Android TTS engine reported a synthesis error " ..
            "(missing voice data, unsupported language, or engine bug)."
    end

    -- Read the WAV file the engine produced.
    local f, ferr = io.open(TEMP_WAV_PATH, "rb")
    if not f then
        return false, Errors.CODE.DISK,
            "Couldn't open synth output: " .. tostring(ferr)
    end
    local bytes = f:read("*a")
    f:close()

    if not bytes or #bytes == 0 then
        return false, Errors.CODE.EMPTY_RESPONSE
    end

    return true, bytes
end

return AndroidTts
