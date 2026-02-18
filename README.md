# PiratePC
A fully automated stream/music player, sound processor, web stream & MPX generator for radio purposes - using ONLY FFmpeg and mpxgen.

 Features:
- Tries to connect to a web stream: If successful, the stream is processed if desired and multiplexed (5 times with a 3 second break between the attempts)
- 4 modes:
    “webstream”           = Webstream capture + FFmpeg fallback (default)
    “auto”                = FFmpeg fallback only (full auto mode)
    “soundcard”           = Capture sound card only (ALSA)
    “soundcard+fallback”  = Capture sound card (ALSA) + FFmpeg fallback

- Custom fallback audio player using ONLY FFmpeg: Automatic creation of playlists using a specified folder containing audio files AND/OR .m3u/.m3u8 files with streaming to the icecast server
- Playback of jingles in a separate folder every X songs with shorter, customizable crossfade
- Separate volume settings for stream and MPX
- Basic sound processing with all standard features (EQ, crystallizer, stereo widening, compressor, AGC, limiter)
- Streaming to an Icecast server (can be disabled)
- MPX generation
- Dynamic RDS/PS, if desired
- Dynamic RT with current track display, if desired
- full logging

And all this on a hacked €25 TV box (T25MAX) running Armbian (Debian) flashed to it's eMMC.
