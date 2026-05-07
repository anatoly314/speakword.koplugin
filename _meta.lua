-- Plugin metadata. KOReader reads this when scanning for plugins.
local _ = require("gettext")
return {
    name = "speakword",
    fullname = _("Speakword TTS"),
    description = _("Pronounce selected words and sentences via cloud TTS (ElevenLabs)."),
    version = "0.1.0",
}
