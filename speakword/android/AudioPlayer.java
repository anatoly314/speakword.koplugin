/*
 * AudioPlayer.java -- minimal MediaPlayer wrapper for the Speakword
 * KOReader plugin.
 *
 * Adapted (and stripped) from the MediaPlayer portion of
 * audiobook.koplugin's android/TtsHelper.java
 *   https://github.com/stradichenko/audiobook.koplugin
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
import android.media.AudioManager;
import android.media.MediaPlayer;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Minimal MediaPlayer wrapper for in-process MP3 playback.
 *
 * Polling-friendly: callbacks update volatile fields that Lua reads via
 * isPlaying() / isPlaybackDone(), so the JNI bridge does not need to
 * implement Java listener interfaces.
 *
 * Audio focus is requested per-clip and abandoned on completion or stop.
 */
public class AudioPlayer {

    private final Object mpLock = new Object();
    private MediaPlayer mediaPlayer;
    private volatile boolean playbackDone = false;
    private final AudioManager audioManager;
    private final File cacheDir;

    public AudioPlayer(Context context) {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        // App-private cache dir. We stage each playback source here so we can
        // give MediaPlayer a path with the right extension -- see playFile()
        // for why.
        cacheDir = context.getCacheDir();
    }

    /**
     * Play an audio file (MP3, WAV, etc.) through the default audio output.
     * Stops any current playback first. Returns the duration in ms, or
     * -1 on error.
     */
    public int playFile(String path) {
        stopPlayback();
        playbackDone = false;
        requestAudioFocus();
        synchronized (mpLock) {
            try {
                // Stage the source into our app-private cache dir under a
                // name with the correct extension, then hand MediaPlayer the
                // String absolute path. Why both:
                //
                // 1) Extension matters. On Android 13 / Boox, the stripped
                //    MediaExtractor uses the FILENAME EXTENSION as a hint
                //    when sniffing the container format. Without an
                //    extension (or with the wrong one) it can fail to pick
                //    an extractor and rejects the data source with
                //    "setDataSourceFD failed.: status=0x80000000". We sniff
                //    the magic bytes here and stage as .mp3 / .wav / .ogg
                //    accordingly so the extractor has the hint it needs.
                //
                // 2) String path, not FD. The reference plugin
                //    stradichenko/audiobook.koplugin (verified working on
                //    Android Boox) uses the String overload of
                //    setDataSource(); the FD overload route was the
                //    original culprit on this device. Stick to String.
                //
                // Single slot per extension, overwritten each call -- we
                // only ever play one clip at a time, so there's no need for
                // unique names.
                String ext = sniffExtension(new File(path));
                File copy = new File(cacheDir, "speakword-play" + ext);
                copyFile(new File(path), copy);

                mediaPlayer = new MediaPlayer();
                mediaPlayer.setDataSource(copy.getAbsolutePath());
                mediaPlayer.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                    @Override
                    public void onCompletion(MediaPlayer mp) {
                        playbackDone = true;
                        abandonAudioFocus();
                    }
                });
                mediaPlayer.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                    @Override
                    public boolean onError(MediaPlayer mp, int what, int extra) {
                        playbackDone = true;
                        abandonAudioFocus();
                        return true;
                    }
                });
                mediaPlayer.prepare();
                mediaPlayer.start();
                return mediaPlayer.getDuration();
            } catch (java.io.FileNotFoundException e) {
                playbackDone = true;
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            } catch (Exception e) {
                playbackDone = true;
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            }
        }
    }

    /** True if audio is currently playing. */
    public boolean isPlaying() {
        synchronized (mpLock) {
            try {
                return mediaPlayer != null && mediaPlayer.isPlaying();
            } catch (IllegalStateException e) {
                return false;
            }
        }
    }

    /** True once playback has completed (normally or by error). */
    public boolean isPlaybackDone() {
        return playbackDone;
    }

    /** Stop and release the MediaPlayer. Safe to call repeatedly. */
    public void stopPlayback() {
        synchronized (mpLock) {
            if (mediaPlayer != null) {
                // Clear listeners BEFORE release to avoid callbacks firing
                // on the internal thread after the native object is torn
                // down (which would deadlock or crash).
                mediaPlayer.setOnCompletionListener(null);
                mediaPlayer.setOnErrorListener(null);
                try {
                    if (mediaPlayer.isPlaying()) {
                        mediaPlayer.stop();
                    }
                } catch (IllegalStateException ignored) {}
                try {
                    mediaPlayer.release();
                } catch (Exception ignored) {}
                mediaPlayer = null;
            }
            playbackDone = false;
        }
        abandonAudioFocus();
    }

    /**
     * Peek the first 4 bytes of src and pick a filename extension based on
     * well-known magic bytes. The Boox / Android 13 MediaExtractor uses the
     * extension as a sniffing hint -- handing it a generic ".tmp" or no
     * extension causes setDataSource() to fail with status=0x80000000.
     *
     * Returns the extension including the leading dot. Falls back to
     * ".audio" for unknown payloads (any extension that survives the
     * extractor's MIME guess is fine; this just keeps the staged filename
     * non-empty for debugging).
     */
    private static String sniffExtension(File src) {
        byte[] head = new byte[4];
        InputStream in = null;
        try {
            in = new FileInputStream(src);
            int read = 0;
            while (read < head.length) {
                int n = in.read(head, read, head.length - read);
                if (n <= 0) break;
                read += n;
            }
            if (read >= 3
                    && head[0] == (byte) 0x49   // 'I'
                    && head[1] == (byte) 0x44   // 'D'
                    && head[2] == (byte) 0x33) { // '3'
                return ".mp3";
            }
            if (read >= 2
                    && head[0] == (byte) 0xFF
                    && (head[1] == (byte) 0xFB
                        || head[1] == (byte) 0xF3
                        || head[1] == (byte) 0xF2)) {
                return ".mp3";
            }
            if (read >= 4
                    && head[0] == (byte) 0x52   // 'R'
                    && head[1] == (byte) 0x49   // 'I'
                    && head[2] == (byte) 0x46   // 'F'
                    && head[3] == (byte) 0x46) { // 'F'
                return ".wav";
            }
            if (read >= 4
                    && head[0] == (byte) 0x4F   // 'O'
                    && head[1] == (byte) 0x67   // 'g'
                    && head[2] == (byte) 0x67   // 'g'
                    && head[3] == (byte) 0x53) { // 'S'
                return ".ogg";
            }
        } catch (IOException ignored) {
            // fall through to default
        } finally {
            if (in != null) {
                try { in.close(); } catch (IOException ignored) {}
            }
        }
        return ".audio";
    }

    /**
     * Byte-copy src to dst, overwriting dst if present. Tiny helper -- the
     * audio clips we play are ~10-100 KB each, so a plain stream copy is
     * fine; we don't need NIO or memory mapping here.
     */
    private static void copyFile(File src, File dst) throws IOException {
        InputStream in = new FileInputStream(src);
        try {
            OutputStream out = new FileOutputStream(dst);
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                out.flush();
            } finally {
                try { out.close(); } catch (IOException ignored) {}
            }
        } finally {
            try { in.close(); } catch (IOException ignored) {}
        }
    }

    @SuppressWarnings("deprecation")
    private void requestAudioFocus() {
        if (audioManager != null) {
            audioManager.requestAudioFocus(null,
                AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager != null) {
            audioManager.abandonAudioFocus(null);
        }
    }
}
