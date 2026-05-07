-- speakword_settings: settings sub-menu builder.
--
-- Two settings live here:
--   * provider selection (only ElevenLabs for now, but the UI is generic)
--   * voice selection (fetched live from the provider's list_voices)
--
-- Selection persists across restarts via KOReader's LuaSettings store.
-- The voice list is fetched on demand (when the user opens the picker), not
-- at plugin init, so we never block startup on a network call.

local DataStorage      = require("datastorage")
local Menu             = require("ui/widget/menu")
local InfoMessage      = require("ui/widget/infomessage")
local NetworkMgr       = require("ui/network/manager")
local Trapper          = require("ui/trapper")
local UIManager        = require("ui/uimanager")
local logger           = require("logger")
local _                = require("gettext")
local T                = require("ffi/util").template

local Cache            = require("speakword/speakword_cache")
local Errors           = require("speakword/speakword_errors")
local Player           = require("speakword/speakword_player")
local ProviderRegistry = require("speakword/speakword_provider")

local Settings = {}

-- Sample sentence synthesized when the user taps a voice in the picker.
-- Kept short so the preview round-trip stays under a couple of seconds and
-- doesn't burn quota.
local PREVIEW_TEXT = "Let's make it speak"

-- Where the preview audio is written. Lives in koreader's cache dir (NOT the
-- per-book notes folder), and is overwritten on every preview, so it never
-- pollutes the user's library or grows unbounded.
--
-- The extension is appended at write time based on the actual audio bytes
-- (see Cache.audioExtensionFor). Android TTS emits WAV, ElevenLabs emits
-- MP3 — using the wrong extension makes Android MediaPlayer refuse the file.
local PREVIEW_PATH_PREFIX = DataStorage:getDataDir() .. "/cache/speakword-preview"

-- Settings keys. Centralized so the entry-point and the UI agree.
Settings.KEY = {
    PROVIDER      = "provider",
    VOICE_ID      = "voice_id",
    VOICE_NAME    = "voice_name",    -- cached for display only
    AUDIO_BACKEND = "audio_backend", -- "auto" | "intent"
    CACHE_ENABLED = "cache_enabled", -- boolean, default true
}

-- Display labels for audio_backend values. The actual key is what gets
-- persisted; the label is what the user sees.
local AUDIO_BACKEND_LABELS = {
    auto   = _("Auto (in-process on Android)"),
    intent = _("System intent (legacy)"),
}

-- Display labels for cache_enabled values. Same shape as AUDIO_BACKEND_LABELS
-- so the menu sub-item builder can reuse the same pattern.
local CACHE_ENABLED_LABELS = {
    [true]  = _("On (per-book folder)"),
    [false] = _("Off (ephemeral, not saved)"),
}

local function showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function showError(code, detail)
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = Errors.message(code, detail),
    })
end

--- Show a Menu listing each known provider and let the user pick one.
local function showProviderPicker(plugin, refresh_parent)
    local items = {}
    for key, display in pairs(ProviderRegistry.KNOWN) do
        table.insert(items, {
            text = display,
            callback = function()
                plugin.settings:saveSetting(Settings.KEY.PROVIDER, key)
                plugin.updated = true
                -- Changing provider invalidates the voice — clear it so the
                -- user is prompted to pick a new one.
                plugin.settings:delSetting(Settings.KEY.VOICE_ID)
                plugin.settings:delSetting(Settings.KEY.VOICE_NAME)
                if refresh_parent then refresh_parent() end
            end,
        })
    end
    table.sort(items, function(a, b) return (a.text or "") < (b.text or "") end)

    UIManager:show(Menu:new{
        title = _("TTS Provider"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    })
end

--- Build a provider instance with the user's currently selected provider key
--- and the loaded CONFIGURATION. Returns (provider, nil) or (nil, code).
local function buildProvider(plugin)
    if not plugin.CONFIGURATION then
        return nil, Errors.CODE.NOT_CONFIGURED
    end
    local key = plugin.settings:readSetting(Settings.KEY.PROVIDER)
        or plugin.CONFIGURATION.provider
    if not key then return nil, Errors.CODE.NOT_CONFIGURED end

    local provider, reason = ProviderRegistry.create(key, plugin.CONFIGURATION)
    if not provider then
        return nil, Errors.CODE.NOT_CONFIGURED, reason
    end
    return provider
end

--- Synthesize PREVIEW_TEXT in `voice_id` and play it. Writes the MP3 to a
--- single shared cache path (overwritten each call) so the per-book notes
--- folder isn't polluted with sample-sentence files. Failures are surfaced
--- via showError; selection-saving is the caller's job and runs regardless
--- of whether this succeeds.
local function previewVoice(provider, voice_id)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local progress = InfoMessage:new{ text = _("Synthesizing preview…") }
            UIManager:show(progress)
            UIManager:forceRePaint()

            local ok, audio_or_code, detail = provider:synthesize(PREVIEW_TEXT, voice_id)

            UIManager:close(progress)

            if not ok then
                return showError(audio_or_code, detail)
            end

            -- Write the audio bytes to our single preview slot. Binary mode
            -- matters on platforms where text mode mangles 0x0D bytes (MP3
            -- frames absolutely contain those).
            --
            -- Extension is derived from the bytes themselves so MediaPlayer
            -- doesn't reject e.g. an Android-TTS WAV saved as .mp3.
            local preview_path = PREVIEW_PATH_PREFIX
                .. Cache.audioExtensionFor(audio_or_code)
            local f, ferr = io.open(preview_path, "wb")
            if not f then
                logger.warn("speakword: preview open failed:", ferr)
                return showError(Errors.CODE.DISK, ferr)
            end
            f:write(audio_or_code)
            f:close()

            local played, perr = Player.play(preview_path)
            if not played then
                return showError(perr)
            end
        end)
    end)
end

--- Open the voice picker. Fetches the list from the provider on each open
--- (so a freshly added voice on the ElevenLabs dashboard appears without
--- restarting KOReader). Network call is wrapped in NetworkMgr + Trapper
--- so it doesn't freeze the UI on a slow Wi-Fi.
local function showVoicePicker(plugin, refresh_parent)
    local provider, code, detail = buildProvider(plugin)
    if not provider then
        return showError(code, detail)
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local info = InfoMessage:new{ text = _("Loading voices…") }
            UIManager:show(info)
            UIManager:forceRePaint()

            local ok, voices_or_code, detail2 = provider:list_voices()

            UIManager:close(info)

            if not ok then
                return showError(voices_or_code, detail2)
            end

            local voices = voices_or_code
            if #voices == 0 then
                return showInfo(_("This account has no voices."))
            end

            local items = {}
            for _, v in ipairs(voices) do
                table.insert(items, {
                    text = v.name,
                    callback = function()
                        -- Save + refresh the parent menu first so the user's
                        -- selection sticks even if the preview round-trip
                        -- fails (network drops, quota, etc.). The voice menu
                        -- itself closes automatically when this callback
                        -- returns (KOReader Menu default tap behavior).
                        plugin.settings:saveSetting(Settings.KEY.VOICE_ID, v.id)
                        plugin.settings:saveSetting(Settings.KEY.VOICE_NAME, v.name)
                        plugin.updated = true
                        if refresh_parent then refresh_parent() end

                        -- Then fire off the preview. Same provider instance
                        -- as the one we used to list voices — no need to
                        -- rebuild it.
                        previewVoice(provider, v.id)
                    end,
                })
            end

            UIManager:show(Menu:new{
                title = _("Select Voice"),
                item_table = items,
                is_popout = false,
                is_borderless = true,
            })
        end)
    end)
end

--- Read the current audio_backend setting, defaulting to "auto".
local function currentAudioBackend(plugin)
    local v = plugin.settings:readSetting(Settings.KEY.AUDIO_BACKEND)
    if v == "intent" then return "intent" end
    return "auto"
end

--- Read the current cache_enabled setting, defaulting to true. Exposed as a
--- module function so main.lua can branch on it without duplicating the
--- "default true if absent" rule.
function Settings.cacheEnabled(plugin)
    local v = plugin.settings:readSetting(Settings.KEY.CACHE_ENABLED)
    if v == nil then return true end
    return v and true or false
end

--- Build the list of menu rows that go under "Tools → Speakword".
--- Returned table is shaped for KOReader's TouchMenu (sub_item_table).
function Settings.genMenuItems(plugin)
    local items = {
        {
            text_func = function()
                local key = plugin.settings:readSetting(Settings.KEY.PROVIDER)
                    or (plugin.CONFIGURATION and plugin.CONFIGURATION.provider)
                local display = key and ProviderRegistry.KNOWN[key] or _("not configured")
                return T(_("Provider: %1"), display)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showProviderPicker(plugin, function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        },
        {
            text_func = function()
                local name = plugin.settings:readSetting(Settings.KEY.VOICE_NAME)
                return T(_("Voice: %1"), name or _("(none selected)"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showVoicePicker(plugin, function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        },
        {
            -- Audio backend toggle. "Auto" is the default and tries the
            -- in-process MediaPlayer wrapper on Android (falling back to a
            -- system intent on failure). "Intent" forces the original
            -- Device:openLink path — useful as a debugging escape hatch or
            -- on Android devices where in-process audio misbehaves.
            text_func = function()
                local key = currentAudioBackend(plugin)
                local label = AUDIO_BACKEND_LABELS[key] or key
                return T(_("Audio backend: %1"), label)
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                local function makeOption(value)
                    return {
                        text = AUDIO_BACKEND_LABELS[value] or value,
                        checked_func = function()
                            return currentAudioBackend(plugin) == value
                        end,
                        callback = function()
                            plugin.settings:saveSetting(
                                Settings.KEY.AUDIO_BACKEND, value)
                            plugin.updated = true
                        end,
                    }
                end
                return {
                    makeOption("auto"),
                    makeOption("intent"),
                }
            end,
        },
        {
            -- Cache toggle. On (default) keeps the existing per-book cache
            -- behavior — every synthesized clip is saved next to the book and
            -- replayed instantly on a re-tap. Off uses a single ephemeral
            -- file under koreader's cache dir, overwritten on every Speak,
            -- so nothing accumulates in the user's library folder.
            text_func = function()
                local enabled = Settings.cacheEnabled(plugin)
                local label = CACHE_ENABLED_LABELS[enabled]
                return T(_("Cache audio per book: %1"), label)
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                local function makeOption(value)
                    return {
                        text = CACHE_ENABLED_LABELS[value],
                        checked_func = function()
                            return Settings.cacheEnabled(plugin) == value
                        end,
                        callback = function()
                            plugin.settings:saveSetting(
                                Settings.KEY.CACHE_ENABLED, value)
                            plugin.updated = true
                        end,
                    }
                end
                return {
                    makeOption(true),
                    makeOption(false),
                }
            end,
        },
        {
            text = _("About Speakword"),
            keep_menu_open = true,
            callback = function()
                local meta = plugin.meta or {}
                showInfo(T("%1 %2\n\n%3",
                    meta.fullname or "Speakword",
                    meta.version or "",
                    meta.description or ""))
            end,
        },
    }
    return items
end

return Settings
