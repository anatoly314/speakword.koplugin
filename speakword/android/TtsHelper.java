/*
 * TtsHelper.java -- minimal Android TextToSpeech wrapper for the Speakword
 * KOReader plugin.
 *
 * Adapted (and stripped) from the TTS portion of
 * audiobook.koplugin's android/TtsHelper.java
 *   https://github.com/stradichenko/audiobook.koplugin
 *
 * Speakword's variant differs from audiobook's in two ways:
 *   1. Voice listing: TextToSpeech.getVoices() is exposed so the user can
 *      pick a voice in the settings UI (audiobook hardcodes Locale.US).
 *   2. No synth-then-play pipeline: the rest of speakword treats the audio
 *      as a byte buffer that the cache layer persists, so we only need
 *      synthesizeToFile + a poll-friendly done flag. MediaPlayer playback
 *      lives in AudioPlayer.java in the same .dex.
 *
 * Polling-friendly: callbacks update volatile fields that Lua reads via
 * isInitialized() / isSynthesisDone() / wasSynthesisError(), so the JNI
 * bridge does not need to implement Java listener interfaces.
 *
 * Copyright (C) 2026 Speakword contributors
 * Copyright (C) 2025 audiobook.koplugin contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package com.speakword;

import android.content.Context;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Wraps android.speech.tts.TextToSpeech for use from Lua over JNI.
 *
 * Lifecycle:
 *   1. ctor starts TextToSpeech construction (async; engine init runs on a
 *      background thread). Lua polls isInitialized() until true (or an init
 *      error is reported via initStatus).
 *   2. listVoices() returns name|locale|name newline-separated rows.
 *   3. synthesizeToFile(text, voiceName, outputPath) dispatches the synth
 *      request. Lua polls isSynthesisDone() and checks wasSynthesisError().
 *   4. shutdown() releases the engine.
 *
 * Voice "id" used by Lua is Voice.getName() — stable across reboots on a
 * given engine install (Android docs guarantee this).
 */
public class TtsHelper implements TextToSpeech.OnInitListener {

    private TextToSpeech tts;

    /** -1 = pending, 0 = TextToSpeech.SUCCESS, anything else = engine error. */
    private volatile int initStatus = -1;

    /**
     * Synth state machine:
     *   -1 = idle (no synth in flight)
     *    0 = synth dispatched, waiting for onDone/onError
     *    1 = onDone fired (success)
     *    2 = onError fired
     */
    private volatile int synthStatus = -1;

    public TtsHelper(Context context) {
        // Two-arg ctor: engine init runs async; onInit() will fire on success
        // or failure. If the constructor itself throws (no TTS service at
        // all on the device), we surface that as a fatal init error.
        try {
            tts = new TextToSpeech(context, this);
        } catch (Throwable t) {
            initStatus = TextToSpeech.ERROR;
            tts = null;
        }
    }

    @Override
    public void onInit(int status) {
        initStatus = status;
        if (status == TextToSpeech.SUCCESS && tts != null) {
            // Default to the system locale; the Lua side will override per
            // request via setVoice(). We only set this so synthesizeToFile()
            // works even before the user picks a voice (e.g. for a sanity
            // check on first run).
            try {
                tts.setLanguage(Locale.US);
            } catch (Throwable ignored) {}

            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override
                public void onStart(String utteranceId) {}

                @Override
                public void onDone(String utteranceId) {
                    synthStatus = 1;
                }

                @Override
                public void onError(String utteranceId) {
                    synthStatus = 2;
                }
            });
        }
    }

    /** True once the engine has reported successful initialization. */
    public boolean isInitialized() {
        return initStatus == TextToSpeech.SUCCESS && tts != null;
    }

    /**
     * -1 while the engine is loading, 0 on success, anything else
     * (TextToSpeech.ERROR == -1 in some SDKs but >0 in others) on failure.
     * Lua polls this together with isInitialized() to distinguish "still
     * waiting" from "permanently broken".
     */
    public int getInitStatus() {
        return initStatus;
    }

    /**
     * Return the installed voice list, one row per line:
     *   name|displayLocale|languageTag
     *
     * "name" is the stable Voice.getName() that should be passed back to
     * synthesizeToFile() as voiceName. "displayLocale" is human-readable
     * (e.g. "English (United States)"). "languageTag" is the BCP-47 tag
     * (e.g. "en-US"), useful for grouping in the picker UI.
     *
     * Returns an empty string when the engine isn't ready or has no voices.
     * Returns null on hard failure (Lua treats both as "no voices").
     */
    public String listVoices() {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) {
            return "";
        }
        Set<Voice> voiceSet;
        try {
            voiceSet = tts.getVoices();
        } catch (Throwable t) {
            return null;
        }
        if (voiceSet == null || voiceSet.isEmpty()) {
            return "";
        }

        List<Voice> voices = new ArrayList<>(voiceSet);
        StringBuilder sb = new StringBuilder();
        for (Voice v : voices) {
            if (v == null) continue;
            String name = v.getName();
            if (name == null || name.isEmpty()) continue;

            // Skip voices flagged as not-yet-installed network voices that
            // the engine knows about but cannot synthesize offline. They
            // would synth-error later anyway and confuse the picker.
            if (v.isNetworkConnectionRequired() && v.getFeatures() != null
                    && v.getFeatures().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) {
                continue;
            }

            Locale loc = v.getLocale();
            String displayLocale = loc != null ? loc.getDisplayName() : "";
            String tag = loc != null ? loc.toLanguageTag() : "";

            // Sanitize: row separator '\n' and column separator '|' must not
            // appear inside fields. Voice names are typically ASCII tokens
            // like "en-us-x-iol-network", but sanitize defensively anyway.
            sb.append(sanitize(name)).append('|')
              .append(sanitize(displayLocale)).append('|')
              .append(sanitize(tag)).append('\n');
        }
        return sb.toString();
    }

    private static String sanitize(String s) {
        if (s == null) return "";
        return s.replace('\n', ' ').replace('|', '_');
    }

    /**
     * Dispatch an async synthesis to the given file path. Returns true if
     * the request was accepted (TextToSpeech.SUCCESS), false on synchronous
     * failure (engine not ready, file unwritable, voice not found, ...).
     *
     * Lua polls isSynthesisDone() / wasSynthesisError() to wait for the
     * actual result — this method does not block.
     *
     * If voiceName is null or empty, the engine's current voice is used.
     */
    public boolean synthesizeToFile(String text, String voiceName, String outputPath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) return false;
        if (text == null || text.isEmpty()) return false;
        if (outputPath == null || outputPath.isEmpty()) return false;

        // Reset synth status BEFORE dispatch. If we did this after, a fast
        // engine could fire onDone before we set status=0 and Lua would see
        // a stale "done" from a previous call.
        synthStatus = 0;

        // Optional voice override.
        if (voiceName != null && !voiceName.isEmpty()) {
            Voice picked = null;
            try {
                Set<Voice> voices = tts.getVoices();
                if (voices != null) {
                    for (Voice v : voices) {
                        if (v != null && voiceName.equals(v.getName())) {
                            picked = v;
                            break;
                        }
                    }
                }
            } catch (Throwable ignored) {}
            if (picked == null) {
                synthStatus = 2;
                return false;
            }
            try {
                int r = tts.setVoice(picked);
                if (r != TextToSpeech.SUCCESS) {
                    synthStatus = 2;
                    return false;
                }
            } catch (Throwable t) {
                synthStatus = 2;
                return false;
            }
        }

        File outFile = new File(outputPath);
        File parent = outFile.getParentFile();
        if (parent != null && !parent.exists()) {
            try { parent.mkdirs(); } catch (Throwable ignored) {}
        }

        try {
            // Unique utterance ID per call: some engines silently drop the
            // onDone callback if the same ID is reused.
            String uttId = "speakword_" + System.currentTimeMillis()
                + "_" + System.nanoTime();
            int r = tts.synthesizeToFile(text, new Bundle(), outFile, uttId);
            if (r != TextToSpeech.SUCCESS) {
                synthStatus = 2;
                return false;
            }
            return true;
        } catch (Throwable t) {
            synthStatus = 2;
            return false;
        }
    }

    /** True if synthesis has finished (successfully OR with an error). */
    public boolean isSynthesisDone() {
        int s = synthStatus;
        return s == 1 || s == 2;
    }

    /** True if the most recent synthesis ended in an error. */
    public boolean wasSynthesisError() {
        return synthStatus == 2;
    }

    /** Release the TTS engine. Safe to call repeatedly. */
    public void shutdown() {
        if (tts != null) {
            try { tts.stop(); } catch (Throwable ignored) {}
            try { tts.shutdown(); } catch (Throwable ignored) {}
            tts = null;
        }
        initStatus = -1;
        synthStatus = -1;
    }
}
