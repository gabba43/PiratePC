#!/bin/bash

# ==============================================================================
# RADIO AUTOMATION SYSTEM - PURE FFMPEG (kein MPD!)
# ==============================================================================
# Playback-Engine komplett auf FFmpeg-Basis mit:
#   - Crossfade (Song↔Song), Hard-Mix (Song→Jingle), Short-Fade (Jingle→Song)
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
# auf RATE_OUTPUT bleiben IMMER aktiv, unabhängig von dieser Einstellung.
# ==============================================================================
SOUND_PROCESSING="yes"

# ==============================================================================
# PEGEL (in dB) - IMMER AKTIV, auch bei SOUND_PROCESSING="no"
# ==============================================================================
VOL_ICECAST="3"       # Amplify für Icecast-Stream
VOL_MPXGEN="-2"       # Amplify für mpxgen (FM-Modulator)

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
STREAM_URL="http://192.168.111.11:8000/stream"

# ==============================================================================
# RDS KONFIGURATION
# ==============================================================================
STATIC_RT="E-Mails to studio@iskra.com"
STATIC_PS="ISKRA"
STATIC_PI="FFFF"
STATIC_PTY="10"

# ==============================================================================
# RDS MODUS: "rt+ps", "rt", "ps" oder "static"
# ==============================================================================
RDS_MODE="rt+ps"

# ==============================================================================
# MPX LEVEL für mpxgen (Standard: 50)
# ==============================================================================
# Steuert den Multiplex-Pegel des FM-Signals.
# Werte: 0-100. Höhere Werte = lauteres FM-Signal.
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
OV_STANDARD=8       # Song → Song
OV_TO_JINGLE=2      # Song → Jingle
OV_FROM_JINGLE=1    # Jingle → Song

# ==============================================================================
# SILENCE DETECTION: Erkennt Stille am Trackende → Crossfade startet früher
# ==============================================================================
# "yes" = Scannt Ende jedes Tracks. Bei Stille: Crossfade-Punkt vorverlegen.
# "no"  = Immer am berechneten Punkt (DUR - TAIL_LEN) schneiden.
# ==============================================================================
SILENCE_DETECT="yes"
SILENCE_THRESHOLD=-33     # dB — ab wann gilt Audio als "Stille"
SILENCE_DURATION=1.0      # Sekunden — wie lang muss Stille sein

# Icecast URL
if [ "$STREAM_FORMAT" = "ogg" ]; then
    ICE_URL="icecast://source:PASSWORD@SERVER:8000/stream"
else
    ICE_URL="icecast://source:PASSWORD@SERVER:8000/stream"
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

# ==============================================================================
# FUNKTIONEN
# ==============================================================================

log() { echo -e "${BLUE}[RADIO]${NC} $(date '+%H:%M:%S') - $1"; }
err() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') - $1"; }

kill_all() {
    log "Stoppe alle Prozesse..."
    for pid in $PIPELINE_PID $RADIO_ENGINE_PID $RDS_LOOP_PID $RT_PID; do
        [ ! -z "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
    killall -9 mpxgen ffmpeg 2>/dev/null
    rm -f "$FIFO_MPX_CTL" "$FIFO_RADIO"
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

    rm -f "$FIFO_MPX_CTL" "$FIFO_RADIO"
    mkfifo "$FIFO_MPX_CTL"
    mkfifo "$FIFO_RADIO"

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

    if [ ! -z "$PLAYLISTS" ]; then
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
            if [ ! -z "$file" ] && ! grep -Fxq "$file" "$HISTORY_FILE" 2>/dev/null; then
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
# RADIO-ENGINE (reines FFmpeg)
# ==============================================================================
# stdout = PCM-Daten → FIFO. Alle Logs gehen auf stderr (&2)!
#
# CROSSFADE-LOGIK (v3 - Single-Call + head):
# Problem: Separate ffmpeg-Aufrufe für Solo/Mix/Body erzeugen Lücken
# und -ss auf raw PCM ist unzuverlässig bei Fließkomma-Werten.
#
# Lösung:
#   1. SOLO: Überschüssiger Tail via "head -c" (instant, null Latenz)
#   2. MIX+BODY: Ein einziger ffmpeg-Aufruf mit filter_complex + concat:
#      - atrim statt -ss (zuverlässiger auf raw PCM)
#      - Crossfade-Mix und Body-Sektion per concat verkettet
#      → Kein Prozess-Gap zwischen Mix und Body
#   3. TAIL: Separat extrahiert (ohne silenceremove)
#
# Bytes-pro-Sekunde: RATE_INTERNAL * CHANNELS * 2 (16-bit)
# ==============================================================================

# ==============================================================================
# SILENCE DETECTION FUNKTION
# ==============================================================================
# Scannt die letzten 30s eines Tracks auf Stille.
# Gibt die "effektive Dauer" zurück (= wo letzte Stille beginnt).
# Ohne Stille → gibt volle Dauer zurück.
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

    # silencedetect braucht info-Level für die Ausgabe
    local SILENCE_START
    SILENCE_START=$(ffmpeg -hide_banner -v info -ss "$SCAN_START" -i "$FILE" \
        -af "silencedetect=noise=${SILENCE_THRESHOLD}dB:d=${SILENCE_DURATION}" \
        -f null - 2>&1 | grep "silence_start" | tail -1 | sed -n 's/.*silence_start: *\([0-9.]*\).*/\1/p')

    if [ ! -z "$SILENCE_START" ] && [ "$(echo "$SILENCE_START > 0" | bc -l)" -eq 1 ]; then
        # silence_start ist relativ zu SCAN_START
        local ABS_SILENCE
        ABS_SILENCE=$(echo "$SCAN_START + $SILENCE_START" | bc -l)
        echo "$ABS_SILENCE"
    else
        echo "$DUR"
    fi
}

# ==============================================================================
# RADIO-ENGINE (reines FFmpeg, Crossfade v4)
# ==============================================================================
# stdout = PCM-Daten → FIFO. Alle Logs gehen auf stderr (&2)!
#
# Crossfade-Ablauf pro Track mit Vorgänger-Tail:
#
#   PREV_TAIL (z.B. 8s PCM):
#   [========= SOLO (head -c) =========][==== OVERLAP ====]
#                                         ↕ MIX (afade out)
#   NEUER TRACK:                         [==== OVERLAP ====][======= BODY =======][= TAIL =]
#                                         ↕ MIX (afade in)
#
#   Ausgabe: SOLO → MIX+BODY (ein ffmpeg-Aufruf, concat) → [Tail wird gespeichert]
#
# Fixes v4:
#   - Tail-Extraktion mit -t (exakte Länge, unabhängig von Silence Detection)
#   - atrim mit explizitem end-Punkt (kein Überlauf)
#   - Silence Detection verschiebt Crossfade-Punkt vor Stille
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

    elog "Radio-Engine gestartet (Crossfade v4)"
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
            if [ ! -z "$CURRENT_FILE" ]; then
                elog "[JINGLE] $(basename "$CURRENT_FILE")"
            fi
        fi

        if [ "$NEXT_TYPE" != "JINGLE" ] || [ -z "$CURRENT_FILE" ]; then
            NEXT_TYPE="SONG"
            CURRENT_FILE=$(get_next_file "SONG")
            ((SONG_COUNTER++))
            if [ ! -z "$CURRENT_FILE" ]; then
                elog "[SONG $SONG_COUNTER] $(basename "$CURRENT_FILE")"
            fi
        fi

        if [ -z "$CURRENT_FILE" ]; then
            eerr "Keine Datei gefunden! Warte 5s..."
            sleep 5
            continue
        fi

        echo "$CURRENT_FILE" > "$NOW_PLAYING"

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

        # --- Tail-Länge für DIESEN Track (für den NÄCHSTEN Übergang) ---
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
        # AUDIO AUSGABE
        # ==============================================================

        if [ -z "$PREV_TAIL" ] || [ ! -f "$PREV_TAIL" ]; then
            # ─── ERSTER TRACK (kein Vorgänger) ───
            elog "Erster Track: Body ${TAIL_START}s"
            ffmpeg -v error -i "$CURRENT_FILE" \
                -t "$TAIL_START" \
                -f s16le -ac $CHANNELS -ar $RATE_INTERNAL - 2>/dev/null
        else
            # ─── CROSSFADE mit Vorgänger-Tail ───

            # Tatsächliche Tail-Länge (Bytes → Sekunden)
            local PREV_BYTES
            PREV_BYTES=$(stat -c%s "$PREV_TAIL" 2>/dev/null || echo "0")
            local PREV_TAIL_SECS
            PREV_TAIL_SECS=$(echo "scale=3; $PREV_BYTES / $BPS" | bc -l)

            # Solo = Tail - Overlap
            local TAIL_SOLO
            TAIL_SOLO=$(echo "scale=3; $PREV_TAIL_SECS - $OVERLAP" | bc -l)

            # ── SCHRITT 1: SOLO via head -c (instant, null Latenz) ──
            if [ "$(echo "$TAIL_SOLO > 0.01" | bc -l)" -eq 1 ]; then
                local SOLO_BYTES
                # Auf Frame-Grenze runden (4 Bytes = 1 Stereo-Sample @ 16bit)
                SOLO_BYTES=$(echo "$TAIL_SOLO * $BPS / 4 * 4" | bc | cut -d. -f1)
                elog "SOLO: ${TAIL_SOLO}s (${SOLO_BYTES}B)"
                head -c "$SOLO_BYTES" "$PREV_TAIL"
            fi

            # ── SCHRITT 2: MIX + BODY in einem ffmpeg-Aufruf ──
            # atrim mit explizitem start UND end → exakte Grenzen, kein Überlauf
            local TAIL_SKIP="0"
            if [ "$(echo "$TAIL_SOLO > 0.01" | bc -l)" -eq 1 ]; then
                TAIL_SKIP="$TAIL_SOLO"
            fi

            # Exakter Endpunkt für den Tail-Trim (TAIL_SKIP + OVERLAP)
            local TAIL_TRIM_END
            TAIL_TRIM_END=$(echo "$TAIL_SKIP + $OVERLAP" | bc -l)

            elog "MIX: ${OVERLAP}s ($PREV_TYPE→$NEXT_TYPE) Tail=[${TAIL_SKIP}..${TAIL_TRIM_END}]s Body=[${OVERLAP}..${TAIL_START}]s"

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

        # ── SCHRITT 3: Tail speichern ──
        # WICHTIG: -t begrenzt auf exakt TAIL_LEN Sekunden!
        # Ohne -t würde bei Silence Detection (TAIL_START < DUR - TAIL_LEN)
        # der Tail bis zum echten Dateiende gehen → zu lang → alle
        # folgenden Berechnungen (SOLO/MIX) wären falsch.
        ffmpeg -v error \
            -ss "$TAIL_START" -t "$TAIL_LEN" -i "$CURRENT_FILE" \
            -f s16le -ac $CHANNELS -ar $RATE_INTERNAL "$TAIL_FILE" 2>/dev/null

        if [ -f "$TAIL_FILE" ]; then
            local TAIL_BYTES
            TAIL_BYTES=$(stat -c%s "$TAIL_FILE" 2>/dev/null || echo "0")
            local TAIL_SECS
            TAIL_SECS=$(echo "scale=1; $TAIL_BYTES / $BPS" | bc -l)
            elog "Tail: ${TAIL_SECS}s ($(( TAIL_BYTES / 1024 ))kB) → $(basename "$TAIL_FILE")"
        else
            eerr "Tail-Datei nicht erstellt!"
        fi

        if [ -n "$PREV_TAIL" ] && [ -f "$PREV_TAIL" ]; then
            rm -f "$PREV_TAIL"
        fi

        PREV_TAIL="$TAIL_FILE"
        PREV_TYPE="$NEXT_TYPE"

    done
}

# ==============================================================================
# START SERVICES
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
                echo "PS ISKRA" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS TEST" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS TEST" > "$FIFO_MPX_CTL"; sleep 10
                echo "PS E-Mail" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS studio@" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS iskra" > "$FIFO_MPX_CTL"; sleep 4
                echo "PS .com" > "$FIFO_MPX_CTL"; sleep 4
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
                if [ ! -z "$CURRENT_FILE" ] && [ -f "$CURRENT_FILE" ]; then
                    ARTIST=$(ffprobe -v error -show_entries format_tags=artist \
                        -of default=noprint_wrappers=1:nokey=1 "$CURRENT_FILE" 2>/dev/null)
                    TITLE=$(ffprobe -v error -show_entries format_tags=title \
                        -of default=noprint_wrappers=1:nokey=1 "$CURRENT_FILE" 2>/dev/null)

                    if [ ! -z "$ARTIST" ] && [ ! -z "$TITLE" ]; then
                        NEW_RT="$ARTIST - $TITLE"
                    else
                        FILENAME=$(basename "$CURRENT_FILE")
                        NEW_RT="${FILENAME%.*}"
                    fi
                    NEW_RT="${NEW_RT:0:64}"

                    if [ "$NEW_RT" != "$LAST_RT" ] && [ ! -z "$NEW_RT" ]; then
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
    log "Starte Radio-Engine → FIFO..."
    run_radio > "$FIFO_RADIO" &
    RADIO_ENGINE_PID=$!
    ok "Radio-Engine PID: $RADIO_ENGINE_PID"
}

# ==============================================================================
# ALSA SOUNDKARTE PRÜFEN
# ==============================================================================

check_soundcard() {
    if ! command -v arecord &> /dev/null; then
        err "arecord nicht installiert (alsa-utils fehlt)"
        return 1
    fi
    if timeout 2 arecord -D "$ALSA_DEVICE" -d 1 -f S16_LE -r "$ALSA_RATE" -c "$ALSA_CHANNELS" /dev/null 2>/dev/null; then
        ok "Soundkarte $ALSA_DEVICE verfügbar"
        return 0
    else
        err "Soundkarte $ALSA_DEVICE nicht verfügbar!"
        return 1
    fi
}

# ==============================================================================
# AUDIO FILTER CHAIN
# ==============================================================================
# Zwei Varianten je nach SOUND_PROCESSING:
#   "yes" = Volle Chain (EQ + Crystalizer + Kompressor + AGC + Limiter)
#   "no"  = Bypass (nur Pegel + Resample)
# Pegel (VOL_ICECAST / VOL_MPXGEN) und Resample sind IMMER aktiv.
# ==============================================================================

build_filter_chain() {
    local FC=""

    if [ "$SOUND_PROCESSING" = "yes" ]; then

    # --- Broadcast Processing Chain - Optimized for "Smooth & Loud" ---

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
        # KEIN Lowpass hier — kommt NUR auf mpxgen (FM-Pilotton-Schutz)

    # --- KLANGVEREDELUNG ---
        FC+="crystalizer=i=1.0,"
        FC+="stereowiden=delay=8:feedback=0.1:crossfeed=0.1:drymix=0.9,"

    # --- DYNAMIK ---
        FC+="acompressor=threshold=-18dB:ratio=3:attack=25:release=400:makeup=2dB:knee=8,"
        FC+="dynaudnorm=f=200:g=31:p=0.9:m=6:r=0.9:s=0,"
        FC+="alimiter=limit=-0.5dB:level_in=1:level_out=1:attack=7:release=50:asc=1,"

    fi
    # Ab hier: IMMER aktiv (Pegel + Resample/Split)
    # Lowpass 15kHz NUR auf mpxgen (FM-Pilotton bei 19kHz)

    if [ "$STREAM_TO_SERVER" = "yes" ]; then
        # MIT Icecast: Split → Icecast (ohne Lowpass) + mpxgen (mit Lowpass)
        FC+="asplit=2[ice_pre][loop_pre];"
        FC+="[ice_pre]volume=${VOL_ICECAST}dB[ice];"
        FC+="[loop_pre]lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT[out_loop]"
    else
        # OHNE Icecast: Nur mpxgen (mit Lowpass)
        FC+="lowpass=f=15000:poles=2,volume=${VOL_MPXGEN}dB,aresample=$RATE_OUTPUT"
    fi

    echo "$FC"
}

# ==============================================================================
# PIPELINE STARTEN
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
            -map "[out_loop]" -f au - \
        | (cd "$MPXGEN_DIR" && "$MPXGEN_BIN" \
            --audio - \
            --mpx "$MPX_LEVEL" \
            --ctl "$FIFO_MPX_CTL" \
            --pi "$STATIC_PI" \
            --ps "$STATIC_PS" \
            --pty "$STATIC_PTY" \
            --rt "$STATIC_RT") &
    else
        ffmpeg -hide_banner -loglevel warning -stats \
            $INPUT_ARGS \
            -af "$FILTER_CHAIN" \
            -f au - \
        | (cd "$MPXGEN_DIR" && "$MPXGEN_BIN" \
            --audio - \
            --mpx "$MPX_LEVEL" \
            --ctl "$FIFO_MPX_CTL" \
            --pi "$STATIC_PI" \
            --ps "$STATIC_PS" \
            --pty "$STATIC_PTY" \
            --rt "$STATIC_RT") &
    fi

    PIPELINE_PID=$!
}

# ==============================================================================
# MODUS-FUNKTIONEN
# ==============================================================================

run_webstream_relay() {
    log "MODUS: Webstream Relay"
    if [ ! -z "$RADIO_ENGINE_PID" ]; then kill -9 "$RADIO_ENGINE_PID" 2>/dev/null; RADIO_ENGINE_PID=""; fi
    if [ ! -z "$RT_PID" ]; then kill -9 "$RT_PID" 2>/dev/null; RT_PID=""; fi

    ffmpeg -hide_banner -loglevel error -stats \
        -thread_queue_size 2048 \
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
        -i "$STREAM_URL" \
        -filter:a "aresample=$RATE_OUTPUT" \
        -f au - \
    | (cd "$MPXGEN_DIR" && "$MPXGEN_BIN" \
        --audio - --mpx "$MPX_LEVEL" --ctl "$FIFO_MPX_CTL" \
        --pi "$STATIC_PI" --ps "$STATIC_PS" --pty "$STATIC_PTY" --rt "Relay Mode") &

    PIPELINE_PID=$!
    wait "$PIPELINE_PID"
    log "Webstream-Relay beendet."
    PIPELINE_PID=""
}

run_fallback() {
    log "MODUS: FFmpeg Engine -> $STREAM_FORMAT + Processing=$SOUND_PROCESSING"
    start_radio_engine
    start_rt_updater

    local INPUT_ARGS="-f s16le -ar $RATE_INTERNAL -ac $CHANNELS -thread_queue_size 4096 -i $FIFO_RADIO"
    start_processing_pipeline "$INPUT_ARGS"
}

run_soundcard() {
    log "MODUS: Soundkarte ($ALSA_DEVICE) -> Processing=$SOUND_PROCESSING"
    local INPUT_ARGS="-f alsa -sample_rate $ALSA_RATE -channels $ALSA_CHANNELS -thread_queue_size 4096 -i $ALSA_DEVICE"
    start_processing_pipeline "$INPUT_ARGS"
}

cleanup_pipeline() {
    if [ ! -z "$RADIO_ENGINE_PID" ]; then kill -9 "$RADIO_ENGINE_PID" 2>/dev/null; RADIO_ENGINE_PID=""; fi
    if [ ! -z "$RT_PID" ]; then kill -9 "$RT_PID" 2>/dev/null; RT_PID=""; fi
    if [ ! -z "$PIPELINE_PID" ]; then kill -9 "$PIPELINE_PID" 2>/dev/null; PIPELINE_PID=""; fi
    killall -9 ffmpeg mpxgen 2>/dev/null
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
    log "ALSA-Gerät:    $ALSA_DEVICE (${ALSA_RATE}Hz, ${ALSA_CHANNELS}ch)"
fi
log "RDS-Modus:     $RDS_MODE"
log "  PS:  $(if [[ "$RDS_MODE" == *"ps"* ]]; then echo "dynamisch"; else echo "statisch ($STATIC_PS)"; fi)"
log "  RT:  $(if [[ "$RDS_MODE" == *"rt"* ]]; then echo "dynamisch"; else echo "statisch"; fi)"
log "  PI:  $STATIC_PI | PTY: $STATIC_PTY"
log "MPX-Level:     $MPX_LEVEL"
log "Jingle alle:   $(if [ "$JINGLE_INTERVAL" -gt 0 ]; then echo "$JINGLE_INTERVAL Songs"; else echo "deaktiviert"; fi)"
log "Crossfade:     S↔S=${OV_STANDARD}s S→J=${OV_TO_JINGLE}s J→S=${OV_FROM_JINGLE}s"
log "Silence-Det:   $(if [ "$SILENCE_DETECT" = "yes" ]; then echo "AN (${SILENCE_THRESHOLD}dB, ${SILENCE_DURATION}s)"; else echo "AUS"; fi)"
log "Pegel:         Icecast=${VOL_ICECAST}dB mpxgen=${VOL_MPXGEN}dB"
log "Hotkey:        [x] = Neustart"
log "============================================"

killall -9 mpxgen ffmpeg 2>/dev/null

if [ -d "$WORKDIR" ]; then
    log "Räume temp auf..."
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
if [ ! -z "$FOUND_M3U" ]; then
    log "Playlist(s): $(echo "$FOUND_M3U" | xargs -I{} basename {} | tr '\n' ' ')"
fi

start_rds

# ==============================================================================
# HAUPTSCHLEIFE
# ==============================================================================

while true; do

    case "$INPUT_MODE" in

        "webstream")
            log "Prüfe Webstream Status..."
            STREAM_ONLINE=false

            for i in {1..5}; do
                if curl --output /dev/null --silent --head --fail --connect-timeout 2 "$STREAM_URL"; then
                    STREAM_ONLINE=true
                    log "Webstream gefunden! (Versuch $i/5)"
                    break
                else
                    log "Webstream nicht erreichbar (Versuch $i/5) - Warte 3s..."
                    if [ $i -lt 5 ]; then sleep 3; fi
                fi
            done

            if [ "$STREAM_ONLINE" = true ]; then
                run_webstream_relay
                sleep 1
            else
                run_fallback

                while kill -0 "$PIPELINE_PID" 2>/dev/null; do
                    if curl --output /dev/null --silent --head --fail --connect-timeout 1 "$STREAM_URL"; then
                        log "Webstream zurück! Umschalten..."
                        cleanup_pipeline
                        break
                    fi
                    sleep 2
                done

                cleanup_pipeline
                log "Pipeline beendet. Warte 5s..."
                sleep 5
            fi
            ;;

        "auto")
            run_fallback
            wait "$PIPELINE_PID" 2>/dev/null
            cleanup_pipeline
            log "Pipeline beendet. Warte 5s..."
            sleep 5
            ;;

        "soundcard")
            if check_soundcard; then
                run_soundcard
                wait "$PIPELINE_PID" 2>/dev/null
                cleanup_pipeline
                log "Soundcard-Pipeline beendet. Warte 5s..."
            else
                err "Soundkarte nicht verfügbar! Warte 10s..."
            fi
            sleep 5
            ;;

        "soundcard+fallback")
            if check_soundcard; then
                run_soundcard
                log "(Fallback bereit wenn Soundkarte ausfällt)"
                wait "$PIPELINE_PID" 2>/dev/null
                cleanup_pipeline
                log "Soundcard-Pipeline beendet."
            else
                log "Soundkarte nicht verfügbar → Fallback auf FFmpeg-Engine"
                run_fallback

                while kill -0 "$PIPELINE_PID" 2>/dev/null; do
                    if check_soundcard 2>/dev/null; then
                        log "Soundkarte wieder da! Umschalten..."
                        cleanup_pipeline
                        break
                    fi
                    sleep 5
                done

                cleanup_pipeline
                log "Fallback-Pipeline beendet."
            fi
            sleep 5
            ;;

        *)
            err "Unbekannter INPUT_MODE: $INPUT_MODE"
            err "Gültig: webstream, auto, soundcard, soundcard+fallback"
            sleep 10
            ;;
    esac

    sleep 2
done
