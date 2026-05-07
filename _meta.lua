-- Plugin metadata. KOReader reads this when scanning for plugins.
local _ = require("gettext")
return {
    name = "speakword",
    fullname = _("Speakword TTS"),
    description = _("Speak selected words and sentences via TTS. Default: Android system TTS (free, offline). Optional: ElevenLabs (premium cloud voices).\n\nCreated by Anatoly Tarnavsky\nhttps://anatoly.dev\nhttps://github.com/anatoly314/speakword.koplugin"),
    version = "0.2.0",
}
