# PiratePC
A fully automated stream/music player, sound processor, web stream & MPX generator for radio purposes - using ONLY FFmpeg and mpxgen.

 Features:
- Tmux terminal that runs in the background so that the SSH connection can be closed (reconnecting to the terminal possible)
- Restart the script/try to reconnect to the web stream by pressing "x"
- Tries to connect to a web stream: If successful, the stream is processed if desired and multiplexed (5 connection attempts with a 3 second break inbetween)
- 4 modes:
    “webstream”           = Webstream capture + FFmpeg fallback (default)
    “auto”                = FFmpeg fallback only (full auto mode)
    “soundcard”           = Capture sound card only (ALSA)
    “soundcard+fallback”  = Capture sound card (ALSA) + FFmpeg fallback

- Custom fallback audio player using ONLY FFmpeg: Automatic creation of playlists using a specified folder containing audio files AND/OR .m3u/.m3u8 files, streaming the signal to an Icecast server
- Playback of jingles in a separate folder every X songs with a shorter, customizable crossfade
- Separate volume settings for stream and MPX
- Basic sound processing with all standard features (EQ, crystallizer, stereo widening, compressor, AGC, limiter)
- Streaming to an Icecast server (can be disabled)
- 192kHz VBR MP3 & OGG as streaming formats (can be adjusted)
- MPX generation
- Dynamic RDS/PS, if desired
- Dynamic RT with current track display, if desired
- using a custom ALSA plug called "mpxmix" instead of streaming directly to the sound card, if desired
- full logging

And all this on a hacked €25 TV box (T25MAX) running Armbian (Debian) flashed to it's eMMC.




# IMPORTANT

Building & compiling mpxgen (commit 397e81e for audio input to work)

git clone https://github.com/Anthony96922/mpxgen
git checkout 397e81e

For the dynamic RDS to work, there are some changes to the source code of mpxgen necessary.
You need to change one single line in mpxgen's source code:

```bash
cd ~/mpxgen/src
nano control_pipe.c
```

Change lines from:

```c
char *res = fgets(buf, CTL_BUFFER_SIZE, f_ctl);
if (res == NULL) return -1;
```

to:

```c
char *res = fgets(buf, CTL_BUFFER_SIZE, f_ctl);
if (res == NULL) {
    clearerr(f_ctl);
    return -1;
}
```

Recompile:

```bash
make clean
make

The `clearerr()` resets the error flag so that the next `fgets()` call actually reads from the kernel pipe buffer again. A one-liner fix for a persistent problem. After that, **both** the `exec 3>` approach **and** the simpler `echo > pipe` work because mpxgen clears the error state after each failed read and reads correctly again on the next pass (10 ms later).
