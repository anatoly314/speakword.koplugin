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
        // App-private cache dir. We copy each playback source here before
        // handing the FD to MediaPlayer -- see playFile() for why.
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
                // Copy the source file into our app-private cache dir before
                // playing it. Why: even when we open() the file ourselves and
                // hand MediaPlayer the resulting FD, MediaPlayer forwards it
                // over Binder IPC to the system audioserver, which then runs
                // its own SELinux/MAC check against the file's underlying
                // inode label. On Android 13 / Boox, files in shared storage
                // (/storage/emulated/0/...) carry a label audioserver isn't
                // allowed to read, so setDataSource() fails with
                // "setDataSourceFD failed.: status=0x80000000" for both MP3
                // and WAV inputs that ffmpeg / desktop players accept fine.
                // Files inside Context.getCacheDir() (app-private storage)
                // carry a label audioserver IS allowed to read, so the same
                // MediaPlayer call succeeds. The reference plugin
                // stradichenko/audiobook.koplugin works on Boox precisely
                // because it writes all TTS output straight into
                // getCacheDir(); we keep our user-visible per-book cache as
                // designed and just stage a copy here for playback.
                //
                // Single slot, overwritten each call -- we only ever play
                // one clip at a time, so there's no need for unique names.
                File copy = new File(cacheDir, "speakword-play.tmp");
                copyFile(new File(path), copy);

                mediaPlayer = new MediaPlayer();
                FileInputStream fis = new FileInputStream(copy);
                try {
                    mediaPlayer.setDataSource(fis.getFD());
                } finally {
                    try { fis.close(); } catch (IOException ignored) {}
                }
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
