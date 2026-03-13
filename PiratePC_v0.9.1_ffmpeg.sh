#!/bin/bash

# ==============================================================================
# RADIO AUTOMATION SYSTEM - PURE FFMPEG (kein MPD!)
# ==============================================================================
# Playback-Engine komplett auf FFmpeg-Basis mit:
#   - Crossfade (Song<>Song), Hard-Mix (Song->Jingle), Short-Fade (Jingle->Song)
#   - Konfigurierbarer Jingle-Rotation
#   - M3U/M3U8 Playlist-Support (optional, sonst Dateisuche)
#   - Song-History (keine Wiederholungen bis alle gespielt)
#   - Silence-Removal am Ende jedes Tracks
#   - 4 RDS-Modi: rt+ps, ps, rt, static
#   - 4 Input-Modi: webstream, auto, soundcard, soundcard+fallback
#   - Icecast-Streaming optional abschaltbar
#   - Sound-Processing abschaltbar (Pegel bleiben immer an)
#   - High-End Audio Processing Chain (EQ, Kompressor, AGC, Limiter)
#   - Icecast Streaming (OGG/MP3) + mpxgen (FM-Modulator)
#   - [x] in tmux = Neustart
#   - Persistente mpxgen-Architektur (FM bleibt bei Webstream-Ausfall aktiv)
# ==============================================================================

# --- 1. TMUX AUTO-WRAPPER ---
SESSION_NAME="radio"

if [ -z "$TMUX" ]; then
    if ! command -v tmux &> /dev/null; then
        echo "Fehler: tmux ist nicht installiert."
        exit 1
    fi

    tmux has-session -t $SESSION_NAME 2>/dev/null
    if [ $? != 0 ]; then
        echo ">>> Starte neue Radio-Session '$SESSION_NAME'..."
        SCRIPT_PATH=$(realpath "$0")
        tmux new-session -s $SESSION_NAME -d "bash -c '\"$SCRIPT_PATH\" run || (echo \"CRASH! Log lesen! Warte 60s...\"; sleep 60)'"
        sleep 1
    fi

    tmux attach -t $SESSION_NAME
    exit 0
fi

# ==============================================================================
# KONFIGURATION
# ==============================================================================

# Dezimaltrenner auf Punkt erzwingen (deutsches Locale nutzt Komma!)
export LC_ALL=C

CURRENT_USER=$(whoami)
SCRIPT_PATH=$(realpath "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# Arbeitsverzeichnis
WORKDIR="$SCRIPT_DIR/radio_temp"

# Musikpfade
DIR_BASE="/home/$CURRENT_USER/Musik"
DIR_MUSIC="$DIR_BASE"
DIR_JINGLES="$DIR_BASE/Jingles"

# ==============================================================================
# STREAM FORMAT: "ogg" oder "mp3"
# ==============================================================================
STREAM_FORMAT="ogg"

# ==============================================================================
# STREAMING AN ICECAST SERVER: "yes" oder "no"
# ==============================================================================
# Bei "yes" wird das verarbeitete Audio an den Icecast-Server gestreamt
# UND gleichzeitig an mpxgen ausgegeben (FM-Modulation).
# Bei "no" wird NUR an mpxgen ausgegeben (kein Icecast-Upload).
# ==============================================================================
STREAM_TO_SERVER="yes"

# ==============================================================================
# SOUND-PROCESSING: "yes" oder "no"
# ==============================================================================
# Bei "yes" wird die volle Processing-Chain angewendet:
#   EQ (10-Band) + Crystalizer + Stereowiden + Kompressor + AGC + Limiter
# Bei "no" wird kein Processing angewendet - das Signal geht unbearbeitet
# durch. Die separaten Pegel (VOL_ICECAST / VOL_MPXGEN) und das Resampling
# auf RATE_OUTPUT bleiben IMMER aktiv, unabhaengig von dieser Einstellung.
# ==============================================================================
SOUND_PROCESSING="yes"

# ==============================================================================
# PEGEL (in dB) - IMMER AKTIV, auch bei SOUND_PROCESSING="no"
# ==============================================================================
VOL_ICECAST="3"       # Amplify fuer Icecast-Stream
VOL_MPXGEN="-2"       # Amplify fuer mpxgen (FM-Modulator)

# ==============================================================================
# INPUT MODUS: Woher kommt das Audio?
# ==============================================================================
#   "webstream"           = Webstream abgreifen + FFmpeg-Fallback (Standard)
#   "auto"                = Nur FFmpeg-Fallback (Full-Auto-Modus)
#   "soundcard"           = Nur Soundkarte (ALSA)
#   "soundcard+fallback"  = Soundkarte (ALSA) + FFmpeg-Fallback
# ==============================================================================
INPUT_MODE="webstream"

# ==============================================================================
# ALSA SOUNDKARTE (nur bei INPUT_MODE "soundcard" / "soundcard+fallback")
# ==============================================================================
ALSA_DEVICE="hw:5,1"
ALSA_RATE=48000
ALSA_CHANNELS=2

# Webstream URL (nur bei INPUT_MODE "webstream")
STREAM_URL="http://91.229.239.78:8000/radio-streaming"

# ==============================================================================
# RDS KONFIGURATION
# ==============================================================================
STATIC_RT="E-Mails und Musikwuensche an studio@radiobm.de"
STATIC_PS="RBM"
STATIC_PI="161F"
STATIC_PTY="10"

# ==============================================================================
# RDS MODUS: "rt+ps", "rt", "ps" oder "static"
# ==============================================================================
RDS_MODE="rt+ps"

# ==============================================================================
# MPX LEVEL fuer mpxgen (Standard: 50)
# ==============================================================================
# Steuert den Multiplex-Pegel des FM-Signals.
# Werte: 0-100. Hoehere Werte = lauteres FM-Signal.
# ==============================================================================
MPX_LEVEL=50

# ==============================================================================
# JINGLE-ROTATION: Nach wie vielen Songs kommt ein Jingle?
# ==============================================================================
# Beispiel: 3 = Nach jedem 3. Song wird ein Jingle eingespielt.
# Auf 0 setzen um Jingles komplett zu deaktivieren.
# ==============================================================================
JINGLE_INTERVAL=3

# ==============================================================================
# CROSSFADE / OVERLAP (in Sekunden)
# ==============================================================================
OV_STANDARD=8       # Song -> Song
OV_TO_JINGLE=2      # Song -> Jingle
OV_FROM_JINGLE=1    # Jingle -> Song

# ==============================================================================
# SILENCE DETECTION: Erkennt Stille am Trackende -> Crossfade startet frueher
# ==============================================================================
# "yes" = Scannt Ende jedes Tracks. Bei Stille: Crossfade-Punkt vorverlegen.
# "no"  = Immer am berechneten Punkt (DUR - TAIL_LEN) schneiden.
# ==============================================================================
SILENCE_DETECT="yes"
SILENCE_THRESHOLD=-33     # dB - ab wann gilt Audio als "Stille"
SILENCE_DURATION=1.0      # Sekunden - wie lang muss Stille sein

# Icecast URL
if [ "$STREAM_FORMAT" = "ogg" ]; then
    ICE_URL="icecast://source:NYucUHz_d5oM@91.229.239.78:8000/radio-streaming"
else
    ICE_URL="icecast://source:NYucUHz_d5oM@91.229.239.78:8000/radio-streaming"
fi

# Audio Settings
RATE_INTERNAL=48000
CHANNELS=2
RATE_OUTPUT=192000

# mpxgen Pfad
MPXGEN_DIR="/home/$CURRENT_USER/mpxgen/src"
MPXGEN_BIN="./mpxgen"

# Files
FIFO_MPX_CTL="$WORKDIR/mpxgen_ctl"
FIFO_RADIO="$WORKDIR/radio.fifo"
FIFO_MPX_AUDIO="$WORKDIR/mpx_audio.fifo"
NOW_PLAYING="$WORKDIR/now_playing"
HISTORY_FILE="$WORKDIR/play_history.txt"

# Farben
RED='\033[0;31m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# PIDs
PIPELINE_PID=""
RADIO_ENGINE_PID=""
RDS_LOOP_PID=""
RT_PID=""
MPXGEN_PID=""
FEEDER_PID=""
FEEDER_MODE=""

# ==============================================================================
# FUNKTIONEN
# ==============================================================================

log() { echo -e "${BLUE}[RADIO]${NC} $(date '+%H:%M:%S') - $1"; }
err() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') - $1"; }

kill_all() {
    log "Stoppe alle Prozesse..."
    # Erst SIGTERM fuer sauberes Beenden
    for pid in $PIPELINE_PID $RADIO_ENGINE_PID $RDS_LOOP_PID $RT_PID $MPXGEN_PID $FEEDER_PID; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    sleep 0.5
    # Dann SIGKILL fuer hartnäckige Prozesse
    for pid in $PIPELINE_PID $RADIO_ENGINE_PID $RDS_LOOP_PID $RT_PID $MPXGEN_PID $FEEDER_PID; do
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
    killall -9 mpxgen ffmpeg 2>/dev/null
    # Gehaltene File-Deskriptoren schliessen
    exec 3>&- 2>/dev/null
    exec 4>&- 2>/dev/null
    rm -f "$FIFO_MPX_CTL" "$FIFO_RADIO" "$FIFO_MPX_AUDIO"
}

cleanup() {
    echo ""
    kill_all
    log "Bye!"
    exit 0
}
trap cleanup SIGINT SIGTERM

restart_self() {
    echo ""
    log ">>> [x] Neustart angefordert!"
    kill_all
    log "Starte Skript neu..."
    exec "$SCRIPT_PATH" run
}
trap restart_self USR1

prepare_environment() {
    mkdir -p "$WORKDIR/tails" "$DIR_MUSIC" "$DIR_JINGLES"

    rm -f "$FIFO_MPX_CTL" "$FIFO_RADIO" "$FIFO_MPX_AUDIO"
    mkfifo "$FIFO_MPX_CTL"
    mkfifo "$FIFO_RADIO"
    mkfifo "$FIFO_MPX_AUDIO"

    touch "$HISTORY_FILE"
    echo "" > "$NOW_PLAYING"
    rm -f "$WORKDIR/tails/"*.pcm

    chmod -R 777 "$WORKDIR"
}

# ==============================================================================
# SONG-AUSWAHL
# ==============================================================================

get_all_songs() {
    local PLAYLISTS
    PLAYLISTS=$(find "$DIR_BASE" -maxdepth 1 -type f \( -name "*.m3u" -o -name "*.m3u8" \) 2>/dev/null)

    if [ -n "$PLAYLISTS" ]; then
        while IFS= read -r playlist; do
            local PDIR
            PDIR=$(dirname "$playlist")
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" =~ ^#.*$ ]] && continue
                [[ -z "${line// }" ]] && continue
                line=$(echo "$line" | tr -d '\r')
                if [[ "$line" = /* ]]; then
                    [ -f "$line" ] && echo "$line"
                else
                    [ -f "$PDIR/$line" ] && echo "$PDIR/$line"
                fi
            done < "$playlist"
        done <<< "$PLAYLISTS"
    else
        find "$DIR_MUSIC" -type f \( -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.ogg" -o -name "*.m4a" \) ! -path "*/Jingles/*"
    fi
}

get_next_file() {
    local TYPE=$1

    if [ "$TYPE" == "JINGLE" ]; then
        find "$DIR_JINGLES" -type f \( -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.ogg" \) 2>/dev/null | shuf -n 1
    else
        local ALL_SONGS
        ALL_SONGS=$(get_all_songs)
        local TOTAL
        TOTAL=$(echo "$ALL_SONGS" | grep -c '.')
        local PLAYED
        PLAYED=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo "0")

        if [ "$PLAYED" -ge "$TOTAL" ]; then
            echo "" > "$HISTORY_FILE"
        fi

        echo "$ALL_SONGS" | shuf | while IFS= read -r file; do
            if [ -n "$file" ] && ! grep -Fxq "$file" "$HISTORY_FILE" 2>/dev/null; then
                echo "$file"
                echo "$file" >> "$HISTORY_FILE"
                return 0
            fi
        done
    fi
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null
}

# ==============================================================================
# SILENCE DETECTION FUNKTION
# ==============================================================================

detect_effective_end() {
    local FILE="$1"
    local DUR="$2"

    if [ "$SILENCE_DETECT" != "yes" ]; then
        echo "$DUR"
        return
    fi

    local SCAN_LEN=30
    local SCAN_START
    SCAN_START=$(echo "$DUR - $SCAN_LEN" | bc -l)
    if [ "$(echo "$SCAN_START < 0" | bc -l)" -eq 1 ]; then
        SCAN_START="0"
    fi

    local SILENCE_START
    SILENCE_START=$(ffmpeg -hide_banner -v info -ss "$SCAN_START" -i "$FILE" \
        -af "silencedetect=noise=${SILENCE_THRESHOLD}dB:d=${SILENCE_DURATION}" \
        -f null - 2>&1 | grep "silence_start" | tail -1 | sed -n 's/.*silence_start: *\([0-9.]*\).*/\1/p')

    if [ -n "$SILENCE_START" ] && [ "$(echo "$SILENCE_START > 0" | bc -l)" -eq 1 ]; then
        local ABS_SILENCE
        ABS_SILENCE=$(echo "$SCAN_START + $SILENCE_START" | bc -l)
        echo "$ABS_SILENCE"
    else
        echo "$DUR"
    fi
}

# ==============================================================================
# RADIO-ENGINE (reines FFmpeg, Crossfade v5)
# ==============================================================================
# stdout = PCM-Daten -> FIFO. Alle Logs gehen auf stderr (&2)!
#
# Crossfade-Ablauf pro Track mit Vorgaenger-Tail:
#
#   PREV_TAIL (z.B. 8s PCM):
#   [========= SOLO (head -c) =========][==== OVERLAP ====]
#                                         <> MIX (afade out)
#   NEUER TRACK:                         [==== OVERLAP ====][======= BODY =======][= TAIL =]
#                                         <> MIX (afade in)
#
#   Ablauf: Tail vorab extrahieren -> SOLO -> RT-Update -> MIX+BODY -> Loop
#
# Fixes v5 (gegenueber v4):
#   - Tail-Extraktion VOR Audio-Ausgabe (kein Gap zwischen Tracks)
#   - -ss NACH -i fuer sample-genaues Seeking (kein falsches Audio im Tail)
#   - NOW_PLAYING erst nach SOLO-Output (RT synchron zum Hoerer)
# ==============================================================================

run_radio() {
    elog() { echo -e "${GREEN}[ENGINE]${NC} $(date '+%H:%M:%S') - $1" >&2; }
    eerr() { echo -e "${RED}[ENGINE]${NC} $(date '+%H:%M:%S') - $1" >&2; }

    local PREV_TAIL=""
    local PREV_TYPE=""
    local SONG_COUNTER=0
    local TAIL_SLOT="a"

    # Bytes pro Sekunde (s16le stereo)
    local BPS=$(( RATE_INTERNAL * CHANNELS * 2 ))

    elog "Radio-Engine gestartet (Crossfade v5)"
    if [ "$JINGLE_INTERVAL" -gt 0 ]; then
        elog "Jingle-Interval: alle $JINGLE_INTERVAL Songs"
    else
        elog "Jingles deaktiviert"
    fi
    elog "Silence-Detect: $SILENCE_DETECT (${SILENCE_THRESHOLD}dB, ${SILENCE_DURATION}s)"

    while true; do

        local NEXT_TYPE="SONG"
        local CURRENT_FILE=""

        # Jingle einspielen?
        if [ "$JINGLE_INTERVAL" -gt 0 ] && \
           [ "$PREV_TYPE" == "SONG" ] && \
           [ $((SONG_COUNTER % JINGLE_INTERVAL)) -eq 0 ] && \
           [ "$SONG_COUNTER" -gt 0 ]; then
            NEXT_TYPE="JINGLE"
            CURRENT_FILE=$(get_next_file "JINGLE")
            if [ -n "$CURRENT_FILE" ]; then
                elog "[JINGLE] $(basename "$CURRENT_FILE")"
            fi
        fi

        if [ "$NEXT_TYPE" != "JINGLE" ] || [ -z "$CURRENT_FILE" ]; then
            NEXT_TYPE="SONG"
            CURRENT_FILE=$(get_next_file "SONG")
            ((SONG_COUNTER++))
            if [ -n "$CURRENT_FILE" ]; then
                elog "[SONG $SONG_COUNTER] $(basename "$CURRENT_FILE")"
            fi
        fi

        if [ -z "$CURRENT_FILE" ]; then
            eerr "Keine Datei gefunden! Warte 5s..."
            sleep 5
            continue
        fi

        local DUR
        DUR=$(get_duration "$CURRENT_FILE")
        if [ -z "$DUR" ] || [ "$(echo "$DUR < 1" | bc -l)" -eq 1 ]; then
            eerr "Dauer nicht lesbar: $(basename "$CURRENT_FILE") - Skip"
            continue
        fi

        # --- Overlap ---
        local OVERLAP=0
        if [ -z "$PREV_TYPE" ]; then
            OVERLAP=0
        elif [ "$PREV_TYPE" == "SONG" ] && [ "$NEXT_TYPE" == "SONG" ]; then
            OVERLAP=$OV_STANDARD
        elif [ "$PREV_TYPE" == "SONG" ] && [ "$NEXT_TYPE" == "JINGLE" ]; then
            OVERLAP=$OV_TO_JINGLE
        elif [ "$PREV_TYPE" == "JINGLE" ] && [ "$NEXT_TYPE" == "SONG" ]; then
            OVERLAP=$OV_FROM_JINGLE
        elif [ "$PREV_TYPE" == "JINGLE" ] && [ "$NEXT_TYPE" == "JINGLE" ]; then
            OVERLAP=$OV_FROM_JINGLE
        fi

        # --- Tail-Laenge fuer DIESEN Track (fuer den NAECHSTEN Uebergang) ---
        local TAIL_LEN
        if [ "$NEXT_TYPE" == "SONG" ]; then
            TAIL_LEN=$OV_STANDARD
        else
            TAIL_LEN=$OV_FROM_JINGLE
        fi

        # --- Effektive Dauer (Silence Detection) ---
        local EFFECTIVE_END
        EFFECTIVE_END=$(detect_effective_end "$CURRENT_FILE" "$DUR")

        local TAIL_START
        TAIL_START=$(echo "$EFFECTIVE_END - $TAIL_LEN" | bc -l)

        if [ "$SILENCE_DETECT" = "yes" ] && [ "$(echo "$EFFECTIVE_END < $DUR" | bc -l)" -eq 1 ]; then
            local TRIMMED
            TRIMMED=$(echo "$DUR - $EFFECTIVE_END" | bc -l)
            elog "Silence: ${TRIMMED}s am Ende, Crossfade ${TRIMMED}s frueher"
        fi

        # Track zu kurz?
        local MIN_LEN
        MIN_LEN=$(echo "$OVERLAP + $TAIL_LEN + 1" | bc -l)
        if [ "$(echo "$EFFECTIVE_END < $MIN_LEN" | bc -l)" -eq 1 ]; then
            elog "Track zu kurz (${DUR%%.*}s) - spiele komplett"
            echo "$CURRENT_FILE" > "$NOW_PLAYING"
            ffmpeg -v error -i "$CURRENT_FILE" \
                -f s16le -ac $CHANNELS -ar $RATE_INTERNAL - 2>/dev/null
            if [ -n "$PREV_TAIL" ] && [ -f "$PREV_TAIL" ]; then rm -f "$PREV_TAIL"; fi
            PREV_TAIL=""
            PREV_TYPE="$NEXT_TYPE"
            continue
        fi

        # --- Tail-Datei: A/B Slots ---
        local TAIL_FILE
        if [ "$TAIL_SLOT" = "a" ]; then
            TAIL_FILE="$WORKDIR/tails/tail_a.pcm"
            TAIL_SLOT="b"
        else
            TAIL_FILE="$WORKDIR/tails/tail_b.pcm"
            TAIL_SLOT="a"
        fi

        # ==============================================================
        # SCHRITT 0: Tail des aktuellen Tracks VORAB extrahieren
        # ==============================================================
        # Vor jeder Audio-Ausgabe, damit kein Gap zwischen Tracks entsteht.
        # -ss NACH -i = sample-genaues Seeking (nicht Keyframe-basiert!)
        # -y = vorhandene Datei ueberschreiben
        # ==============================================================
        ffmpeg -v error -i "$CURRENT_FILE" \
            -ss "$TAIL_START" -t "$TAIL_LEN" \
            -f s16le -ac $CHANNELS -ar $RATE_INTERNAL -y "$TAIL_FILE" 2>/dev/null

        if [ -f "$TAIL_FILE" ]; then
            local TAIL_BYTES
            TAIL_BYTES=$(stat -c%s "$TAIL_FILE" 2>/dev/null || echo "0")
            local TAIL_SECS
            TAIL_SECS=$(echo "scale=1; $TAIL_BYTES / $BPS" | bc -l)
            elog "Tail: ${TAIL_SECS}s ($(( TAIL_BYTES / 1024 ))kB) -> $(basename "$TAIL_FILE")"
        else
            eerr "Tail-Datei nicht erstellt!"
        fi

        # ==============================================================
        # AUDIO AUSGABE
        # ==============================================================

        if [ -z "$PREV_TAIL" ] || [ ! -f "$PREV_TAIL" ]; then
            # --- ERSTER TRACK (kein Vorgaenger) ---
            # RT-Update: Hoerer hoert diesen Track ab jetzt
            echo "$CURRENT_FILE" > "$NOW_PLAYING"
            elog "Erster Track: Body ${TAIL_START}s"
            ffmpeg -v error -i "$CURRENT_FILE" \
                -t "$TAIL_START" \
                -f s16le -ac $CHANNELS -ar $RATE_INTERNAL - 2>/dev/null
        else
            # --- CROSSFADE mit Vorgaenger-Tail ---

            # Tatsaechliche Tail-Laenge (Bytes -> Sekunden)
            local PREV_BYTES
            PREV_BYTES=$(stat -c%s "$PREV_TAIL" 2>/dev/null || echo "0")
            local PREV_TAIL_SECS
            PREV_TAIL_SECS=$(echo "scale=3; $PREV_BYTES / $BPS" | bc -l)

            # Solo = Tail - Overlap
            local TAIL_SOLO
            TAIL_SOLO=$(echo "scale=3; $PREV_TAIL_SECS - $OVERLAP" | bc -l)

            # -- SCHRITT 1: SOLO via head -c (instant, null Latenz) --
            if [ "$(echo "$TAIL_SOLO > 0.01" | bc -l)" -eq 1 ]; then
                local SOLO_BYTES
                # Auf Frame-Grenze runden (4 Bytes = 1 Stereo-Sample @ 16bit)
                SOLO_BYTES=$(echo "$TAIL_SOLO * $BPS / 4 * 4" | bc | cut -d. -f1)
                elog "SOLO: ${TAIL_SOLO}s (${SOLO_BYTES}B)"
                head -c "$SOLO_BYTES" "$PREV_TAIL"
            fi

            # -- RT-Update: Ab hier hoert der Hoerer den neuen Track --
            echo "$CURRENT_FILE" > "$NOW_PLAYING"

            # -- SCHRITT 2: MIX + BODY in einem ffmpeg-Aufruf --
            local TAIL_SKIP="0"
            if [ "$(echo "$TAIL_SOLO > 0.01" | bc -l)" -eq 1 ]; then
                TAIL_SKIP="$TAIL_SOLO"
            fi

            local TAIL_TRIM_END
            TAIL_TRIM_END=$(echo "$TAIL_SKIP + $OVERLAP" | bc -l)

            elog "MIX: ${OVERLAP}s ($PREV_TYPE->$NEXT_TYPE) Tail=[${TAIL_SKIP}..${TAIL_TRIM_END}]s Body=[${OVERLAP}..${TAIL_START}]s"

            ffmpeg -v error \
                -f s16le -ac $CHANNELS -ar $RATE_INTERNAL -i "$PREV_TAIL" \
                -i "$CURRENT_FILE" \
                -filter_complex "
                    [0:a]atrim=start=${TAIL_SKIP}:end=${TAIL_TRIM_END},asetpts=PTS-STARTPTS,afade=t=out:st=0:d=${OVERLAP}[old];
                    [1:a]asplit=2[new_mix][new_body];
                    [new_mix]atrim=end=${OVERLAP},asetpts=PTS-STARTPTS,afade=t=in:st=0:d=${OVERLAP}[new];
                    [old][new]amix=inputs=2:duration=first:normalize=0[mix];
                    [new_body]atrim=start=${OVERLAP}:end=${TAIL_START},asetpts=PTS-STARTPTS[body];
                    [mix][body]concat=n=2:v=0:a=1[out]
                " \
                -map "[out]" \
                -f s16le -ac $CHANNELS -ar $RATE_INTERNAL - 2>/dev/null
        fi

        # Prev-Tail aufraeumen
        if [ -n "$PREV_TAIL" ] && [ -f "$PREV_TAIL" ]; then
            rm -f "$PREV_TAIL"
        fi

        PREV_TAIL="$TAIL_FILE"
        PREV_TYPE="$NEXT_TYPE"

    done
}

# ==============================================================================
# RDS SERVICES
# ==============================================================================

start_rds() {
    if [[ "$RDS_MODE" != *"ps"* ]]; then
        log "RDS PS Loop: DEAKTIVIERT (PS bleibt '$STATIC_PS')"
        return
    fi

    log "Starte dynamischen RDS PS Loop..."
    (
        while [ ! -p "$FIFO_MPX_CTL" ]; do sleep 1; done
        while true; do
            if [ -p "$FIFO_MPX_CTL" ]; then
                echo "PS RADIO" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS BLACK" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS MOUNTAIN" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS RBM" > "$FIFO_MPX_CTL"; sleep 10
                echo "PS E-Mail" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS studio@" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS radiobm" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS .de" > "$FIFO_MPX_CTL"; sleep 4
            else
                sleep 1
            fi
        done
    ) &
    RDS_LOOP_PID=$!
}

start_rt_updater() {
    if [[ "$RDS_MODE" != *"rt"* ]]; then
        log "RDS RT Updater: DEAKTIVIERT (RT bleibt '$STATIC_RT')"
        return
    fi

    log "Starte dynamischen RT-Updater (ffprobe)..."
    (
        LAST_RT=""
        while true; do
            if [ -f "$NOW_PLAYING" ]; then
                CURRENT_FILE=$(cat "$NOW_PLAYING" 2>/dev/null)
                if [ -n "$CURRENT_FILE" ] && [ -f "$CURRENT_FILE" ]; then
                    ARTIST=$(ffprobe -v error -show_entries format_tags=artist \
                        -of default=noprint_wrappers=1:nokey=1 "$CURRENT_FILE" 2>/dev/null)
                    TITLE=$(ffprobe -v error -show_entries format_tags=title \
                        -of default=noprint_wrappers=1:nokey=1 "$CURRENT_FILE" 2>/dev/null)

                    if [ -n "$ARTIST" ] && [ -n "$TITLE" ]; then
                        NEW_RT="$ARTIST - $TITLE"
                    else
                        FILENAME=$(basename "$CURRENT_FILE")
                        NEW_RT="${FILENAME%.*}"
                    fi
                    NEW_RT="${NEW_RT:0:64}"

                    if [ "$NEW_RT" != "$LAST_RT" ] && [ -n "$NEW_RT" ]; then
                        if [ -p "$FIFO_MPX_CTL" ]; then
                            echo "RT $NEW_RT" > "$FIFO_MPX_CTL"
                            log "RT-Update: $NEW_RT"
                            LAST_RT="$NEW_RT"
                        fi
                    fi
                fi
            fi
            sleep 3
        done
    ) &
    RT_PID=$!
}

start_radio_engine() {
    log "Starte Radio-Engine -> FIFO..."
    run_radio > "$FIFO_RADIO" &
    RADIO_ENGINE_PID=$!
    ok "Radio-Engine PID: $RADIO_ENGINE_PID"
}

# ==============================================================================
# ALSA SOUNDKARTE PRUEFEN
# ==============================================================================

check_soundcard() {
    if ! command -v arecord &> /dev/null; then
        err "arecord nicht installiert (alsa-utils fehlt)"
        return 1
    fi
    if timeout 2 arecord -D "$ALSA_DEVICE" -d 1 -f S16_LE -r "$ALSA_RATE" -c "$ALSA_CHANNELS" /dev/null 2>/dev/null; then
        ok "Soundkarte $ALSA_DEVICE verfuegbar"
        return 0
    else
        err "Soundkarte $ALSA_DEVICE nicht verfuegbar!"
        return 1
    fi
}

# ==============================================================================
# AUDIO FILTER CHAIN
# ==============================================================================
# Zwei Varianten je nach SOUND_PROCESSING:
#   "yes" = Volle Chain (EQ + Crystalizer + Kompressor + Limiter)
#   "no"  = Bypass (nur Pegel + Resample)
# Pegel (VOL_ICECAST / VOL_MPXGEN) und Resample sind IMMER aktiv.
# ==============================================================================

build_filter_chain() {
    local FC=""

    if [ "$SOUND_PROCESSING" = "yes" ]; then

    # ==========================================================================
    # Broadcast Processing Chain mit Multiband-Kompressor
    # ==========================================================================
    # Signalfluss:
    #   Input -> EQ -> Klangveredelung -> [pre]
    #         -> acrossover (4 Baender) -> compand je Band -> amix
    #         -> Wideband Kompressor -> Limiter -> [proc]
    #         -> Split (Icecast + mpxgen) oder nur mpxgen
    # ==========================================================================

    # --- EQ SEKTION ---
        FC="highpass=f=35:poles=2,"
        FC+="equalizer=f=60:width_type=o:width=1.0:g=3,"
        FC+="equalizer=f=120:width_type=o:width=0.8:g=-1,"
        FC+="equalizer=f=400:width_type=o:width=0.7:g=-2,"
        FC+="equalizer=f=800:width_type=o:width=0.8:g=1,"
        FC+="equalizer=f=2000:width_type=o:width=0.6:g=1.5,"
        FC+="equalizer=f=3500:width_type=o:width=0.7:g=2,"
        FC+="equalizer=f=6000:width_type=o:width=0.8:g=1,"
        FC+="equalizer=f=10000:width_type=o:width=1.0:g=1.5,"

    # --- KLANGVEREDELUNG ---
        FC+="crystalizer=i=1.0,"
        FC+="stereowiden=delay=8:feedback=0.1:crossfeed=0.1:drymix=0.9"
        FC+=" [pre];"

    # --- MULTIBAND KOMPRESSOR (4-Band via acrossover) ---
        FC+="[pre]acrossover=split='150 1000 5000':order=8th [b1][b2][b3][b4];"
        FC+="[b1]compand=attacks=0.015:decays=0.300:points=-90/-90|-18/-18|0/-10:gain=0 [c1];"
        FC+="[b2]compand=attacks=0.008:decays=0.150:points=-90/-90|-20/-20|0/-10:gain=0 [c2];"
        FC+="[b3]compand=attacks=0.004:decays=0.080:points=-90/-90|-22/-22|0/-11:gain=0 [c3];"
        FC+="[b4]compand=attacks=0.001:decays=0.040:points=-90/-90|-24/-24|0/-14:gain=0 [c4];"
        FC+="[c1][c2][c3][c4]amix=inputs=4:normalize=0,"

    # --- FINALES LEVELING (nach Multiband) ---
    # Sanfter Wideband-Kompressor fuer konsistente Lautstaerke.
    # Ersetzt dynaudnorm, das durch Frame-basierte Gain-Anpassung
    # und fehlende Kanal-Kopplung (s=0) Volume-Pumping verursachte.
    # Der Multiband oben kontrolliert bereits die Dynamik pro Band;
    # dieser Kompressor sorgt nur fuer finalen Pegelausgleich.
        FC+="acompressor=threshold=-18dB:ratio=2.5:attack=25:release=300:makeup=2dB:knee=8dB,"
        FC+="alimiter=limit=-0.5dB:level_in=1:level_out=1:attack=7:release=50:asc=1"

    # --- SPLIT / OUTPUT ---
    # Lowpass 15kHz NUR auf mpxgen (FM-Pilotton bei 19kHz)
        if [ "$STREAM_TO_SERVER" = "yes" ]; then
            FC+=",asplit=2[ice_pre][loop_pre];"
            FC+="[ice_pre]volume=${VOL_ICECAST}dB[ice];"
            FC+="[loop_pre]lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT[out_loop]"
        else
            FC+=",lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT[out_loop]"
        fi

    else
        # ==== SOUND_PROCESSING=no: Nur Pegel + Resample ====
        if [ "$STREAM_TO_SERVER" = "yes" ]; then
            FC="asplit=2[ice_pre][loop_pre];"
            FC+="[ice_pre]volume=${VOL_ICECAST}dB[ice];"
            FC+="[loop_pre]lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT[out_loop]"
        else
            FC="lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT"
        fi
    fi

    echo "$FC"
}

# ==============================================================================
# PERSISTENTER MPXGEN
# ==============================================================================
# mpxgen laeuft dauerhaft und liest aus FIFO_MPX_AUDIO.
# Verschiedene Feeder (Webstream/Processing-Pipeline) schreiben in das FIFO.
# Ein gehaltener File-Deskriptor (fd 3) verhindert, dass mpxgen EOF sieht,
# wenn ein Feeder stirbt -> FM-Signal bleibt immer aktiv!
# ==============================================================================

start_mpxgen() {
    log "Starte persistenten mpxgen (liest aus FIFO)..."
    cat "$FIFO_MPX_AUDIO" \
    | (cd "$MPXGEN_DIR" && "$MPXGEN_BIN" \
        --audio - \
        --mpx "$MPX_LEVEL" \
        --ctl "$FIFO_MPX_CTL" \
        --pi "$STATIC_PI" \
        --ps "$STATIC_PS" \
        --pty "$STATIC_PTY" \
        --rt "$STATIC_RT") &
    MPXGEN_PID=$!
    ok "mpxgen PID: $MPXGEN_PID"
}

# ==============================================================================
# PROCESSING PIPELINE (ohne mpxgen - schreibt in FIFO_MPX_AUDIO)
# ==============================================================================

start_processing_pipeline() {
    local INPUT_ARGS="$1"

    FILTER_CHAIN=$(build_filter_chain)

    if [ "$STREAM_TO_SERVER" = "yes" ]; then
        if [ "$STREAM_FORMAT" = "ogg" ]; then
            ICE_CODEC="-c:a libvorbis -q:a 6 -content_type audio/ogg -f ogg"
        else
            ICE_CODEC="-c:a libmp3lame -b:a 192k -content_type audio/mpeg -f mp3"
        fi

        ffmpeg -hide_banner -loglevel warning -stats \
            $INPUT_ARGS \
            -filter_complex "$FILTER_CHAIN" \
            -map "[ice]" $ICE_CODEC "$ICE_URL" \
            -map "[out_loop]" -f au "$FIFO_MPX_AUDIO" &
    else
        if [ "$SOUND_PROCESSING" = "yes" ]; then
            ffmpeg -hide_banner -loglevel warning -stats \
                $INPUT_ARGS \
                -filter_complex "$FILTER_CHAIN" \
                -map "[out_loop]" -f au "$FIFO_MPX_AUDIO" &
        else
            ffmpeg -hide_banner -loglevel warning -stats \
                $INPUT_ARGS \
                -af "$FILTER_CHAIN" \
                -f au "$FIFO_MPX_AUDIO" &
        fi
    fi

    PIPELINE_PID=$!
    ok "Processing-Pipeline PID: $PIPELINE_PID"
}

# ==============================================================================
# FEEDER-MANAGEMENT
# ==============================================================================
# Feeder = die Audioquelle, die in FIFO_MPX_AUDIO schreibt.
# Webstream-Feeder: Webstream -> Resample -> FIFO_MPX_AUDIO (direkt)
# Fallback-Feeder:  Radio-Engine -> FIFO_RADIO -> Processing -> FIFO_MPX_AUDIO
# ==============================================================================

kill_feeder() {
    log "Stoppe aktuellen Feeder ($FEEDER_MODE)..."
    # SIGTERM fuer sauberes Beenden
    [ -n "$FEEDER_PID" ] && kill "$FEEDER_PID" 2>/dev/null
    [ -n "$RADIO_ENGINE_PID" ] && kill "$RADIO_ENGINE_PID" 2>/dev/null
    [ -n "$PIPELINE_PID" ] && kill "$PIPELINE_PID" 2>/dev/null
    [ -n "$RT_PID" ] && kill "$RT_PID" 2>/dev/null
    sleep 0.3
    # SIGKILL fuer hartnäckige Prozesse
    [ -n "$FEEDER_PID" ] && kill -9 "$FEEDER_PID" 2>/dev/null
    [ -n "$RADIO_ENGINE_PID" ] && kill -9 "$RADIO_ENGINE_PID" 2>/dev/null
    [ -n "$PIPELINE_PID" ] && kill -9 "$PIPELINE_PID" 2>/dev/null
    [ -n "$RT_PID" ] && kill -9 "$RT_PID" 2>/dev/null
    # Orphaned ffmpeg-Kinder abfangen
    killall ffmpeg 2>/dev/null
    sleep 0.2
    FEEDER_PID=""
    RADIO_ENGINE_PID=""
    PIPELINE_PID=""
    RT_PID=""
    FEEDER_MODE=""
}

start_webstream_feeder() {
    log "Starte Webstream-Feeder..."
    ffmpeg -v error \
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
        -i "$STREAM_URL" \
        -af "lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT" \
        -f au "$FIFO_MPX_AUDIO" &
    FEEDER_PID=$!
    FEEDER_MODE="webstream"
    # RT auf Relay-Modus setzen
    if [ -p "$FIFO_MPX_CTL" ]; then
        echo "RT Relay Mode" > "$FIFO_MPX_CTL" &
    fi
    ok "Webstream-Feeder PID: $FEEDER_PID"
}

start_fallback_feeder() {
    log "Starte Fallback-Feeder (Radio Engine + Processing)..."
    # Radio-Engine schreibt in FIFO_RADIO
    start_radio_engine
    # RT-Updater fuer dynamische Titelanzeige
    start_rt_updater
    # Processing-Pipeline liest aus FIFO_RADIO, schreibt in FIFO_MPX_AUDIO
    local INPUT_ARGS="-f s16le -ar $RATE_INTERNAL -ac $CHANNELS -thread_queue_size 4096 -i $FIFO_RADIO"
    start_processing_pipeline "$INPUT_ARGS"
    FEEDER_MODE="fallback"
}

# ==============================================================================
# MAIN
# ==============================================================================

log "============================================"
log "  RADIO AUTOMATION SYSTEM (Pure FFmpeg)"
log "============================================"
log "Input-Modus:   $INPUT_MODE"
log "Stream-Format: $STREAM_FORMAT"
log "Icecast:       $STREAM_TO_SERVER"
log "Processing:    $SOUND_PROCESSING"
if [[ "$INPUT_MODE" == *"soundcard"* ]]; then
    log "ALSA-Geraet:   $ALSA_DEVICE (${ALSA_RATE}Hz, ${ALSA_CHANNELS}ch)"
fi
log "RDS-Modus:     $RDS_MODE"
log "  PS:  $(if [[ "$RDS_MODE" == *"ps"* ]]; then echo "dynamisch"; else echo "statisch ($STATIC_PS)"; fi)"
log "  RT:  $(if [[ "$RDS_MODE" == *"rt"* ]]; then echo "dynamisch"; else echo "statisch"; fi)"
log "  PI:  $STATIC_PI | PTY: $STATIC_PTY"
log "MPX-Level:     $MPX_LEVEL"
log "Jingle alle:   $(if [ "$JINGLE_INTERVAL" -gt 0 ]; then echo "$JINGLE_INTERVAL Songs"; else echo "deaktiviert"; fi)"
log "Crossfade:     S<>S=${OV_STANDARD}s S->J=${OV_TO_JINGLE}s J->S=${OV_FROM_JINGLE}s"
log "Silence-Det:   $(if [ "$SILENCE_DETECT" = "yes" ]; then echo "AN (${SILENCE_THRESHOLD}dB, ${SILENCE_DURATION}s)"; else echo "AUS"; fi)"
log "Pegel:         Icecast=${VOL_ICECAST}dB mpxgen=${VOL_MPXGEN}dB"
log "Hotkey:        [x] = Neustart"
log "============================================"

killall -9 mpxgen ffmpeg 2>/dev/null

if [ -d "$WORKDIR" ]; then
    log "Raeume temp auf..."
    rm -rf "${WORKDIR:?}"/*
fi

prepare_environment

tmux bind-key -n x run-shell "kill -USR1 $$ 2>/dev/null" 2>/dev/null

if [ ! -f "$MPXGEN_DIR/mpxgen" ]; then
    err "FEHLER: mpxgen nicht gefunden unter: $MPXGEN_DIR/mpxgen"
    exit 1
fi
chmod +x "$MPXGEN_DIR/mpxgen"

SONG_COUNT=$(get_all_songs | grep -c '.')
JINGLE_COUNT=$(find "$DIR_JINGLES" -type f \( -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.ogg" \) 2>/dev/null | wc -l)
log "Songs: $SONG_COUNT | Jingles: $JINGLE_COUNT"

FOUND_M3U=$(find "$DIR_BASE" -maxdepth 1 -type f \( -name "*.m3u" -o -name "*.m3u8" \) 2>/dev/null)
if [ -n "$FOUND_M3U" ]; then
    log "Playlist(s): $(echo "$FOUND_M3U" | xargs -I{} basename {} | tr '\n' ' ')"
fi

# RDS PS-Loop starten (laeuft persistent, wartet auf mpxgen)
start_rds

# ==============================================================================
# HAUPTSCHLEIFE
# ==============================================================================

while true; do

    case "$INPUT_MODE" in

        "webstream")
            log "=== Webstream-Modus mit persistentem mpxgen ==="

            # Persistenten mpxgen starten
            start_mpxgen

            # Gehaltene File-Deskriptoren:
            # fd 3 auf FIFO_MPX_AUDIO -> mpxgen bekommt nie EOF
            # fd 4 auf FIFO_RADIO -> Processing-Pipeline bekommt nie EOF
            exec 3>"$FIFO_MPX_AUDIO"
            exec 4>"$FIFO_RADIO"

            while true; do
                # Prüfe ob mpxgen noch lebt
                if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                    err "mpxgen gestorben! Neustart..."
                    start_mpxgen
                fi

                # Prüfe ob aktueller Feeder noch lebt
                if [ -n "$FEEDER_PID" ] && ! kill -0 "$FEEDER_PID" 2>/dev/null; then
                    log "Feeder ($FEEDER_MODE) gestorben."
                    # Auch Processing-Pipeline prüfen (Fallback-Modus)
                    if [ "$FEEDER_MODE" = "fallback" ] && [ -n "$PIPELINE_PID" ] && ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
                        log "Processing-Pipeline auch gestorben."
                    fi
                    kill_feeder
                fi

                # Webstream-Verfügbarkeit prüfen
                STREAM_ONLINE=false
                if curl --output /dev/null --silent --head --fail --connect-timeout 2 "$STREAM_URL"; then
                    STREAM_ONLINE=true
                fi

                if [ "$STREAM_ONLINE" = true ]; then
                    if [ "$FEEDER_MODE" != "webstream" ]; then
                        log "Webstream verfuegbar! Schalte auf Webstream..."
                        [ -n "$FEEDER_MODE" ] && kill_feeder
                        start_webstream_feeder
                    fi
                else
                    if [ "$FEEDER_MODE" != "fallback" ]; then
                        log "Webstream nicht erreichbar. Schalte auf Fallback..."
                        [ -n "$FEEDER_MODE" ] && kill_feeder
                        start_fallback_feeder
                    fi
                fi

                sleep 3
            done
            ;;

        "auto")
            log "=== Auto-Modus mit persistentem mpxgen ==="

            start_mpxgen
            exec 3>"$FIFO_MPX_AUDIO"
            exec 4>"$FIFO_RADIO"

            while true; do
                # Radio-Engine prüfen/starten
                if [ -z "$RADIO_ENGINE_PID" ] || ! kill -0 "$RADIO_ENGINE_PID" 2>/dev/null; then
                    start_radio_engine
                fi
                # RT-Updater prüfen/starten
                if [ -z "$RT_PID" ] || ! kill -0 "$RT_PID" 2>/dev/null; then
                    start_rt_updater
                fi
                # Processing-Pipeline prüfen/starten
                if [ -z "$PIPELINE_PID" ] || ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
                    local INPUT_ARGS="-f s16le -ar $RATE_INTERNAL -ac $CHANNELS -thread_queue_size 4096 -i $FIFO_RADIO"
                    start_processing_pipeline "$INPUT_ARGS"
                fi
                # mpxgen prüfen/starten
                if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                    start_mpxgen
                fi

                sleep 5
            done
            ;;

        "soundcard")
            log "=== Soundcard-Modus mit persistentem mpxgen ==="

            start_mpxgen
            exec 3>"$FIFO_MPX_AUDIO"

            while true; do
                if check_soundcard; then
                    local INPUT_ARGS="-f alsa -sample_rate $ALSA_RATE -channels $ALSA_CHANNELS -thread_queue_size 4096 -i $ALSA_DEVICE"
                    start_processing_pipeline "$INPUT_ARGS"
                    wait "$PIPELINE_PID" 2>/dev/null
                    PIPELINE_PID=""
                    log "Soundcard-Pipeline beendet."
                else
                    err "Soundkarte nicht verfuegbar! Warte 10s..."
                    sleep 10
                fi

                # mpxgen prüfen
                if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                    start_mpxgen
                fi

                sleep 2
            done
            ;;

        "soundcard+fallback")
            log "=== Soundcard+Fallback-Modus mit persistentem mpxgen ==="

            start_mpxgen
            exec 3>"$FIFO_MPX_AUDIO"
            exec 4>"$FIFO_RADIO"

            while true; do
                if check_soundcard; then
                    log "Soundkarte verfuegbar, nutze ALSA-Input..."
                    local INPUT_ARGS="-f alsa -sample_rate $ALSA_RATE -channels $ALSA_CHANNELS -thread_queue_size 4096 -i $ALSA_DEVICE"
                    start_processing_pipeline "$INPUT_ARGS"
                    log "(Fallback bereit wenn Soundkarte ausfaellt)"

                    while kill -0 "$PIPELINE_PID" 2>/dev/null; do
                        if ! check_soundcard 2>/dev/null; then
                            log "Soundkarte verloren!"
                            kill "$PIPELINE_PID" 2>/dev/null
                            wait "$PIPELINE_PID" 2>/dev/null
                            PIPELINE_PID=""
                            break
                        fi
                        # mpxgen prüfen
                        if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                            start_mpxgen
                        fi
                        sleep 5
                    done
                else
                    log "Soundkarte nicht verfuegbar -> Fallback auf Radio-Engine"
                    start_fallback_feeder

                    while [ -n "$PIPELINE_PID" ] && kill -0 "$PIPELINE_PID" 2>/dev/null; do
                        if check_soundcard 2>/dev/null; then
                            log "Soundkarte wieder da! Umschalten..."
                            kill_feeder
                            break
                        fi
                        # mpxgen prüfen
                        if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                            start_mpxgen
                        fi
                        sleep 5
                    done

                    kill_feeder
                    log "Fallback-Pipeline beendet."
                fi

                # mpxgen prüfen
                if ! kill -0 "$MPXGEN_PID" 2>/dev/null; then
                    start_mpxgen
                fi

                sleep 2
            done
            ;;

        *)
            err "Unbekannter INPUT_MODE: $INPUT_MODE"
            err "Gueltig: webstream, auto, soundcard, soundcard+fallback"
            sleep 10
            ;;
    esac

    sleep 2
done
