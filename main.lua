-- speakword.koplugin — main entry point.
--
-- Responsibilities:
--   1. Load configuration.lua (user-supplied, gitignored) safely.
--   2. Open per-plugin LuaSettings for user-mutable preferences.
--   3. Register a "Speakword" entry under Tools menu.
--   4. Hook the dictionary popup (onDictButtonsReady) and add a "Speak" button
--      on its OWN row, separate from the row assistant.koplugin uses.
--   5. Hook the highlight dialog (addToHighlightDialog) so phrases and
--      sentences can also be spoken.
--   6. Orchestrate Speak: cache lookup -> synthesize -> write -> play, with
--      every failure path mapped to a clear user-facing message.
--
-- Patterns adapted (NOT copied) from
--   https://github.com/omer-faruq/assistant.koplugin
-- — credit also in README.

local Device          = require("device")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings     = require("luasettings")
local NetworkMgr   = require("ui/network/manager")
local Trapper      = require("ui/trapper")
local UIManager    = require("ui/uimanager")
local logger       = require("logger")
local _            = require("gettext")
local T            = require("ffi/util").template

local SettingsUI       = require("speakword/speakword_settings")
local Cache            = require("speakword/speakword_cache")
local Player           = require("speakword/speakword_player")
local Errors           = require("speakword/speakword_errors")
local ProviderRegistry = require("speakword/speakword_provider")

-- Per-document-instance state container. KOReader instantiates the plugin
-- fresh each time a book is opened, so anything we want to keep between
-- opens has to live in `self.settings` (LuaSettings) or the user's
-- configuration.lua.
local Speakword = WidgetContainer:extend{
    name = "speakword",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/speakword.lua",
    settings = nil,
    meta = nil,
    CONFIGURATION = nil,
    config_load_error = nil,
    updated = false, -- LuaSettings flush gate (see onFlushSettings)
}

-- ------------------------------------------------------------------------
-- Configuration loading
-- ------------------------------------------------------------------------

local PLUGIN_DIR    = T("%1/plugins/speakword.koplugin/", DataStorage:getDataDir())
local CONFIG_PATH   = PLUGIN_DIR .. "configuration.lua"
local META_PATH     = PLUGIN_DIR .. "_meta.lua"

-- Throwaway path used when the user has turned caching off. Lives in
-- koreader's cache dir (never inside the per-book folder) and is overwritten
-- on every Speak so it can't accumulate.
local EPHEMERAL_PATH = DataStorage:getDataDir() .. "/cache/speakword-ephemeral.mp3"

--- Load the user's configuration.lua. If it's missing or syntactically
--- broken, we don't crash — we record the error and surface it through
--- isConfigured() so the UI can guide the user to fix it.
local function loadConfiguration()
    local f = io.open(CONFIG_PATH, "r")
    if not f then
        return nil, _("configuration.lua not found. Copy configuration.sample.lua to configuration.lua and add your API key.")
    end
    f:close()

    -- pcall around dofile so a bad config file doesn't take down KOReader.
    local ok, result = pcall(function() return dofile(CONFIG_PATH) end)
    if not ok then
        return nil, T(_("configuration.lua failed to load:\n%1"), tostring(result))
    end
    if type(result) ~= "table" then
        return nil, _("configuration.lua must return a table.")
    end
    return result
end

-- ------------------------------------------------------------------------
-- Lifecycle
-- ------------------------------------------------------------------------

function Speakword:init()
    -- Read our metadata file so the About menu and provider-mismatch error
    -- messages can show a real version string.
    local meta_ok, meta = pcall(dofile, META_PATH)
    self.meta = meta_ok and meta or { name = "speakword", fullname = "Speakword TTS", version = "?" }

    self.settings = LuaSettings:open(self.settings_file)

    local config, err = loadConfiguration()
    if config then
        self.CONFIGURATION = config
    else
        self.config_load_error = err
        logger.warn("speakword: configuration not loaded:", err)
    end

    -- Tools menu (filemanager + reader) and reader-only highlight hook.
    self.ui.menu:registerToMainMenu(self)

    if self.ui.document and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("speakword_speak", function(_reader_highlight_instance)
            return {
                text = _("Speak"),
                enabled = self:_canSpeak(),
                callback = function()
                    local sel = _reader_highlight_instance.selected_text
                    local text = sel and sel.text or nil
                    self:speak(text)
                end,
            }
        end)
    end
end

--- Called by KOReader when the menu manager assembles the tools list.
function Speakword:addToMainMenu(menu_items)
    menu_items.speakword = {
        text = self.meta.fullname or _("Speakword TTS"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return SettingsUI.genMenuItems(self)
        end,
    }
end

--- KOReader calls this on shutdown / book close. Only flush if something
--- actually changed; flushing on every close churns the SD card needlessly.
function Speakword:onFlushSettings()
    if self.updated and self.settings then
        self.settings:flush()
        self.updated = false
    end
end

-- ------------------------------------------------------------------------
-- Dictionary popup integration
-- ------------------------------------------------------------------------

--- Event handler dispatched by ReaderDictionary / DictQuickLookup just
--- before the popup paints its buttons. We add a NEW BOTTOM ROW with a
--- single "Speak" button so we don't visually collide with assistant.koplugin
--- (which inserts at row index 2).
---
--- `dict_buttons` is a list of rows; each row is a list of button specs.
function Speakword:onDictButtonsReady(dict_popup, dict_buttons)
    if not dict_popup or type(dict_buttons) ~= "table" then return end

    local enabled = self:_canSpeak()
    local row = {
        {
            id        = "speakword_speak",
            text      = _("Speak"),
            enabled   = enabled,
            font_bold = true,
            callback  = function()
                self:speak(dict_popup.word)
            end,
        },
    }

    -- Append as a new last row. Putting it after assistant.koplugin's
    -- inserted row (index 2) keeps the two plugins visually distinct.
    table.insert(dict_buttons, row)
end

-- ------------------------------------------------------------------------
-- Speak orchestration
-- ------------------------------------------------------------------------

--- True when we have enough config + state to attempt a synthesize.
--- Used to grey out the Speak button instead of letting the user tap a
--- doomed action.
function Speakword:_canSpeak()
    if self.config_load_error or not self.CONFIGURATION then return false end
    return Device.canOpenLink and Device:canOpenLink() or false
end

--- Build a provider instance from current settings + configuration.
--- Returns (provider) or (nil, error_code, detail).
function Speakword:_currentProvider()
    if not self.CONFIGURATION then
        return nil, Errors.CODE.NOT_CONFIGURED, self.config_load_error
    end
    local key = self.settings:readSetting(SettingsUI.KEY.PROVIDER)
        or self.CONFIGURATION.provider
    if not key then
        return nil, Errors.CODE.NOT_CONFIGURED
    end
    local provider, reason = ProviderRegistry.create(key, self.CONFIGURATION)
    if not provider then
        return nil, Errors.CODE.NOT_CONFIGURED, reason
    end
    return provider, nil, key
end

local function showError(code, detail)
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = Errors.message(code, detail),
    })
end

--- The public action. Called from the dict popup, the highlight dialog, or
--- (in the future) a gesture binding. Handles cache hit, cache miss, and
--- every failure path with a specific user message.
---
--- `text` is the word/phrase/sentence to speak.
function Speakword:speak(text)
    if not text or text == "" then
        return showError(Errors.CODE.EMPTY_INPUT)
    end

    if self.config_load_error then
        return showError(Errors.CODE.NOT_CONFIGURED, self.config_load_error)
    end

    local voice_id = self.settings:readSetting(SettingsUI.KEY.VOICE_ID)
    if not voice_id or voice_id == "" then
        return showError(Errors.CODE.NO_VOICE_SELECTED)
    end

    local provider, code, detail = self:_currentProvider()
    if not provider then
        return showError(code, detail)
    end

    local cache_enabled = SettingsUI.cacheEnabled(self)

    -- Cache hit: skip the network entirely. Only consulted when caching is on
    -- — with caching off, we have no per-book file to look up.
    if cache_enabled then
        local hit, cached_path = Cache.exists(self.ui, text, voice_id, provider.model_id)
        if hit then
            local ok, perr = Player.play(cached_path)
            if not ok then return showError(perr) end
            return
        end
    end

    -- Cache miss (or caching disabled): synthesize. Wrapped in NetworkMgr so
    -- the user gets a proper "turn on Wi-Fi?" prompt on a fresh boot, and
    -- Trapper so in-flight calls can be cancelled by the user.
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local progress = InfoMessage:new{ text = _("Synthesizing speech…") }
            UIManager:show(progress)
            UIManager:forceRePaint()

            local ok, audio_or_code, detail2 = provider:synthesize(text, voice_id)

            UIManager:close(progress)

            if not ok then
                return showError(audio_or_code, detail2)
            end

            local audio_bytes = audio_or_code
            local play_path

            if cache_enabled then
                -- Persistent per-book cache.
                local saved_ok, path_or_code = Cache.write(
                    self.ui, text, voice_id, provider.model_id, audio_bytes)
                if not saved_ok then
                    return showError(path_or_code)
                end
                play_path = path_or_code
            else
                -- Ephemeral path: single shared slot, overwritten each call.
                -- Binary mode matters on platforms where text mode mangles
                -- 0x0D bytes (MP3 frames absolutely contain those).
                local f, ferr = io.open(EPHEMERAL_PATH, "wb")
                if not f then
                    logger.warn("speakword: ephemeral open failed:", ferr)
                    return showError(Errors.CODE.DISK, ferr)
                end
                local ok_write, write_err = pcall(function()
                    f:write(audio_bytes)
                end)
                f:close()
                if not ok_write then
                    logger.warn("speakword: ephemeral write failed:", write_err)
                    os.remove(EPHEMERAL_PATH)
                    return showError(Errors.CODE.DISK, write_err)
                end
                play_path = EPHEMERAL_PATH
            end

            local played, perr = Player.play(play_path)
            if not played then
                return showError(perr)
            end
        end)
    end)
end

return Speakword
