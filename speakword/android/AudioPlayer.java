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

    public AudioPlayer(Context context) {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
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
                mediaPlayer = new MediaPlayer();
                // Open the file in our own process and hand MediaPlayer a
                // FileDescriptor instead of a path. The String overload
                // routes through Android's storage permission system, which
                // on Android 13 (scoped storage / SELinux) blocks
                // MediaPlayer's separate process from reading some
                // app-public paths under /storage/emulated/0/... and fails
                // with "setDataSourceFD failed.: status=0x80000000".
                // Passing an FD we already opened bypasses that check --
                // MediaPlayer dup()s the FD internally, so closing our
                // FileInputStream after setDataSource is safe.
                java.io.FileInputStream fis = new java.io.FileInputStream(path);
                try {
                    mediaPlayer.setDataSource(fis.getFD());
                } finally {
                    try { fis.close(); } catch (java.io.IOException ignored) {}
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
