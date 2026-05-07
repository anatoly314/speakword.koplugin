--[[--
speakword_player: play an MP3 file.

On Android, plays in-process via a small bundled `.dex` (com.speakword.AudioPlayer)
loaded through DexClassLoader and called via JNI. This avoids the system music
player overlay and the need for an `audio/mpeg` Intent handler — useful on
devices like the Boox Note X5 that ship without a registered media app.

On other platforms (desktop Linux dev builds, Kobo, Kindle), and when the
`audio_backend` setting is set to "intent", it falls back to the original
`Device:openLink("file://"..path)` Intent dispatch.

The JNI plumbing (DexClassLoader bootstrap, method-id caching, GlobalRef
lifetime management) is adapted from
  https://github.com/stradichenko/audiobook.koplugin (AGPL-3.0)
specifically `androidtts.lua`'s init sequence.

Copyright (C) 2026 Speakword contributors
Copyright (C) 2025 audiobook.koplugin contributors

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, version 3 of the License, or (at your
option) any later version.
--]]--

local Device      = require("device")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")
local Errors      = require("speakword/speakword_errors")

local Player = {}

-- Settings key shared with speakword_settings.lua. Duplicated here to avoid
-- a circular require with speakword_settings.lua (which itself loads UI bits).
local KEY_AUDIO_BACKEND = "audio_backend"
local SETTINGS_FILE     = DataStorage:getSettingsDir() .. "/speakword.lua"

-- Path to the precompiled .dex helper, relative to this module's plugin dir.
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/speakword.koplugin"
local DEX_PATH   = PLUGIN_DIR .. "/speakword/android/audio_helper.dex"

-- Module-scope JNI cache — lazily populated on first Android playback.
local _android_state = {
    initialized   = false,   -- true once the helper class+instance are ready
    failed        = false,   -- true once init has irrecoverably failed
    helper_ref    = nil,     -- JNI GlobalRef to AudioPlayer instance
    helper_class  = nil,     -- JNI GlobalRef to AudioPlayer class
    method        = {},      -- cached jmethodID values
    android       = nil,     -- the `android` Lua module
}

-- ----------------------------------------------------------------------------
-- Settings access
-- ----------------------------------------------------------------------------

--- Read the `audio_backend` setting. Returns one of "auto" or "intent".
--- Defaults to "auto".
local function readAudioBackend()
    local ok, settings = pcall(function()
        return LuaSettings:open(SETTINGS_FILE)
    end)
    if not ok or not settings then return "auto" end
    local v = settings:readSetting(KEY_AUDIO_BACKEND)
    if v == "intent" then return "intent" end
    return "auto"
end

-- ----------------------------------------------------------------------------
-- Intent fallback
-- ----------------------------------------------------------------------------

--- Hand the file off to the OS via an ACTION_VIEW intent. The Boox Note X5
--- has no `audio/mpeg` handler so this silently does nothing on that device,
--- which is precisely why the in-process backend exists. Other platforms
--- (desktop xdg-open, Kindle, Kobo) generally do honor it.
local function playViaIntent(path)
    if not Device.canOpenLink or not Device:canOpenLink() then
        logger.warn("speakword_player: openLink unavailable on this platform")
        return false, Errors.CODE.PLAYBACK
    end
    local uri = "file://" .. path
    local ok, err = pcall(function() Device:openLink(uri) end)
    if not ok then
        logger.warn("speakword_player: openLink threw", err)
        return false, Errors.CODE.PLAYBACK
    end
    return true
end

-- ----------------------------------------------------------------------------
-- Android in-process backend
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

--- Lazy initialization of the Android in-process player. Loads the .dex via
--- DexClassLoader, instantiates `com.speakword.AudioPlayer`, and caches
--- method IDs + GlobalRefs. Returns true on success, false on failure (in
--- which case `_android_state.failed` is set to short-circuit retries).
local function initAndroid()
    if _android_state.initialized then return true end
    if _android_state.failed then return false end

    local ok, android = pcall(require, "android")
    if not ok then
        logger.warn("speakword_player: cannot load android module:", android)
        _android_state.failed = true
        return false
    end
    _android_state.android = android

    -- Sanity check: .dex shipped with the plugin?
    local f = io.open(DEX_PATH, "r")
    if not f then
        logger.warn("speakword_player: audio_helper.dex not found at", DEX_PATH)
        _android_state.failed = true
        return false
    end
    f:close()

    -- DexClassLoader needs an output dir for its optimized dex cache. Use the
    -- app cache dir, retrieved from the activity's Context via JNI.
    local cache_dir = android.jni:context(android.app.activity.vm, function(jni)
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
    if not cache_dir then
        logger.warn("speakword_player: cannot resolve cache dir")
        _android_state.failed = true
        return false
    end

    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env

        -- 1. Activity ClassLoader (the parent for our DexClassLoader).
        local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
        if checkException(env) or ctx_class == nil then
            logger.warn("speakword_player: GetObjectClass(activity) failed")
            return
        end
        local get_cl_id = env[0].GetMethodID(env, ctx_class,
            "getClassLoader", "()Ljava/lang/ClassLoader;")
        env[0].DeleteLocalRef(env, ctx_class)
        if checkException(env) or get_cl_id == nil then
            logger.warn("speakword_player: getClassLoader methodID missing")
            return
        end
        local parent_cl = env[0].CallObjectMethod(env,
            android.app.activity.clazz, get_cl_id)
        if checkException(env) or parent_cl == nil then
            logger.warn("speakword_player: getClassLoader returned null")
            return
        end

        -- 2. DexClassLoader pointing at our .dex.
        local dcl_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        if checkException(env) or dcl_class == nil then
            logger.warn("speakword_player: DexClassLoader not found")
            env[0].DeleteLocalRef(env, parent_cl)
            return
        end
        local dcl_init = env[0].GetMethodID(env, dcl_class, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        if checkException(env) or dcl_init == nil then
            logger.warn("speakword_player: DexClassLoader.<init> missing")
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
            logger.warn("speakword_player: DexClassLoader instantiation failed")
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        -- 3. Resolve loadClass() on the DexClassLoader and load AudioPlayer.
        local load_class_id = env[0].GetMethodID(env, dcl_class,
            "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        env[0].DeleteLocalRef(env, dcl_class)
        if checkException(env) or load_class_id == nil then
            logger.warn("speakword_player: loadClass methodID missing")
            env[0].DeleteLocalRef(env, dcl_obj)
            return
        end
        local j_class_name = env[0].NewStringUTF(env, "com.speakword.AudioPlayer")
        local helper_class = env[0].CallObjectMethod(env,
            dcl_obj, load_class_id, j_class_name)
        env[0].DeleteLocalRef(env, j_class_name)
        env[0].DeleteLocalRef(env, dcl_obj)
        if checkException(env) or helper_class == nil then
            logger.warn("speakword_player: AudioPlayer class not found in .dex")
            return
        end

        -- 4. Instantiate AudioPlayer(Context).
        local helper_init = env[0].GetMethodID(env, helper_class,
            "<init>", "(Landroid/content/Context;)V")
        if checkException(env) or helper_init == nil then
            logger.warn("speakword_player: AudioPlayer.<init>(Context) missing")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end
        local helper_obj = env[0].NewObject(env, helper_class, helper_init,
            android.app.activity.clazz)
        if checkException(env) or helper_obj == nil then
            logger.warn("speakword_player: AudioPlayer instantiation failed")
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 5. Cache method IDs.
        _android_state.method.playFile = env[0].GetMethodID(env, helper_class,
            "playFile", "(Ljava/lang/String;)I")
        _android_state.method.stopPlayback = env[0].GetMethodID(env, helper_class,
            "stopPlayback", "()V")
        _android_state.method.isPlaying = env[0].GetMethodID(env, helper_class,
            "isPlaying", "()Z")
        _android_state.method.isPlaybackDone = env[0].GetMethodID(env, helper_class,
            "isPlaybackDone", "()Z")
        if checkException(env)
                or _android_state.method.playFile == nil
                or _android_state.method.stopPlayback == nil
                or _android_state.method.isPlaying == nil
                or _android_state.method.isPlaybackDone == nil then
            logger.warn("speakword_player: failed to resolve AudioPlayer method IDs")
            env[0].DeleteLocalRef(env, helper_obj)
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- 6. Promote refs to GlobalRefs so they outlive this JNI context.
        _android_state.helper_ref   = env[0].NewGlobalRef(env, helper_obj)
        _android_state.helper_class = env[0].NewGlobalRef(env, helper_class)
        env[0].DeleteLocalRef(env, helper_obj)
        env[0].DeleteLocalRef(env, helper_class)

        load_ok = true
        logger.dbg("speakword_player: AudioPlayer loaded from .dex")
    end)

    if not load_ok then
        _android_state.failed = true
        return false
    end
    _android_state.initialized = true
    return true
end

--- Play a file via the in-process Android MediaPlayer wrapper.
--- Returns (true) on dispatch, (false, code) on failure.
local function playViaAndroid(path)
    if not initAndroid() then
        return false, Errors.CODE.PLAYBACK
    end

    local android = _android_state.android
    local result = android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local j_path = env[0].NewStringUTF(env, path)
        local r = env[0].CallIntMethod(env,
            _android_state.helper_ref, _android_state.method.playFile, j_path)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.warn("speakword_player: playFile threw a JNI exception")
            return -1
        end
        return r
    end)

    if not result or result < 0 then
        logger.warn("speakword_player: AudioPlayer.playFile returned", result)
        return false, Errors.CODE.PLAYBACK
    end
    logger.dbg("speakword_player: playing", path, "duration ms =", result)
    return true
end

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

--- Play an audio file at `path`. Returns (true) on dispatch, (false, code)
--- on failure. Backend selection follows the `audio_backend` setting
--- ("auto" — Android in-process if available, else intent; "intent" —
--- always intent).
function Player.play(path)
    if not path or path == "" then
        return false, Errors.CODE.PLAYBACK
    end

    local backend = readAudioBackend()

    if backend ~= "intent" and Device:isAndroid() then
        local ok, code = playViaAndroid(path)
        if ok then return true end
        -- Fall through to intent on Android failure (only in auto mode).
        logger.info("speakword_player: in-process playback failed (",
            code, "), falling back to intent")
    end

    return playViaIntent(path)
end

return Player
