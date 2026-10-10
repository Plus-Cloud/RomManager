#!/bin/sh
cd /mnt/SDCARD/App/RomManager

# Crash guard: the app runs as a child of this first copy of the script. Errors go to
# caches/rommanager.log, and if the app ever dies unexpectedly it's logged (with the
# screen it was on) and started again instead of dropping back to Onion. A normal exit
# (B on the main menu, or Onion asking it to close) ends it for good.
if [ -z "$RM_SUPERVISED" ]; then
    export RM_SUPERVISED=1
    mkdir -p caches
    RM_LOG="caches/rommanager.log"
    # Keep the log small: start a fresh one once it passes ~64KB
    [ "$(wc -c < "$RM_LOG" 2>/dev/null || echo 0)" -gt 65536 ] && mv -f "$RM_LOG" "$RM_LOG.old"
    echo "=== $(date) start" >> "$RM_LOG"
    restarts=0
    while :; do
        sh ./launch.sh "$@" 2>> "$RM_LOG"
        rc=$?
        killall rmui rmkey rmaudio ffplay 2>/dev/null
        [ "$rc" -eq 0 ] && exit 0
        # 75: an update was just installed (lib/update.sh) - start the new version
        if [ "$rc" -eq 75 ]; then
            echo "=== $(date) updated, restarting" >> "$RM_LOG"
            restarts=0
            continue
        fi
        echo "=== $(date) exited with code $rc on screen: $(cat /tmp/rm_state 2>/dev/null)" >> "$RM_LOG"
        # 137/143: killed by the system (power off, low battery) - don't come back
        case "$rc" in 137|143) exit "$rc" ;; esac
        restarts=$((restarts + 1))
        [ "$restarts" -ge 3 ] && exit "$rc"
    done
fi

# ==========================================
# 1. GLOBAL NAMESPACE & CONFIG
# ==========================================
export PATH="./bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH"
export LD_LIBRARY_PATH="./libs:./bin:/usr/lib:/customer/lib:/config/lib:/lib:$LD_LIBRARY_PATH"

RM_VERSION="2.1"
UI_FRAME="/tmp/ui_frame.txt"
# rmui is the new renderer; the original ui_renderer stays as a fallback.
UI_RENDERER="./bin/rmui"
[ -f "$UI_RENDERER" ] || UI_RENDERER="./bin/ui_renderer"
# Game titles are sent whole: rmui cuts them to fit and scrolls a long highlighted one.
# The old renderer can't, so it gets them cut to 28 characters.
ITEM_CHARS=200
[ "$UI_RENDERER" = "./bin/ui_renderer" ] && ITEM_CHARS=28
chmod +x ./bin/rmui ./bin/ui_renderer ./bin/rmkey ./bin/rmls ./bin/rmaudio ./bin/getkey 2>/dev/null
RMUI_FIFO="/tmp/rmui.fifo"
RMUI_PID=""

# Buttons: rmkey runs in the background and answers "get" requests (see src/rmkey).
# Without it, a key reader program is started for every press (rmkey, else getkey).
KEY_READER="./bin/rmkey"
[ -f "$KEY_READER" ] || KEY_READER="./bin/getkey"
RMKEY_REQ="/tmp/rmkey.req"
RMKEY_RESP="/tmp/rmkey.resp"
RMKEY_PID=""

# Sound: rmaudio plays the music and mixes button sounds over it (see src/rmaudio).
RMAUDIO_FIFO="/tmp/rmaudio.fifo"
RMAUDIO_PID=""

CACHE_DIR="/mnt/SDCARD/App/RomManager/caches"
RECENT_DL_FILE="$CACHE_DIR/recent_downloads.txt"
FAV_FILE="$CACHE_DIR/favorites.txt"
# repos.txt replaced archives.txt; an old archives.txt is converted on first launch.
SETTINGS_FILE="settings.ini"
SFX_DIR="/mnt/SDCARD/App/RomManager/sounds"
ROMS_DIR="/mnt/SDCARD/Roms"

# Files in a ROM folder that are not games: hidden files, Onion's list caches and
# custom-name lists, cover art, and folders (listed with "ls -p", so they end in "/":
# Imgs, and things like Ports' Games / Manuals / Shortcuts folders).
ROM_IGNORE="^\.|\.xml$|\.db$|^miyoocache\.bin$|\.png$|\.jpg$|\.txt$|\.json$|^Imgs$|/$"

mkdir -p "$CACHE_DIR/previews"
touch "$RECENT_DL_FILE"
touch "$FAV_FILE"

# Default Settings
BGM_ENABLED=1
SFX_ENABLED=1
UI_MAX_ITEMS=10
AUTO_SCRAPE=1
REPO_CACHE_DAYS=7
GAME_VIEW=list
AUDIO_OUT=auto
PREVIEW_CACHE_MB=40
START_SCREEN=menu  # what RomManager opens on: menu | installed | last (where you were)
HOME_STYLE=tiles   # tiles | list
MOTION=on          # on | off (animations)
LAUNCHER=1         # 1: games started here (and Onion's game switcher) come back here
SHOW_PERF=0        # 1: frames-per-second / CPU readout (settings.ini only)
DISCLAIMER_SEEN=0
AUTO_UPDATE=1      # 1: get new versions from GitHub by itself (lib/update.sh)
UPDATE_SKIP=""     # a version the player chose to skip

[ -f "$SETTINGS_FILE" ] && . "./$SETTINGS_FILE" # (with ./ - a bare name is looked for in PATH)

# Older settings: "reduced" animations are now just on; "After a Game: Onion Menu"
# is Default Launcher off
case "$MOTION" in off) ;; *) MOTION=on ;; esac
[ "$AFTER_GAME" = "onion" ] && LAUNCHER=0
AFTER_GAME=""

# Volumes 0-10 (0 = off). Older settings only had on/off: on becomes full volume.
[ -z "$BGM_VOLUME" ] && { [ "$BGM_ENABLED" -eq 1 ] && BGM_VOLUME=10 || BGM_VOLUME=0; }
[ -z "$SFX_VOLUME" ] && { [ "$SFX_ENABLED" -eq 1 ] && SFX_VOLUME=10 || SFX_VOLUME=0; }
BGM_ENABLED=0; [ "$BGM_VOLUME" -gt 0 ] && BGM_ENABLED=1
SFX_ENABLED=0; [ "$SFX_VOLUME" -gt 0 ] && SFX_ENABLED=1
STATUSBAR=""
LAST_FRAME_STATE=""
DL_WORKER_PID=""

UI_RENDER_NEEDED=1
UI_FRAME_BUF=""

# ==========================================
# 2. STATE GLOBALS
# ==========================================
STATE="MAIN_MENU"

MAIN_INDEX=0
DL_INDEX=0
INST_INDEX=0
INST_GAME_INDEX=0
REPO_INDEX=0
RECENT_INDEX=0
MISSING_INDEX=0
FAV_INDEX=0
SET_INDEX=0
CREDITS_INDEX=0
FOLDER_SELECT_INDEX=0
PREVIEW_REPO_INDEX=0

DL_KEY_LISTENER_PID=""

DL_CHOSEN_FOLDER=""
DL_CHOSEN_DISPLAY=""
DL_CONSOLE_INDEX=0
DL_FORCE_REFRESH=0
OSK_LAYER=0

INST_CHOSEN_FOLDER=""
INST_CHOSEN_DISPLAY=""

OSK_X=0
OSK_Y=0
OSK_BUF=""
OSK_UPPER=0
SEARCH_RETURN_STATE=""
DOWNLOAD_RETURN_STATE="DL_GAMES"

BGM_PID=""
SFX_PID=""

# Cached Audio Commands
CMD_BGM_MP3=""
CMD_BGM_WAV=""
CMD_SFX=""

# ==========================================
# 3. AUDIO ENGINE (INTERRUPTION & TIME RESUME)
# ==========================================

init_audio() {
    # Infinite native loops are removed so the script can track natural track completion
    if command -v madplay >/dev/null 2>&1; then
        CMD_BGM_MP3="madplay -q"
    elif command -v ffplay >/dev/null 2>&1; then
        CMD_BGM_MP3="ffplay -nodisp -autoexit"
    fi

    if command -v audplay >/dev/null 2>&1; then
        CMD_BGM_WAV="audplay"
        CMD_SFX="audplay"
    elif command -v ffplay >/dev/null 2>&1; then
        CMD_BGM_WAV="ffplay -nodisp -autoexit"
        CMD_SFX="ffplay -nodisp -autoexit"
    fi

    # Flush old hardware state configurations on initial boot execution
    rm -f /tmp/bgm_position /tmp/bgm_start_epoch /tmp/bgm_playing /tmp/bgm_interrupted /tmp/bgm_child.pid /tmp/sfx_child.pid
    echo "0" > /tmp/bgm_position

    start_audio_mixer
}

# rmaudio plays the music on a loop and mixes button sounds over it, so pressing a
# button never pauses the music. The Mini's sound chip takes only one player at a
# time (that's why the old code had to stop the music for every beep), so rmaudio
# makes one stream of everything and hands it to a single player:
#   1. ffplay (Onion ships it, and it's what the old code played the music with),
#      reading rmaudio's mix through a pipe - known to make sound on Onion
#   2. /dev/dsp through Onion's libpadsp.so + audioserver (how RetroArch does it)
# If neither starts, the old players below are used. AUDIO_OUT=dsp in settings.ini
# tries /dev/dsp first. What happened is written to caches/rommanager.log.
start_audio_mixer() {
    [ -f ./bin/rmaudio ] || return
    local music=""
    [ -f "$SFX_DIR/bgm.mp3" ] && music="$SFX_DIR/bgm.mp3"
    # A player left over from an earlier run (or one that got stuck) keeps the sound
    # device, and a new one then waits silently until it lets go - which is how the
    # music could start minutes late. Only one thing plays sound while we're open.
    killall rmaudio ffplay 2>/dev/null && sleep 0.2
    # (Stopping Onion's audio server first, as Onion's GMU player does, left no sound
    # at all - it stays running.) For the log: what we're starting with.
    local as="no"
    pidof audioserver >/dev/null 2>&1 && as="yes"
    echo "audio: starting - ffplay: $(command -v ffplay 2>/dev/null || echo none), Onion audio server running: $as, AUDIO_OUT=$AUDIO_OUT" >&2
    rm -f "$RMAUDIO_FIFO"
    mkfifo "$RMAUDIO_FIFO" 2>/dev/null || return
    local ffplay_cmd=$(command -v ffplay 2>/dev/null)
    local way try t err=/tmp/rm_audio.err
    # Right after boot the SD card is slow and Onion may still be letting go of the
    # speaker, so ffplay can take over a second to start - or start and then fail to
    # open the sound device. Each way is watched for 1.5s (an error or an exit means it
    # failed) and the pipe gets a few tries before falling back.
    for way in pipe pipe pipe dsp; do
        [ "$AUDIO_OUT" = "dsp" ] && [ "$way" = "pipe" ] && continue
        : > "$err"
        case "$way" in
            pipe)
                [ -n "$ffplay_cmd" ] || continue
                # In a subshell so its PID stands for the whole pipeline: it ends
                # when either side does
                (
                    ./bin/rmaudio -d "$RMAUDIO_FIFO" $music -o - </dev/null 2>>"$err" \
                        | "$ffplay_cmd" -nodisp -autoexit -loglevel error -fflags nobuffer -probesize 32 \
                            -analyzeduration 0 -f s16le -i pipe:0 >/dev/null 2>>"$err"
                ) &
                ;;
            dsp)
                [ -f /mnt/SDCARD/miyoo/lib/libpadsp.so ] || continue
                # (this way goes through Onion's audio server: start it again if needed)
                if ! pidof audioserver >/dev/null 2>&1 && [ -x /mnt/SDCARD/miyoo/app/audioserver ]; then
                    /mnt/SDCARD/miyoo/app/audioserver </dev/null >/dev/null 2>&1 &
                    sleep 0.5
                fi
                # libpadsp.so needs Onion's own libraries next to it
                LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so \
                    LD_LIBRARY_PATH="/mnt/SDCARD/miyoo/lib:/config/lib:/customer/lib:/lib:/usr/lib" \
                    ./bin/rmaudio -d "$RMAUDIO_FIFO" $music </dev/null >/dev/null 2>>"$err" &
                ;;
        esac
        RMAUDIO_PID=$!
        # (rmaudio starts with a second of silence, so the player has to open the
        # sound device within this time - and rmaudio reports one that's stuck)
        t=0
        while [ $t -lt 12 ] && kill -0 "$RMAUDIO_PID" 2>/dev/null && ! grep -qi "fail\|error\|cannot\|could not\|stalled" "$err" 2>/dev/null; do
            sleep 0.15
            t=$((t + 1))
        done
        cat "$err" >&2
        if [ $t -ge 12 ] && kill -0 "$RMAUDIO_PID" 2>/dev/null; then
            exec 9<>"$RMAUDIO_FIFO"
            audio_apply_volume
            echo "audio: mixing music + sounds, output: $way" >&2
            return
        fi
        kill_tree "$RMAUDIO_PID"
        echo "audio: output '$way' didn't start" >&2
        sleep 0.3
    done
    echo "audio: using the old players ($CMD_BGM_MP3 / $CMD_SFX) - music pauses for button sounds" >&2
    RMAUDIO_PID=""
}

audio_mixer_alive() {
    [ -n "$RMAUDIO_PID" ] && kill -0 "$RMAUDIO_PID" 2>/dev/null
}

# Sends the volume settings to the mixer (0-10 each).
audio_apply_volume() {
    audio_mixer_alive || return
    echo "vol music $BGM_VOLUME" >&9
    echo "vol sfx $SFX_VOLUME" >&9
}

# Volume option for the old players: only ffplay has one (-volume 0-100, squared like
# rmaudio's, so the steps sound even).
ff_volume() {
    case "$1" in *ffplay*) echo "-volume $(( $2 * $2 ))" ;; esac
}

# Volume bars for a settings row: "{BAR:n/10}", drawn by rmui (text for the old renderer)
volume_bar() {
    if [ "$ITEM_CHARS" -gt 28 ]; then
        echo "{BAR:$1/10}"
    elif [ "$1" -eq 0 ]; then
        echo "[OFF]"
    else
        echo "[$1/10]"
    fi
}

# If the mixer stops after it started (the player lost the sound device), start it
# again with the music - up to 3 times, so a broken setup can't stall every press.
AUDIO_RESTARTS=0
audio_check() {
    [ -n "$RMAUDIO_PID" ] || return
    kill -0 "$RMAUDIO_PID" 2>/dev/null && return
    exec 9>&-
    RMAUDIO_PID=""
    [ "$AUDIO_RESTARTS" -ge 3 ] && return
    AUDIO_RESTARTS=$((AUDIO_RESTARTS + 1))
    echo "audio: the mixer stopped - restarting it" >&2
    start_audio_mixer
    start_bgm
}

start_bgm() {
    [ "$BGM_ENABLED" -eq 0 ] && return
    if audio_mixer_alive; then
        echo "bgm on" >&9
        return
    fi

    # Old players: do nothing if the music loop is already running. (Checking the
    # player alone wasn't enough - a button sound briefly stops it, so a second loop
    # got started and two copies of the song fought over the speaker.)
    if [ -n "$BGM_PID" ] && kill -0 "$BGM_PID" 2>/dev/null; then
        return
    fi

    touch /tmp/bgm_playing
    rm -f /tmp/bgm_child.pid

    # The Positional Management Loop Worker
    (
        while [ -f /tmp/bgm_playing ]; do
            # Hold loop playback if navigation is actively occurring
            while [ -f /tmp/bgm_interrupted ]; do
                sleep 0.1
            done

            local offset=$(cat /tmp/bgm_position 2>/dev/null || echo 0)
            local seek_flag=""

            # Format custom seek strings dynamically depending on binary system state
            if [ "$offset" -gt 0 ]; then
                case "$CMD_BGM_MP3" in *madplay*) seek_flag="-s $offset" ;; *ffplay*) seek_flag="-ss $offset" ;; esac
                case "$CMD_BGM_WAV" in *ffplay*)  seek_flag="-ss $offset" ;; esac
            fi

            # Execute targets and map start time references
            local started=$(date +%s)
            if [ -f "$SFX_DIR/bgm.mp3" ] && [ -n "$CMD_BGM_MP3" ]; then
                echo "$started" > /tmp/bgm_start_epoch
                $CMD_BGM_MP3 $seek_flag $(ff_volume "$CMD_BGM_MP3" "$BGM_VOLUME") "$SFX_DIR/bgm.mp3" </dev/null >/dev/null 2>&1 &
                echo $! > /tmp/bgm_child.pid
                wait $!
            elif [ -f "$SFX_DIR/bgm.wav" ] && [ -n "$CMD_BGM_WAV" ]; then
                local filesize=$(wc -c < "$SFX_DIR/bgm.wav" 2>/dev/null | tr -d ' ')
                if [ "$filesize" -gt 1000 ]; then
                    echo "$started" > /tmp/bgm_start_epoch
                    $CMD_BGM_WAV $seek_flag $(ff_volume "$CMD_BGM_WAV" "$BGM_VOLUME") "$SFX_DIR/bgm.wav" </dev/null >/dev/null 2>&1 &
                    echo $! > /tmp/bgm_child.pid
                    wait $!
                fi
            else
                break
            fi

            # Song finished by itself (not stopped for a button sound): start over.
            # A player that quits straight away (a resume point past the end) also
            # means start over - otherwise the music could stop for good.
            if [ -f /tmp/bgm_playing ] && [ ! -f /tmp/bgm_interrupted ]; then
                echo "0" > /tmp/bgm_position
            elif [ "$(date +%s)" -eq "$started" ] && [ "$offset" -gt 0 ]; then
                echo "0" > /tmp/bgm_position
            fi

            sleep 0.4
        done
    ) &
    BGM_PID=$!
}

stop_bgm() {
    if audio_mixer_alive; then
        echo "bgm off" >&9
        return
    fi
    rm -f /tmp/bgm_playing
    rm -f /tmp/bgm_interrupted
    if [ -f /tmp/bgm_child.pid ]; then
        kill $(cat /tmp/bgm_child.pid) 2>/dev/null
        rm -f /tmp/bgm_child.pid
    fi
    if [ -n "$BGM_PID" ]; then
        kill "$BGM_PID" 2>/dev/null
        BGM_PID=""
    fi
    killall audplay madplay ffplay 2>/dev/null
    echo "0" > /tmp/bgm_position
}

stop_audio() {
    stop_bgm
    if audio_mixer_alive; then
        echo "quit" >&9
    fi
    RMAUDIO_PID=""
}

trap "shutdown_app" INT TERM QUIT
# Writing to a helper that has just died must not kill the app (render_ui copes).
trap "" PIPE

play_sound() {
    audio_check
    [ "$SFX_ENABLED" -eq 0 ] && return
    local sound_file="$SFX_DIR/$1.wav"
    if audio_mixer_alive; then
        echo "sfx $sound_file" >&9
        return
    fi
    [ -f "$sound_file" ] || return
    [ -z "$CMD_SFX" ] && return

    # Old players: while a sound is still playing, skip the new one. Killing and
    # restarting players on every quick press left the sound chip busy and all sound
    # stopped.
    if [ -n "$SFX_PID" ] && kill -0 "$SFX_PID" 2>/dev/null; then
        return
    fi

    (
        touch /tmp/bgm_interrupted

        # Capture and save elapsed track runtime parameters before applying hard break
        if [ -f /tmp/bgm_child.pid ]; then
            local bgm_child=$(cat /tmp/bgm_child.pid)
            if [ -n "$bgm_child" ] && kill -0 "$bgm_child" 2>/dev/null; then
                local start_epoch=$(cat /tmp/bgm_start_epoch 2>/dev/null || date +%s)
                local now=$(date +%s)
                local elapsed=$((now - start_epoch))
                [ "$elapsed" -lt 0 ] && elapsed=0

                local current_pos=$(cat /tmp/bgm_position 2>/dev/null || echo 0)
                echo $((current_pos + elapsed)) > /tmp/bgm_position

                kill -9 "$bgm_child" 2>/dev/null
            fi
        fi

        sleep 0.04

        # Fire UI Sound effect
        $CMD_SFX $(ff_volume "$CMD_SFX" "$SFX_VOLUME") "$sound_file" </dev/null >/dev/null 2>&1 &
        local sfx_child=$!
        echo $sfx_child > /tmp/sfx_child.pid
        wait $sfx_child

        # Added delay here to prevent BGM from jarringly cutting in/out on single quick button presses
        sleep 0.2
        rm -f /tmp/bgm_interrupted
    ) &
    SFX_PID=$!
}

# ==========================================
# 4. CENTRALIZED HELPERS
# ==========================================

save_settings() {
    echo "BGM_VOLUME=$BGM_VOLUME" > "$SETTINGS_FILE"
    echo "SFX_VOLUME=$SFX_VOLUME" >> "$SETTINGS_FILE"
    echo "UI_MAX_ITEMS=$UI_MAX_ITEMS" >> "$SETTINGS_FILE"
    echo "AUTO_SCRAPE=$AUTO_SCRAPE" >> "$SETTINGS_FILE"
    echo "REPO_CACHE_DAYS=$REPO_CACHE_DAYS" >> "$SETTINGS_FILE"
    echo "GAME_VIEW=$GAME_VIEW" >> "$SETTINGS_FILE"
    echo "AUDIO_OUT=$AUDIO_OUT" >> "$SETTINGS_FILE"
    echo "PREVIEW_CACHE_MB=$PREVIEW_CACHE_MB" >> "$SETTINGS_FILE"
    echo "START_SCREEN=$START_SCREEN" >> "$SETTINGS_FILE"
    echo "HOME_STYLE=$HOME_STYLE" >> "$SETTINGS_FILE"
    echo "MOTION=$MOTION" >> "$SETTINGS_FILE"
    echo "LAUNCHER=$LAUNCHER" >> "$SETTINGS_FILE"
    echo "SHOW_PERF=$SHOW_PERF" >> "$SETTINGS_FILE"
    echo "DISCLAIMER_SEEN=$DISCLAIMER_SEEN" >> "$SETTINGS_FILE"
    echo "AUTO_UPDATE=$AUTO_UPDATE" >> "$SETTINGS_FILE"
    echo "UPDATE_SKIP=$UPDATE_SKIP" >> "$SETTINGS_FILE"
    theme_settings

    if [ "$BGM_ENABLED" -eq 0 ]; then stop_bgm; else start_bgm; fi
}

# The settings rmui gets with every frame, worked out once when they change
theme_settings() {
    case "$MOTION" in off) MOTION_N=0 ;; *) MOTION_N=2 ;; esac
    PERF_LINE=""
    [ "$SHOW_PERF" = "1" ] && PERF_LINE="PERF:1\n"
}

wifi_on() {
    local st=""
    # (checked first: a failed "<" prints an error before any 2>/dev/null applies)
    [ -r /sys/class/net/wlan0/operstate ] && read -r st < /sys/class/net/wlan0/operstate
    [ "$st" = "up" ]
}

# Wi-Fi, battery and free space for the top-right corner. Run now and then (main menu,
# after downloads), not per frame - it reads a few files and runs df.
update_statusbar() {
    local s b=""
    if wifi_on; then s="{WIFI}"; else s="{NOWIFI}"; fi
    # Onion keeps the battery level here
    [ -r /tmp/percBat ] && read -r b < /tmp/percBat
    case "$b" in ''|*[!0-9]*) ;; *) s="$s {BATT:$b}" ;; esac
    local kb=$(free_space_kb /mnt/SDCARD)
    case "$kb" in ''|*[!0-9]*) ;; *) s="$s $(format_size $((kb * 1024)) | tr -d ' ')" ;; esac
    STATUSBAR="$s"
}

# A short notice that slides down at the top and goes away by itself - the screen
# stays usable meanwhile. $1: ok | err | info, $2: text.
toast() {
    if [ -n "$RMUI_PID" ] && kill -0 "$RMUI_PID" 2>/dev/null; then
        printf 'TOAST:%s:%s\n' "$1" "$2" >&6
    else
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$2\nART:NULL\n"
        render_ui
        sleep 1
    fi
}

# How deep a screen is, so moving to another one slides the right way (deeper: push,
# back: pop, same level: fade)
state_depth() {
    case "$1" in
        MAIN_MENU) DEPTH=0 ;;
        DL_CONSOLES|INST_CONSOLES|FAVORITES|RECENT_DOWNLOADS|MANAGE_REPOS|SETTINGS|DOWNLOADS) DEPTH=1 ;;
        SEARCH_GAMES|DL_FILTER|REPO_PICK_CONSOLE|PACK_CONFIRM|IA_LOGIN_PASS) DEPTH=3 ;;
        *) DEPTH=2 ;;
    esac
}

# Starts rmkey in the background. It keeps the buttons open, so presses made while the
# screen is being drawn aren't missed, and asking it for a key is just a line written
# to a pipe - no new program per press.
start_input() {
    [ "$KEY_READER" = "./bin/rmkey" ] || return
    rm -f "$RMKEY_REQ" "$RMKEY_RESP"
    mkfifo "$RMKEY_REQ" "$RMKEY_RESP" 2>/dev/null || return
    ./bin/rmkey -d "$RMKEY_REQ" "$RMKEY_RESP" </dev/null >/dev/null 2>&1 &
    RMKEY_PID=$!
    sleep 0.1
    if kill -0 "$RMKEY_PID" 2>/dev/null; then
        exec 7<>"$RMKEY_REQ" 8<>"$RMKEY_RESP"
    else
        echo "input: rmkey couldn't start, reading keys with $KEY_READER" >&2
        RMKEY_PID=""
    fi
}

stop_input() {
    if [ -n "$RMKEY_PID" ] && kill -0 "$RMKEY_PID" 2>/dev/null; then
        echo "quit" >&7
    fi
    RMKEY_PID=""
}

# Forgets presses made so far - after a task that read the buttons itself (the B that
# cancelled it shouldn't also count as "back" on the next screen).
flush_keys() {
    [ -n "$RMKEY_PID" ] && echo "flush" >&7
}

# Waits for a button and puts its name in KEY. $1: give up after this many ms
# (returns 1 with KEY empty) - for screens that animate while waiting.
get_key() {
    if [ -n "$RMKEY_PID" ] && kill -0 "$RMKEY_PID" 2>/dev/null; then
        echo "get ${1:--1}" >&7
        read -r KEY <&8
        [ "$KEY" = "none" ] && KEY=""
    elif [ -n "$1" ] && [ "$KEY_READER" = "./bin/rmkey" ]; then
        KEY=$(./bin/rmkey -t "$1")
    else
        RMKEY_PID=""
        KEY=$($KEY_READER)
        [ -z "$KEY" ] && sleep 0.08
    fi
    # Menu opens Onion's game switcher from anywhere (as it does in Onion's menu)
    if [ "$KEY" = "menu" ]; then
        KEY=""
        open_game_switcher
    fi
    [ -n "$KEY" ]
}

# Moves a list selection: up/down by one (wrapping), left/right by a page. Sets SEL.
# (Not "echo" + $(...): that started a subshell on every button press.)
update_selection() {
    local key="$1"
    local total="$2"
    local max="$3"
    SEL="$4"
    [ "$total" -le 0 ] && total=1
    case "$key" in
        down) SEL=$((SEL + 1)); [ "$SEL" -ge "$total" ] && SEL=0 ;;
        up) SEL=$((SEL - 1)); [ "$SEL" -lt 0 ] && SEL=$((total - 1)) ;;
        right) SEL=$((SEL + max)); [ "$SEL" -ge "$total" ] && SEL=$((total - 1)) ;;
        left) SEL=$((SEL - max)); [ "$SEL" -lt 0 ] && SEL=0 ;;
    esac
}

handle_osk_navigation() {
    case "$KEY" in
        right) OSK_X=$((OSK_X + 1)); [ "$OSK_X" -gt 6 ] && OSK_X=0 ;;
        left) OSK_X=$((OSK_X - 1)); [ "$OSK_X" -lt 0 ] && OSK_X=6 ;;
        down) OSK_Y=$((OSK_Y + 1)); [ "$OSK_Y" -gt 5 ] && OSK_Y=0 ;;
        up) OSK_Y=$((OSK_Y - 1)); [ "$OSK_Y" -lt 0 ] && OSK_Y=5 ;;
        R) OSK_UPPER=$((1 - OSK_UPPER)) ;;
    esac
}

build_theme() {
    local sb="$STATUSBAR"
    # A download running in the background: rmui shows its progress (it reads the
    # progress file itself, so this needs no redraws from here)
    [ -n "$DL_WORKER_PID" ] && kill -0 "$DL_WORKER_PID" 2>/dev/null && sb="{DL} $sb"
    UI_FRAME_BUF="THEME_BG:0xFF051105\nTHEME_TEXT:0xFF33FF33\nTHEME_HL:0xFF33FF33\nTHEME_HL_TEXT:0xFF051105\nTHEME_DIM:0xFF33FF33\nFONT:/mnt/SDCARD/App/RomManager/ui/font.ttf:22\nBACKGROUND:/mnt/SDCARD/App/RomManager/ui/bg.png\nTITLE:ROM MANAGER\nMOTION:${MOTION_N:-2}\n${PERF_LINE}STATUSBAR:$sb\n"
}

render_ui() {
    # Moving to another screen: say which way, so rmui can slide to it
    if [ "$STATE" != "$LAST_FRAME_STATE" ]; then
        if [ -n "$LAST_FRAME_STATE" ]; then
            local old new
            state_depth "$LAST_FRAME_STATE"; old=$DEPTH
            state_depth "$STATE"; new=$DEPTH
            if [ "$new" -gt "$old" ]; then
                UI_FRAME_BUF="${UI_FRAME_BUF}TRANSITION:push\n"
            elif [ "$new" -lt "$old" ]; then
                UI_FRAME_BUF="${UI_FRAME_BUF}TRANSITION:pop\n"
            else
                UI_FRAME_BUF="${UI_FRAME_BUF}TRANSITION:fade\n"
            fi
        fi
        LAST_FRAME_STATE=$STATE
    fi
    if [ -n "$RMUI_PID" ] && kill -0 "$RMUI_PID" 2>/dev/null; then
        # The renderer is running in the background: hand it the frame through its pipe.
        printf "%bEND\n" "$UI_FRAME_BUF" >&6
        # Back from a game: the sound starts once the first screen is up
        if [ "$AUDIO_DEFERRED" = "1" ]; then
            AUDIO_DEFERRED=0
            init_audio
            start_bgm
        fi
    else
        if [ -n "$RMUI_PID" ]; then
            # It stopped (crashed?): note it in the log and start a new one
            echo "renderer stopped unexpectedly on screen $STATE - restarting it" >&2
            RMUI_PID=""
            start_renderer
        fi
        if [ -n "$RMUI_PID" ]; then
            printf "%bEND\n" "$UI_FRAME_BUF" >&6
        else
            printf "%b" "$UI_FRAME_BUF" > "$UI_FRAME"
            $UI_RENDERER "$UI_FRAME"
        fi
    fi
    UI_RENDER_NEEDED=0
}

# Starts rmui in the background. It keeps the font, background and covers loaded
# between screens (the one-shot renderer reloads them for every frame) and animates
# cover flow by itself. If it can't start, render_ui falls back to one-shot drawing.
start_renderer() {
    [ "$UI_RENDERER" = "./bin/rmui" ] || return
    [ "${RMUI_STARTS:-0}" -ge 3 ] && return
    RMUI_STARTS=$((${RMUI_STARTS:-0} + 1))
    rm -f "$RMUI_FIFO"
    mkfifo "$RMUI_FIFO" 2>/dev/null || return
    ./bin/rmui -d "$RMUI_FIFO" >/dev/null &
    RMUI_PID=$!
    # If it exits straight away (e.g. it can't open the screen), use one-shot drawing.
    sleep 0.2
    if kill -0 "$RMUI_PID" 2>/dev/null; then
        # Kept open (read-write, so it never blocks) instead of reopening per frame
        exec 6<>"$RMUI_FIFO"
    else
        RMUI_PID=""
    fi
}

stop_renderer() {
    if [ -n "$RMUI_PID" ] && kill -0 "$RMUI_PID" 2>/dev/null; then
        echo "QUIT" >&6
        sleep 0.1
        kill "$RMUI_PID" 2>/dev/null
    fi
    RMUI_PID=""
    rm -f "$RMUI_FIFO"
}

shutdown_app() {
    save_spot
    dl_worker_stop
    stop_renderer
    stop_audio
    stop_input
    exit 0
}

invalidate_game_cache() {
    rm -f "$CACHE_DIR/current_games.cache"
    rm -f "$CACHE_DIR/current_games_full.cache"
}

# Favorites are "folder|file|title" lines, identified by folder + file only. Matching on
# exact fields (not substrings) stops "Mario.zip" from also matching "Super Mario.zip".
is_favorite() {
    awk -F'|' -v f="$1" -v n="$2" '$1==f && $2==n { found=1; exit } END { exit !found }' "$FAV_FILE" 2>/dev/null
}

remove_favorite() {
    awk -F'|' -v f="$1" -v n="$2" 'NF && !($1==f && $2==n)' "$FAV_FILE" > "$FAV_FILE.tmp" 2>/dev/null
    mv "$FAV_FILE.tmp" "$FAV_FILE"
}

toggle_favorite() {
    if is_favorite "$1" "$2"; then
        remove_favorite "$1" "$2"
    else
        echo "$1|$2|$3" >> "$FAV_FILE"
    fi
}

# Kills a process and everything it started. Killing only a background subshell leaves
# its children running - an orphaned curl keeps downloading, and an orphaned getkey
# silently swallows the next button press.
kill_tree() {
    local parent="$1" child
    [ -z "$parent" ] && return
    for child in $(cat /proc/[0-9]*/stat 2>/dev/null | awk -v p="$parent" '$4==p { print $1 }'); do
        kill_tree "$child"
    done
    kill -9 "$parent" 2>/dev/null
}

# Background listener that creates $1 when B is pressed, for cancelling long tasks.
start_cancel_listener() {
    local flag="$1"
    rm -f "$flag"
    (
        while :; do
            k=$($KEY_READER)
            if [ "$k" = "B" ]; then
                touch "$flag"
                break
            fi
        done
    ) &
    CANCEL_LISTENER_PID=$!
}

stop_cancel_listener() {
    kill_tree "$CANCEL_LISTENER_PID"
    CANCEL_LISTENER_PID=""
    flush_keys
}

# Onion caches each game list in <folder>_cache6.db / _cache2.db (see Onion's
# reset_list.sh). Deleting them makes new or removed games show up straight away.
refresh_onion_list() {
    local dir="$ROMS_DIR/$1"
    rm -f "$dir/${1}_cache6.db" "$dir/${1}_cache2.db" "$dir/miyoocache.bin"
}

# The games in a ROM folder, sorted. rmls reads the folder once; "ls -p" looked up
# every file, which on the SD card took seconds for a folder of thousands of games.
list_rom_folder() {
    if [ -x ./bin/rmls ]; then
        ./bin/rmls list "$ROMS_DIR/$1" 2>/dev/null
    else
        ls -1p "$ROMS_DIR/$1" 2>/dev/null | grep -ivE "$ROM_IGNORE"
    fi
}

# Filters the full list into the current one. Every space-separated word must appear
# (in any order, any case), so "mario 3" finds "Super Mario Bros. 3".
apply_search_filter() {
    if [ ${#OSK_BUF} -ge 2 ]; then
        awk -v q="$OSK_BUF" '
            BEGIN { n = split(tolower(q), words, " ") }
            {
                line = tolower($0)
                for (i = 1; i <= n; i++) if (index(line, words[i]) == 0) next
                print
            }' "$CACHE_DIR/current_games_full.cache" > "$CACHE_DIR/current_games.cache"
    else
        cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
    fi
}

# Adds a line to the top of a short on-screen history list, keeping it at 8 lines.
# (Inserting with sed into an ever-growing file rewrote it once per item.)
push_history() {
    { echo "$2"; head -n 7 "$1" 2>/dev/null; } > "$1.tmp"
    mv "$1.tmp" "$1"
}

# The 42 keys (7 x 6) of the on-screen keyboard's current layer, space-separated.
# Layer 0 is letters (capitals when OSK_UPPER=1); layer 1 is symbols for typing
# addresses. The bottom row ends with the control keys: Caps/ABC, Del, Esc, OK.
osk_keys() {
    if [ "${OSK_LAYER:-0}" = 1 ]; then
        echo ". / : @ - _ ~ ? = & % + # ! ( ) [ ] , ; ' 0 1 2 3 4 5 6 7 8 9 SPC * \$ ^ . / : ABC DEL ESC OK"
    elif [ "$OSK_UPPER" -eq 1 ]; then
        echo "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z - _ 0 1 2 3 4 5 6 7 8 9 CAPS DEL ESC OK"
    else
        echo "a b c d e f g h i j k l m n o p q r s t u v w x y z - _ 0 1 2 3 4 5 6 7 8 9 CAPS DEL ESC OK"
    fi
}

# Character under the keyboard cursor, or empty for the control keys.
osk_char() {
    local key=$(osk_keys | cut -d' ' -f$((OSK_Y * 7 + OSK_X + 1)))
    case "$key" in
        CAPS|ABC|DEL|ESC|OK) ;;
        SPC) printf ' ' ;;
        *) printf '%s' "$key" ;;
    esac
}

free_space_kb() {
    df -k "$1" 2>/dev/null | tail -n 1 | awk '{ print $(NF-2) }'
}

format_size() {
    local bytes="$1"
    case "$bytes" in ''|*[!0-9]*) echo "size unknown"; return ;; esac
    if [ "$bytes" -eq 0 ]; then
        echo "size unknown"
    elif [ "$bytes" -ge 1073741824 ]; then
        echo "$((bytes / 1073741824)).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576)).$(( (bytes % 1048576) * 10 / 1048576 )) MB"
    else
        echo "$(( (bytes + 1023) / 1024 )) KB"
    fi
}

# Adds cover-flow lines to the frame for the games around position $1.
#   $1 selected index   $2 total games   $3 list file
#   $4 "dl" (download list: field 1 is the title), "inst" (installed: a file name) or
#      "multi" (favorites / recent: "folder|file|title" lines, any console)
#   $5 ROM folder (not used for "multi")
# Covers missing from the cache are written to .cover_wanted (nearest first) so
# start_cover_fetch can download them in the background.
append_coverflow() {
    local sel=$1 total=$2 list=$3 mode=$4 folder=$5 f2 f3
    local lo=$((sel - 8)) hi=$((sel + 10))
    # After a page jump the covers in between are sent too, so they can slide past
    local last="${CF_LAST_SEL:-$sel}"
    if [ "$last" -ne "$sel" ] && [ $((last - sel)) -le 40 ] && [ $((sel - last)) -le 40 ]; then
        [ "$last" -lt "$sel" ] && lo=$((last - 4))
        [ "$last" -gt "$sel" ] && hi=$((last + 5))
    fi
    CF_LAST_SEL=$sel
    [ $lo -lt 0 ] && lo=0
    local target_dir="$ROMS_DIR/$folder"
    local idx name base path dist label=""

    UI_FRAME_BUF="${UI_FRAME_BUF}COVERFLOW:$sel:$total:$STATE-$folder\n"
    : > "$CACHE_DIR/.cover_wanted"
    while IFS='|' read -r idx name f2 f3; do
        [ -z "$idx" ] && continue
        base="$name"
        [ "$mode" = "inst" ] && base="${name%.*}"
        if [ "$mode" = "multi" ]; then
            target_dir="$ROMS_DIR/$name"
            base="${f2%.*}"
        fi
        path="BLANK"
        if [ -s "$target_dir/Imgs/$base.png" ]; then
            path="$target_dir/Imgs/$base.png"
        elif [ -s "$CACHE_DIR/previews/$base.png" ]; then
            path="$CACHE_DIR/previews/$base.png"
        elif [ "$mode" = "dl" ] && [ ! -f "$CACHE_DIR/previews/$base.png.none" ]; then
            dist=$((idx - sel))
            dist=${dist#-}
            [ "$dist" -le 6 ] && echo "$dist|$base" >> "$CACHE_DIR/.cover_wanted"
        fi
        UI_FRAME_BUF="${UI_FRAME_BUF}COVER:$idx:$path\n"
        if [ "$idx" -eq "$sel" ]; then
            label="$base"
            [ "$mode" = "multi" ] && label="${f3:-$base}  - $(get_console_name "$name")"
        fi
    done <<EOF
$(awk -F'|' -v lo=$((lo + 1)) -v hi=$((hi + 1)) -v m="$mode" 'NR >= lo && NR <= hi { print NR - 1 "|" $1 ((m == "multi") ? "|" $2 "|" $3 : "") } NR > hi { exit }' "$list")
EOF
    UI_FRAME_BUF="${UI_FRAME_BUF}CFLABEL:$label${6:+  - $6}\n"
}

# Downloads the covers listed in .cover_wanted in the background, nearest first.
# Three workers share the queue (most of a cover's time is waiting on the server, so
# three at once fill a new list about three times as fast). Each re-reads .cover_queue
# before every cover, so when the selection moves they just switch to the new covers -
# no stopping and restarting them. A worker claims a cover by making a folder for it
# (mkdir is all-or-nothing), so two never fetch the same one. Each touches .cover_new
# after a cover it gets, so the screen knows to redraw.
COVER_WORKERS=3
COVER_FETCH_PIDS=""
start_cover_fetch() {
    [ -s "$CACHE_DIR/.cover_wanted" ] || return
    local sys=$(get_libretro_system "$DL_CHOSEN_FOLDER")
    [ -z "$sys" ] && return
    sort -n "$CACHE_DIR/.cover_wanted" | awk -F'|' -v s="$sys" '{ sub(/^[^|]*\|/, ""); print s "|" $0 }' \
        > "$CACHE_DIR/.cover_queue.tmp"
    mv -f "$CACHE_DIR/.cover_queue.tmp" "$CACHE_DIR/.cover_queue"
    local pid alive="" n=0
    for pid in $COVER_FETCH_PIDS; do
        kill -0 "$pid" 2>/dev/null && { alive="$alive $pid"; n=$((n + 1)); }
    done
    # none running: claims left by stopped workers are stale
    [ "$n" -eq 0 ] && rm -rf "$CACHE_DIR/.cover_claims"
    mkdir -p "$CACHE_DIR/.cover_claims"
    while [ "$n" -lt "$COVER_WORKERS" ]; do
        cover_worker </dev/null >/dev/null 2>&1 &
        alive="$alive $!"
        n=$((n + 1))
    done
    COVER_FETCH_PIDS=$alive
}

cover_worker() {
    local s t next claim
    while :; do
        next=""
        while IFS='|' read -r s t; do
            [ -s "$CACHE_DIR/previews/$t.png" ] && continue
            [ -f "$CACHE_DIR/previews/$t.png.none" ] && continue
            claim="$CACHE_DIR/.cover_claims/$(printf '%s' "$t" | tr -c 'A-Za-z0-9._-' '_')"
            mkdir "$claim" 2>/dev/null || continue
            next="$s|$t"
            break
        done < "$CACHE_DIR/.cover_queue"
        [ -z "$next" ] && break
        fetch_libretro_art_preview "${next%%|*}" "${next#*|}" "$CACHE_DIR/previews/${next#*|}.png"
        [ -s "$CACHE_DIR/previews/${next#*|}.png" ] && touch "$CACHE_DIR/.cover_new"
        # (the claim stays: removing it let another worker that had just looked fetch
        # the same cover again)
    done
    trim_preview_cache
}

# Stops cover downloads (they'd only slow a game download down). The worker finishes
# the cover it's on and then finds nothing left to do.
stop_cover_fetch() {
    : > "$CACHE_DIR/.cover_queue" 2>/dev/null
}

# Arrow keys in cover flow: left/right step one game, up/down jump a page.
coverflow_key() {
    case "$KEY" in
        left) KEY=up ;;
        right) KEY=down ;;
        up) KEY=left ;;
        down) KEY=right ;;
    esac
}

toggle_game_view() {
    if [ "$GAME_VIEW" = "covers" ]; then GAME_VIEW=list; else GAME_VIEW=covers; fi
    save_settings
}

# A message. With rmui running it's a notice that slides in and goes away by itself
# (no waiting) - looking like success or a problem depending on what it says.
show_message() {
    if [ -n "$RMUI_PID" ] && kill -0 "$RMUI_PID" 2>/dev/null; then
        local kind=info
        case "$1" in
            *[Cc]ouldn*|*[Ff]ail*|No\ *|*[Ww]rong*|*"t reach"*|*" not "*|*[Cc]ancelled*|*first*|*" no "*) kind=err ;;
            *[Ss]aved*|*" is on"*|*"Logged in"*|*[Cc]leared*|*[Rr]ebuilt*|*[Dd]eleted*|*[Ff]inished*|*[Cc]omplete*) kind=ok ;;
        esac
        toast "$kind" "$1"
        return
    fi
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$1\nART:${3:-NULL}\n"
    render_ui
    sleep "${2:-1.5}"
}

url_decode() {
    printf '%s' "$1" | awk '
        function hexval(c) {
            if (c ~ /[0-9]/) return c + 0
            c = toupper(c)
            if (c == "A") return 10
            if (c == "B") return 11
            if (c == "C") return 12
            if (c == "D") return 13
            if (c == "E") return 14
            if (c == "F") return 15
            return 0
        }
        {
            s = $0
            result = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "%" && i + 2 <= length(s)) {
                    result = result sprintf("%c", hexval(substr(s, i+1, 1)) * 16 + hexval(substr(s, i+2, 1)))
                    i += 2
                } else {
                    result = result c
                }
            }
            printf "%s", result
        }'
}

# ==========================================
# 5. DATA LOGIC HELPERS
# ==========================================

get_libretro_system() {
    local folder_key=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    case "$folder_key" in
        "GBA") echo "Nintendo%20-%20Game%20Boy%20Advance" ;;
        "PS") echo "Sony%20-%20PlayStation" ;;
        "FC") echo "Nintendo%20-%20Nintendo%20Entertainment%20System" ;;
        "SFC"|"SNES"|SATELLAVIEW) echo "Nintendo%20-%20Super%20Nintendo%20Entertainment%20System" ;;
        "GB") echo "Nintendo%20-%20Game%20Boy" ;;
        "GBC") echo "Nintendo%20-%20Game%20Boy%20Color" ;;
        "MD") echo "Sega%20-%20Mega%20Drive%20-%20Genesis" ;;
        "GG") echo "Sega%20-%20Game%20Gear" ;;
        "SMS") echo "Sega%20-%20Master%20System%20-%20Mark%20III" ;;
        "PCE") echo "NEC%20-%20PC%20Engine%20-%20TurboGrafx%2016" ;;
        "NEOGEO") echo "SNK%20-%20Neo%20Geo" ;;
        "ARCADE") echo "MAME" ;;
        "MS"|"SMS") echo "Sega%20-%20Master%20System%20-%20Mark%20III" ;;
        "ATARI"|"ATARI2600") echo "Atari%20-%202600" ;;
        "SEVENTYEIGHTHUNDRED"|"ATARI7800") echo "Atari%20-%207800" ;;
        "FIFTYTWOHUNDRED") echo "Atari%20-%205200" ;;
        "LYNX"|"ATARILYNX") echo "Atari%20-%20Lynx" ;;
        "THIRTYTWOX"|"32X") echo "Sega%20-%2032X" ;;
        "SEGACD") echo "Sega%20-%20Mega-CD%20-%20Sega%20CD" ;;
        "SEGASGONE") echo "Sega%20-%20SG-1000" ;;
        "NDS") echo "Nintendo%20-%20Nintendo%20DS" ;;
        "FDS") echo "Nintendo%20-%20Family%20Computer%20Disk%20System" ;;
        "VB") echo "Nintendo%20-%20Virtual%20Boy" ;;
        "POKE"|"POKEFAMI") echo "Nintendo%20-%20Pokemon%20Mini" ;;
        "SGB") echo "Nintendo%20-%20Super%20Nintendo%20Entertainment%20System" ;;
        "NGP"|"NGPC") echo "SNK%20-%20Neo%20Geo%20Pocket%20Color" ;;
        "NEOCD") echo "SNK%20-%20Neo%20Geo%20CD" ;;
        "WS"|"WSC") echo "Bandai%20-%20WonderSwan%20Color" ;;
        "PCECD") echo "NEC%20-%20PC%20Engine%20CD%20-%20TurboGrafx-CD" ;;
        "SGFX") echo "NEC%20-%20PC%20Engine%20SuperGrafx" ;;
        "CPS1"|"CPS2"|"CPS3") echo "FBNeo%20-%20Arcade%20Games" ;;
        "COLECO") echo "Coleco%20-%20ColecoVision" ;;
        "INTELLIVISION") echo "Mattel%20-%20Intellivision" ;;
        "VECTREX") echo "GCE%20-%20Vectrex" ;;
        "MSX") echo "Microsoft%20-%20MSX" ;;
        "COMMODORE") echo "Commodore%20-%2064" ;;
        "AMIGA") echo "Commodore%20-%20Amiga" ;;
        "ZXS") echo "Sinclair%20-%20ZX%20Spectrum" ;;
        "CPC") echo "Amstrad%20-%20CPC" ;;
        "DOS") echo "DOS" ;;
        *) echo "" ;;
    esac
}

# Extra file extensions to automatically accept for a given system folder, on top of the
# universal defaults (zip|7z|rar|chd) and whatever the user manually set via "Format" in
# Manage Repositories. This lets a single repo entry pick up e.g. both .zip and .smc SNES
# dumps, or PS1 .bin (its .cue pair is fetched automatically at download time), without the
# user having to know or configure it per repo.
get_auto_extensions() {
    local folder_key=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    case "$folder_key" in
        FC|NES) echo "nes" ;;
        SFC|SNES|SATELLAVIEW) echo "smc|sfc|bs" ;;
        GB|SGB) echo "gb" ;;
        GBC) echo "gbc" ;;
        GBA) echo "gba" ;;
        MD) echo "md|gen" ;;
        GG) echo "gg" ;;
        SMS) echo "sms" ;;
        PCE) echo "pce" ;;
        PS) echo "bin" ;;
        NGP) echo "ngp" ;;
        NGPC) echo "ngc" ;;
        WS) echo "ws" ;;
        WSC) echo "wsc" ;;
        ATARI2600) echo "a26" ;;
        ATARI7800) echo "a78" ;;
        ATARILYNX) echo "lnx" ;;
        VB) echo "vb" ;;
        # CD-based systems: .bin also carries a matching .cue, fetched automatically
        # at download time (same mechanism as PS1).
        SEGACD|NEOCD|PCFX) echo "bin" ;;
        FDS) echo "fds" ;;
        POKEFAMI) echo "min" ;;
        NDS) echo "nds" ;;
        N64) echo "n64|z64|v64" ;;
        MSX|MSX2) echo "rom|dsk|cas" ;;
        PICO) echo "p8" ;;
        FIFTYTWO00) echo "a52" ;;
        AMIGA) echo "adf|lha" ;;
        C64) echo "d64|t64|crt" ;;
        PSP) echo "iso|cso" ;;
        DC) echo "cdi" ;;
        32X) echo "32x" ;;
        TIC80) echo "tic" ;;
        VECTREX) echo "vec" ;;
        # Onion's own folder names
        MS) echo "sms" ;;
        ATARI) echo "a26" ;;
        SEVENTYEIGHTHUNDRED) echo "a78" ;;
        FIFTYTWOHUNDRED) echo "a52" ;;
        LYNX) echo "lnx" ;;
        THIRTYTWOX) echo "32x" ;;
        POKE) echo "min" ;;
        COMMODORE) echo "d64|t64|crt|prg" ;;
        TIC) echo "tic" ;;
        PCECD) echo "cue|chd" ;;
        COLECO) echo "col" ;;
        INTELLIVISION) echo "int" ;;
        SEGASGONE) echo "sg" ;;
        SGFX) echo "pce|sgx" ;;
        ZXS) echo "z80|tzx|tap" ;;
        CPC) echo "dsk|cdt" ;;
        VIC20) echo "d64|prg|crt" ;;
        VIDEOPAC|ODYSSEY) echo "bin" ;;
        SUPERVISION) echo "sv" ;;
        MEGADUCK) echo "bin" ;;
        # ARCADE, CPS1/2/3, NEOGEO, DOS, PORTS, GW, SCUMMVM: no single-file raw dump
        # format in common use - these are always distributed as zip/7z archives,
        # already covered by the universal defaults.
        *) echo "" ;;
    esac
}

get_console_name() {
    console_name_var "$1"
    echo "$CONSOLE_NAME"
}

# Sets CONSOLE_NAME without starting a subshell (get_console_name prints it)
console_name_var() {
    case "$1" in
        "GBA") CONSOLE_NAME="Game Boy Advance" ;;
        "PS") CONSOLE_NAME="PlayStation 1" ;;
        "FC") CONSOLE_NAME="Nintendo NES" ;;
        "SFC") CONSOLE_NAME="Super Nintendo" ;;
        "SATELLAVIEW") CONSOLE_NAME="Satellaview" ;;
        "GB") CONSOLE_NAME="Game Boy" ;;
        "GBC") CONSOLE_NAME="Game Boy Color" ;;
        "MD") CONSOLE_NAME="Sega Genesis" ;;
        "GG") CONSOLE_NAME="Sega Game Gear" ;;
        "SMS") CONSOLE_NAME="Sega Master System" ;;
        "PCE") CONSOLE_NAME="TurboGrafx-16" ;;
        "NEOGEO") CONSOLE_NAME="Neo Geo" ;;
        "ARCADE") CONSOLE_NAME="Arcade" ;;
        "NGP") CONSOLE_NAME="Neo Geo Pocket" ;;
        "NGPC") CONSOLE_NAME="Neo Geo Pocket Color" ;;
        "WS") CONSOLE_NAME="WonderSwan" ;;
        "WSC") CONSOLE_NAME="WonderSwan Color" ;;
        "SNES") CONSOLE_NAME="Super Nintendo" ;;
        "NES") CONSOLE_NAME="Nintendo NES" ;;
        "ATARI2600") CONSOLE_NAME="Atari 2600" ;;
        "ATARI7800") CONSOLE_NAME="Atari 7800" ;;
        "ATARILYNX") CONSOLE_NAME="Atari Lynx" ;;
        "VB") CONSOLE_NAME="Virtual Boy" ;;
        "SEGACD") CONSOLE_NAME="Sega CD" ;;
        "FDS") CONSOLE_NAME="Famicom Disk System" ;;
        "POKEFAMI") CONSOLE_NAME="Pokemon Mini" ;;
        "NDS") CONSOLE_NAME="Nintendo DS" ;;
        "N64") CONSOLE_NAME="Nintendo 64" ;;
        "CPS1") CONSOLE_NAME="Capcom Play System 1" ;;
        "CPS2") CONSOLE_NAME="Capcom Play System 2" ;;
        "CPS3") CONSOLE_NAME="Capcom Play System 3" ;;
        "DOS") CONSOLE_NAME="MS-DOS" ;;
        "PORTS") CONSOLE_NAME="Ports" ;;
        "GW") CONSOLE_NAME="Game & Watch" ;;
        "MSX") CONSOLE_NAME="MSX" ;;
        "MSX2") CONSOLE_NAME="MSX2" ;;
        "PICO") CONSOLE_NAME="Pico-8" ;;
        "SGB") CONSOLE_NAME="Super Game Boy" ;;
        "FIFTYTWO00") CONSOLE_NAME="Atari 5200" ;;
        "AMIGA") CONSOLE_NAME="Commodore Amiga" ;;
        "C64") CONSOLE_NAME="Commodore 64" ;;
        "NEOCD") CONSOLE_NAME="Neo Geo CD" ;;
        "SCUMMVM") CONSOLE_NAME="ScummVM" ;;
        "PSP") CONSOLE_NAME="PlayStation Portable" ;;
        "DC") CONSOLE_NAME="Sega Dreamcast" ;;
        "32X") CONSOLE_NAME="Sega 32X" ;;
        "PCFX") CONSOLE_NAME="PC-FX" ;;
        "TIC80") CONSOLE_NAME="TIC-80" ;;
        "VECTREX") CONSOLE_NAME="Vectrex" ;;
        # Onion's own folder names
        "MS") CONSOLE_NAME="Sega Master System" ;;
        "ATARI") CONSOLE_NAME="Atari 2600" ;;
        "SEVENTYEIGHTHUNDRED") CONSOLE_NAME="Atari 7800" ;;
        "FIFTYTWOHUNDRED") CONSOLE_NAME="Atari 5200" ;;
        "LYNX") CONSOLE_NAME="Atari Lynx" ;;
        "THIRTYTWOX") CONSOLE_NAME="Sega 32X" ;;
        "POKE") CONSOLE_NAME="Pokemon Mini" ;;
        "COMMODORE") CONSOLE_NAME="Commodore 64" ;;
        "TIC") CONSOLE_NAME="TIC-80" ;;
        "PCECD") CONSOLE_NAME="TurboGrafx CD" ;;
        "COLECO") CONSOLE_NAME="ColecoVision" ;;
        "INTELLIVISION") CONSOLE_NAME="Intellivision" ;;
        "SEGASGONE") CONSOLE_NAME="Sega SG-1000" ;;
        "SGFX") CONSOLE_NAME="SuperGrafx" ;;
        "SUFAMI") CONSOLE_NAME="Sufami Turbo" ;;
        "SUPERVISION") CONSOLE_NAME="Supervision" ;;
        "VIC20") CONSOLE_NAME="Commodore VIC-20" ;;
        "VIDEOPAC") CONSOLE_NAME="Videopac+" ;;
        "ODYSSEY") CONSOLE_NAME="Odyssey 2" ;;
        "ZXS") CONSOLE_NAME="ZX Spectrum" ;;
        "CPC") CONSOLE_NAME="Amstrad CPC" ;;
        "MEGADUCK") CONSOLE_NAME="Mega Duck" ;;
        "FAIRCHILD") CONSOLE_NAME="Channel F" ;;
        "ATARIST") CONSOLE_NAME="Atari ST" ;;
        *) CONSOLE_NAME="$1" ;;
    esac
}

fetch_libretro_art() {
    local sys="$1"
    local base="$2"
    local out="$3"
    local fast="$4"
    local tmp_out="${out}.tmp"
    rm -f "$tmp_out"

    encode_libretro() { echo "$1" | sed -e 's/[&*/:<>\?|\"\\]/_/g' -e 's/  */ /g' | sed 's/ *$//'; }
    url_enc() { echo "$1" | sed 's/ /%20/g; s/(/%28/g; s/)/%29/g; s/\[/%5B/g; s/\]/%5D/g; s/'\''/%27/g; s/,/%2C/g; s/+/%2B/g; s/!/%21/g; s/&/%26/g; s/#/%23/g'; }

    # --- GOODTOOLS TO NO-INTRO FILTERING ---
    # 1. Strip all square bracket tags (e.g., [C], [!], [b1]) and trailing spaces
    local no_brackets=$(echo "$base" | sed 's/\[[^]]*\]//g' | sed 's/  */ /g' | sed 's/ *$//')
    
    # 2. Expand GoodTools single-letter region codes into Libretro full words
    local region_fixed=$(echo "$no_brackets" | sed 's/(U)/(USA)/g; s/(E)/(Europe)/g; s/(J)/(Japan)/g; s/(W)/(World)/g; s/(UE)/(USA, Europe)/g; s/(JU)/(Japan, USA)/g')

    # 3. Create the exact match attempt using the newly translated regions
    local clean_name=$(encode_libretro "$region_fixed")

    # 4. Create a "naked" title completely stripped of parentheses for fallback guessing
    local naked_base=$(echo "$region_fixed" | sed 's/([^)]*)//g' | sed 's/  */ /g' | sed 's/ *$//')
    local naked_name=$(encode_libretro "$naked_base")
    # ---------------------------------------

    local base_url="https://thumbnails.libretro.com/${sys}/Named_Boxarts"

    local curl_timeout=15
    local curl_connect=5
    local curl_retry=2
    if [ "$fast" = "1" ]; then
        curl_timeout=4
        curl_connect=2
        curl_retry=0
    fi

    try_curl() { curl --retry $curl_retry --retry-delay 1 -f -s -L -k --globoff --connect-timeout $curl_connect -m $curl_timeout -A "Mozilla/5.0" "$1" -o "$2"; }

    local success=0

    # Try the exact GoodTools-translated name first
    if try_curl "${base_url}/$(url_enc "$clean_name").png" "$tmp_out"; then success=1; fi

    # Then start hammering the naked title with standard No-Intro suffixes
    if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name")%20%28USA%2C%20Europe%29.png" "$tmp_out"; then success=1; fi

    # In fast (browse-preview) mode, stop after the two most common variants to keep navigation snappy
    if [ "$fast" != "1" ]; then
        if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name")%20%28USA%29.png" "$tmp_out"; then success=1; fi
        if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name")%20%28Europe%29.png" "$tmp_out"; then success=1; fi
        if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name")%20%28World%29.png" "$tmp_out"; then success=1; fi
        if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name")%20%28Japan%29.png" "$tmp_out"; then success=1; fi
        if [ $success -eq 0 ] && try_curl "${base_url}/$(url_enc "$naked_name").png" "$tmp_out"; then success=1; fi
    fi

    if [ $success -eq 1 ] && [ -s "$tmp_out" ]; then
        mv "$tmp_out" "$out"
        return 0
    else
        rm -f "$tmp_out"
        return 1
    fi
}

# Preview covers (for games not downloaded yet) are only for looking at, so they're
# kept small: shrunk to screen size as JPEG (~15KB instead of a ~200KB PNG; the name
# stays .png - the renderer goes by the contents), and the oldest are deleted once the
# folder passes PREVIEW_CACHE_MB. Covers of downloaded games (Imgs) are left alone.
shrink_preview() {
    [ -f ./bin/rmui ] || return
    if ./bin/rmui --thumb "$1" "$1.small" 240 280 2>/dev/null && [ -s "$1.small" ]; then
        mv -f "$1.small" "$1"
    else
        rm -f "$1.small"
    fi
}

trim_preview_cache() {
    local dir="$CACHE_DIR/previews" limit=$((${PREVIEW_CACHE_MB:-40} * 1024)) f size
    local used=$(du -sk "$dir" 2>/dev/null | cut -f1)
    [ "${used:-0}" -le "$limit" ] && return
    ls -tr "$dir" 2>/dev/null | grep '\.png$' | while IFS= read -r f; do
        [ "$used" -le $((limit * 8 / 10)) ] && break
        size=$(( ($(stat -c %s "$dir/$f" 2>/dev/null || echo 0) + 1023) / 1024 ))
        rm -f "$dir/$f"
        used=$((used - size))
    done
}

# Older versions kept full-size preview PNGs: shrink those once, in the background.
shrink_old_previews() {
    [ -f "$CACHE_DIR/.previews_shrunk" ] && return
    (
        for f in "$CACHE_DIR"/previews/*.png; do
            [ -f "$f" ] || continue
            [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 40000 ] && shrink_preview "$f"
        done
        touch "$CACHE_DIR/.previews_shrunk"
        trim_preview_cache
    ) </dev/null >/dev/null 2>&1 &
}

fetch_libretro_art_preview() {
    local sys="$1"
    local base="$2"
    local out="$3"
    [ -z "$sys" ] && return 1
    if fetch_libretro_art "$sys" "$base" "$out" "1"; then
        shrink_preview "$out"
        return 0
    else
        touch "${out}.none"
        return 1
    fi
}

refresh_previews_have_list() {
    local previews_mtime=$(stat -c %Y "$CACHE_DIR/previews" 2>/dev/null || echo 0)
    local last_scanned_mtime=$(cat "$CACHE_DIR/preview_cache_mtime.txt" 2>/dev/null)
    if [ "$previews_mtime" != "$last_scanned_mtime" ] || [ ! -f "$CACHE_DIR/preview_cache_have.txt" ]; then
        busy_frame "Scanning the preview cache..."
        ls "$CACHE_DIR/previews" 2>/dev/null | grep '\.png$' | sed 's/\.png$//' | sort > "$CACHE_DIR/preview_cache_have.txt"
        echo "$previews_mtime" > "$CACHE_DIR/preview_cache_mtime.txt"
    fi
}

update_local_consoles() {
    [ -f "$CACHE_DIR/local_consoles.cache" ] && return
    
    local out="$CACHE_DIR/local_consoles.cache" folder_name count
    # One rmls run counts every folder (this used to start three programs for each
    # of the ~70 Roms folders, and list every file of each one)
    if [ -x ./bin/rmls ]; then
        ./bin/rmls count "$ROMS_DIR" 2>/dev/null > "$out.tmp"
    else
        > "$out.tmp"
        for dir in "$ROMS_DIR"/*; do
            [ -d "$dir" ] || continue
            count=$(ls -1p "$dir" 2>/dev/null | grep -ivE -c "$ROM_IGNORE")
            [ "$count" -gt 0 ] && echo "${dir##*/}|$count" >> "$out.tmp"
        done
    fi
    > "$out"
    while IFS='|' read -r folder_name count; do
        [ -n "$folder_name" ] || continue
        console_name_var "$folder_name"
        echo "${folder_name}|${count}|${CONSOLE_NAME}" >> "$out"
    done < "$out.tmp"
    rm -f "$out.tmp"
    [ -s "$out" ] && sort -u "$out" -o "$out"
}

force_update_local_consoles() {
    rm -f "$CACHE_DIR/local_consoles.cache"
    update_local_consoles
}

# ==========================================
# 6. STATE FUNCTIONS
# ==========================================

# Numbers shown on the home screen. Worked out at boot and when coming back to the home
# screen (not per button press).
refresh_home_counts() {
    local g c
    read -r g c <<EOF
$(awk -F'|' '{ g += $2; c++ } END { print g + 0, c + 0 }' "$CACHE_DIR/local_consoles.cache" 2>/dev/null)
EOF
    HOME_GAMES=${g:-0}
    HOME_CONSOLES=${c:-0}
    HOME_FAVS=$(grep -c . "$FAV_FILE" 2>/dev/null)
    HOME_RECENT=$(grep -c . "$RECENT_DL_FILE" 2>/dev/null)
    HOME_REPOS=$(repos_list | grep -c .)
    HOME_STALE=0
}

# "1 game" / "3 games"
plural() {
    if [ "$1" = "1" ]; then echo "1 $2"; else echo "$1 ${3:-${2}s}"; fi
}

# Home screen: what each item does, shown on the status line
home_hint() {
    case "$1" in
        0) HINT="Browse your repos and download ROMs" ;;
        1) HINT="Play and manage the games on your SD card" ;;
        2) HINT="Your favorite games, from every console" ;;
        3) HINT="The games you downloaded lately" ;;
        4) HINT="Add or change where games come from" ;;
        *) HINT="Sound, looks, tools and archive.org login" ;;
    esac
}

# The home screen: six tiles (or a plain list - Settings > Home Screen).
state_main_menu() {
    local total_items=6

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        if [ "${HOME_STALE:-1}" = "1" ]; then
            refresh_home_counts
            update_statusbar
        fi
        build_theme
        if [ "$EXIT_ARMED" = "1" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Press B again to exit RomManager\n"
        else
            home_hint "$MAIN_INDEX"
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$HINT\n"
        fi
        # A download running: the tile shows its progress (rmui keeps it up to date), and
        # X opens the queue
        local dl_sub home_footer="<>/ Move  A/ Open  B/ Exit"
        if dl_worker_alive; then
            dl_sub="{DL}"
        else
            dl_sub="$(plural "$HOME_REPOS" repo)"
        fi
        [ -s "$DLQ" ] && home_footer="<>/ Move  A/ Open  X/ Downloads  B/ Exit"
        if [ "$HOME_STYLE" = "list" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Download ROMs\nITEM:Installed ROMs\nITEM:Favorite Games\n"
            UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Recent Downloads\nITEM:Manage Repositories\nITEM:Settings & Tools\n"
            UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$MAIN_INDEX\nFOOTER:${home_footer#<>/ Move  }\nART:NULL\n"
        else
            HOME_TILES="TILE:download|Download ROMs|$dl_sub\nTILE:installed|Installed ROMs|$(plural "$HOME_GAMES" game)\n"
            HOME_TILES="${HOME_TILES}TILE:favorites|Favorites|$(plural "$HOME_FAVS" game)\nTILE:recent|Recent|$(plural "$HOME_RECENT" download)\n"
            HOME_TILES="${HOME_TILES}TILE:repos|Repositories|$(plural "$HOME_REPOS" source)\nTILE:settings|Settings|v$RM_VERSION\n"
            HOME_TILES="TILE_ICONS:/mnt/SDCARD/App/RomManager/ui/menu\n$HOME_TILES"
            UI_FRAME_BUF="${UI_FRAME_BUF}$HOME_TILES"
            UI_FRAME_BUF="${UI_FRAME_BUF}TILE_SEL:$MAIN_INDEX\nFOOTER:$home_footer\n"
        fi
        render_ui
    fi

    get_key || return

    # B asks first and only a second B exits: one press too many while backing out of
    # the menus used to close the whole app.
    if [ "$EXIT_ARMED" = "1" ] && [ "$KEY" != "B" ]; then
        EXIT_ARMED=0
        UI_RENDER_NEEDED=1
    fi

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            if [ "$HOME_STYLE" = "list" ]; then
                update_selection "$KEY" "$total_items" 1 "$MAIN_INDEX"; MAIN_INDEX=$SEL
            else
                # 3 x 2 grid: left/right go along (and on to the next row), up/down
                # switch rows
                case "$KEY" in
                    right) MAIN_INDEX=$(( (MAIN_INDEX + 1) % 6 )) ;;
                    left) MAIN_INDEX=$(( (MAIN_INDEX + 5) % 6 )) ;;
                    up|down) MAIN_INDEX=$(( (MAIN_INDEX + 3) % 6 )) ;;
                esac
            fi
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "confirm"
            if [ "$HOME_STYLE" != "list" ] && [ -n "$RMUI_PID" ]; then
                # The tile presses in while the next screen loads
                home_hint "$MAIN_INDEX"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$HINT\n$HOME_TILES"
                UI_FRAME_BUF="${UI_FRAME_BUF}TILE_SEL:$MAIN_INDEX\nTILE_PRESS:1\nFOOTER:<>/ Move  A/ Open  B/ Exit\n"
                [ -s "$DLQ" ] && UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<>/ Move  A/ Open  X/ Downloads  B/ Exit\n"
                render_ui
            fi
            HOME_STALE=1
            case "$MAIN_INDEX" in
                0) refresh_dl_consoles; STATE="DL_CONSOLES" ;;
                1) update_local_consoles; STATE="INST_CONSOLES" ;;
                2) STATE="FAVORITES" ;;
                3) prune_recent; RECENT_INDEX=0; STATE="RECENT_DOWNLOADS" ;;
                4) STATE="MANAGE_REPOS" ;;
                5) STATE="SETTINGS" ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
        X)
            # The download queue, straight from the home screen
            if [ -s "$DLQ" ]; then
                play_sound "confirm"
                DLQ_INDEX=0
                DOWNLOADS_BACK=MAIN_MENU
                STATE="DOWNLOADS"
                UI_RENDER_NEEDED=1
            fi
            ;;
        B)
            play_sound "back"
            [ "$EXIT_ARMED" = "1" ] && shutdown_app
            EXIT_ARMED=1
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# Settings rows, in order. Value rows change with left/right (or A); "->" rows open a
# tool. The volume rows show bars.
SETTINGS_ROWS="music sfx home motion start launcher items scrape cache login tool_scrape tool_prefetch previews clear rebuild autoupdate update credits"

settings_row_id() {
    echo "$SETTINGS_ROWS" | cut -d' ' -f$(($1 + 1))
}

# Changes a value row by $2 (1 = next / louder, -1 = previous / quieter).
settings_change() {
    case "$1" in
        music)
            BGM_VOLUME=$((BGM_VOLUME + $2))
            [ "$BGM_VOLUME" -lt 0 ] && BGM_VOLUME=0
            [ "$BGM_VOLUME" -gt 10 ] && BGM_VOLUME=10
            local was=$BGM_ENABLED
            BGM_ENABLED=0; [ "$BGM_VOLUME" -gt 0 ] && BGM_ENABLED=1
            audio_apply_volume
            if [ "$BGM_ENABLED" != "$was" ]; then
                if [ "$BGM_ENABLED" -eq 1 ]; then start_bgm; else stop_bgm; fi
            fi
            play_sound "change"
            ;;
        sfx)
            SFX_VOLUME=$((SFX_VOLUME + $2))
            [ "$SFX_VOLUME" -lt 0 ] && SFX_VOLUME=0
            [ "$SFX_VOLUME" -gt 10 ] && SFX_VOLUME=10
            SFX_ENABLED=0; [ "$SFX_VOLUME" -gt 0 ] && SFX_ENABLED=1
            audio_apply_volume
            # Played at the new level, so you hear what you picked
            play_sound "change"
            ;;
        start)
            play_sound "change"
            if [ "$2" -gt 0 ]; then
                case "$START_SCREEN" in menu) START_SCREEN=installed ;; installed) START_SCREEN=last ;; *) START_SCREEN=menu ;; esac
            else
                case "$START_SCREEN" in last) START_SCREEN=installed ;; installed) START_SCREEN=menu ;; *) START_SCREEN=last ;; esac
            fi
            ;;
        home)
            play_sound "change"
            if [ "$HOME_STYLE" = "list" ]; then HOME_STYLE=tiles; else HOME_STYLE=list; fi
            ;;
        motion)
            play_sound "change"
            if [ "$MOTION" = "off" ]; then MOTION=on; else MOTION=off; fi
            theme_settings
            ;;
        launcher)
            play_sound "change"
            LAUNCHER=$((1 - LAUNCHER))
            ;;
        items)
            play_sound "change"
            UI_MAX_ITEMS=$((UI_MAX_ITEMS + $2 * 2))
            [ "$UI_MAX_ITEMS" -gt 14 ] && UI_MAX_ITEMS=6
            [ "$UI_MAX_ITEMS" -lt 6 ] && UI_MAX_ITEMS=14
            ;;
        scrape)
            play_sound "change"
            AUTO_SCRAPE=$((1 - AUTO_SCRAPE))
            ;;
        autoupdate)
            play_sound "change"
            AUTO_UPDATE=$((1 - AUTO_UPDATE))
            ;;
        cache)
            play_sound "change"
            if [ "$2" -gt 0 ]; then
                case "$REPO_CACHE_DAYS" in 1) REPO_CACHE_DAYS=7 ;; 7) REPO_CACHE_DAYS=30 ;; *) REPO_CACHE_DAYS=1 ;; esac
            else
                case "$REPO_CACHE_DAYS" in 30) REPO_CACHE_DAYS=7 ;; 7) REPO_CACHE_DAYS=1 ;; *) REPO_CACHE_DAYS=30 ;; esac
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

state_settings() {
    local total_items=$(echo $SETTINGS_ROWS | wc -w)
    [ "$SET_INDEX" -ge "$total_items" ] && SET_INDEX=$((total_items - 1))
    local row=$(settings_row_id "$SET_INDEX")

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local scrape_txt="OFF"; [ "$AUTO_SCRAPE" -eq 1 ] && scrape_txt="ON"
        local start_txt="Main Menu"
        [ "$START_SCREEN" = "installed" ] && start_txt="Installed ROMs"
        [ "$START_SCREEN" = "last" ] && start_txt="Where I Left Off"
        local home_txt="Tiles"; [ "$HOME_STYLE" = "list" ] && home_txt="List"
        local motion_txt="ON"; [ "$MOTION" = "off" ] && motion_txt="OFF"
        local launcher_txt="ON"; [ "$LAUNCHER" = "1" ] || launcher_txt="OFF"
        local login_txt="-> Log in to archive.org"
        [ -n "$IA_USER" ] && login_txt="archive.org: $(echo "$IA_USER" | cut -c 1-20) (log out)"
        local autoupd_txt="ON"; [ "$AUTO_UPDATE" = "1" ] || autoupd_txt="OFF"
        local update_txt="-> Check for Updates"
        update_pending && update_txt="-> Update to $UPD_VERSION"
        {
            echo "Music Volume  $(volume_bar "$BGM_VOLUME")"
            echo "Sound Effects  $(volume_bar "$SFX_VOLUME")"
            echo "Home Screen  [$home_txt]"
            echo "Animations  [$motion_txt]"
            echo "Open To  [$start_txt]"
            echo "Default Launcher  [$launcher_txt]"
            echo "List Rows  [$UI_MAX_ITEMS]"
            echo "Auto Scrape Covers  [$scrape_txt]"
            echo "Repo Cache  [$REPO_CACHE_DAYS days]"
            echo "$login_txt"
            echo "-> Scrape Missing Box Art"
            echo "-> Prefetch Repo Previews"
            echo "-> Manage Preview Cache"
            echo "-> Clear Repo Cache"
            echo "-> Rebuild Local Database"
            echo "Auto Update  [$autoupd_txt]"
            echo "$update_txt"
            echo "-> Credits & About"
        } > "$CACHE_DIR/settings_rows.list"

        local footer="A/ Open  B/ Save & Back"
        case "$row" in
            music|sfx) footer="<>/ Volume  B/ Save & Back" ;;
            start|home|motion|launcher|items|scrape|cache|autoupdate) footer="<>/ Change  B/ Save & Back" ;;
        esac
        # What the highlighted setting does
        local hint="Settings & Tools"
        case "$row" in
            music) hint="Music volume - all the way down turns it off" ;;
            sfx) hint="Button sound volume - all the way down turns them off" ;;
            home) hint="Main menu as big tiles or a plain list" ;;
            motion) hint="Slides, fades and the floating cover" ;;
            start) hint="What RomManager opens on from Onion (after a game: where you were)" ;;
            launcher) hint="ON: games started here, and Menu, come back to RomManager" ;;
            items) hint="How many rows a list shows" ;;
            scrape) hint="Fetch box art for each game you download" ;;
            cache) hint="How long repo game lists are kept before re-reading" ;;
            login) hint="Log in for archive.org items that need an account" ;;
            tool_scrape) hint="Find box art for installed games that have none" ;;
            tool_prefetch) hint="Download a repo's preview covers ahead of time" ;;
            previews) hint="See and delete saved preview covers, by console" ;;
            clear) hint="Forget saved repo game lists - they're read again" ;;
            rebuild) hint="Count the games on your SD card again" ;;
            autoupdate) hint="Get new versions from GitHub by itself (installed when it starts)" ;;
            update) hint="You have version $RM_VERSION - get the newest from GitHub" ;;
            credits) hint="Who made RomManager" ;;
        esac
        draw_simple_list "$CACHE_DIR/settings_rows.list" "$SET_INDEX" "$hint" "$footer"
    fi

    get_key || return

    case "$KEY" in
        down|up)
            play_sound "change"
            update_selection "$KEY" "$total_items" 1 "$SET_INDEX"; SET_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        left|right)
            local step=1; [ "$KEY" = "left" ] && step=-1
            settings_change "$row" "$step" && UI_RENDER_NEEDED=1
            ;;
        A)
            case "$row" in
                music|sfx) ;;
                start|home|motion|launcher|items|scrape|cache|autoupdate) settings_change "$row" 1 ;;
                update)
                    play_sound "change"
                    save_settings
                    if update_pending; then update_flow; else update_flow check; fi
                    ;;
                login)
                    play_sound "change"
                    if [ -n "$IA_USER" ]; then
                        ask_dialog "Log out of archive.org?" "Logged in as $IA_USER" -- "Log out" "Cancel"
                        if [ "$DIALOG_RESULT" = "0" ]; then
                            ia_logout
                            rm -f "$CACHE_DIR"/console_*.list
                        fi
                    else
                        OSK_BUF=""; OSK_X=0; OSK_Y=0; OSK_LAYER=0; OSK_UPPER=0
                        STATE="IA_LOGIN_EMAIL"
                    fi
                    ;;
                tool_scrape) play_sound "change"; save_settings; STATE="SCRAPE_ART" ;;
                tool_prefetch) play_sound "change"; save_settings; STATE="PREFETCH_COVERS_SCAN" ;;
                previews)
                    play_sound "change"
                    PREVIEW_REPO_INDEX=0
                    > "$CACHE_DIR/preview_scope_selected.txt"
                    { echo "[ALL CONSOLES]|__ALL__"; consoles_with_repos | while IFS='|' read -r c n; do echo "$(get_console_name "$c")|$c"; done; } > "$CACHE_DIR/preview_scope_list.txt"
                    STATE="SELECT_PREVIEW_REPO"
                    ;;
                clear)
                    play_sound "change"
                    ask_dialog "Clear the repo cache?" "Game lists are read from the repos" "again the next time you open them." -- "Clear" "Cancel"
                    if [ "$DIALOG_RESULT" = "0" ]; then
                        rm -f "$SOURCES_DIR"/* "$CACHE_DIR"/console_*.list
                        toast ok "Repo cache cleared"
                    fi
                    ;;
                rebuild)
                    play_sound "change"
                    force_update_local_consoles
                    show_message "Local Database Rebuilt!" 1.5
                    ;;
                credits) play_sound "change"; CREDITS_INDEX=0; STATE="CREDITS" ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            save_settings
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# Settings > Credits & About
state_credits() {
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        {
            echo "RomManager $RM_VERSION for OnionOS"
            echo "Made by plusCloud: design, the app, the screen,"
            echo "  sound and button engines, repos, downloads"
            echo "Contributions by brenonsc: file-format detection,"
            echo "  cover prefetch, .cue downloads, reliability fixes"
            echo "Icons by Bernig"
            echo "Box art: the Libretro thumbnail project"
            echo "Uses stb_image / stb_truetype (Sean Barrett), minimp3"
            echo "Thanks to the OnionOS team"
            echo "Only download games you own - RomManager comes"
            echo "  with no games, just the sources you add"
        } > "$CACHE_DIR/credits.list"
        draw_simple_list "$CACHE_DIR/credits.list" "$CREDITS_INDEX" "Credits & About" "^v/ Scroll  B/ Back"
    fi
    get_key || return
    case "$KEY" in
        down|up)
            count_lines "$CACHE_DIR/credits.list"
            update_selection "$KEY" "$N" 1 "$CREDITS_INDEX"; CREDITS_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        B|A)
            play_sound "back"
            STATE="SETTINGS"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_select_preview_repo() {
    local total_items=$(wc -l < "$CACHE_DIR/preview_scope_list.txt")
    [ "$total_items" -le 0 ] && total_items=1
    local selected_count=$(wc -l < "$CACHE_DIR/preview_scope_selected.txt" 2>/dev/null)
    [ -z "$selected_count" ] && selected_count=0

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((PREVIEW_REPO_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((PREVIEW_REPO_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (PREVIEW_REPO_INDEX * 100) / (total_items - 1) ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Preview cache: $selected_count selected  ·  $human_pos/$total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Select  Y/ All  X/ None  Start/ Delete  B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local total_real=$((total_items - 1))
        if [ -s "$CACHE_DIR/preview_scope_selected.txt" ]; then
            local items=$(awk -F'|' -v start=$((start_item + 1)) -v end=$((end_item + 1)) -v sel_count="$selected_count" -v total_real="$total_real" '
                NR==FNR { sel[$0]=1; next }
                (FNR>=start && FNR<=end) {
                    if ($2 == "__ALL__") {
                        mark = (sel_count > 0 && sel_count == total_real) ? "*" : "-";
                    } else {
                        mark = ($2 in sel) ? "*" : "-";
                    }
                    print mark substr($1, 1, 27);
                }
            ' "$CACHE_DIR/preview_scope_selected.txt" "$CACHE_DIR/preview_scope_list.txt")
        else
            local items=$(awk -F'|' -v start=$((start_item + 1)) -v end=$((end_item + 1)) '
                NR>=start && NR<=end { print "-" substr($1, 1, 27) }
            ' "$CACHE_DIR/preview_scope_list.txt")
        fi
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((PREVIEW_REPO_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$DL_CHOSEN_FOLDER$INST_CHOSEN_FOLDER-$total_items\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$PREVIEW_REPO_INDEX"; PREVIEW_REPO_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local chosen_id=$(sed -n "$((PREVIEW_REPO_INDEX + 1))p" "$CACHE_DIR/preview_scope_list.txt" | cut -d'|' -f2)
            if [ "$chosen_id" = "__ALL__" ]; then
                local total_real=$(( $(wc -l < "$CACHE_DIR/preview_scope_list.txt") - 1 ))
                if [ "$selected_count" -gt 0 ] && [ "$selected_count" -eq "$total_real" ]; then
                    > "$CACHE_DIR/preview_scope_selected.txt"
                else
                    awk -F'|' '$2!="__ALL__"{print $2}' "$CACHE_DIR/preview_scope_list.txt" > "$CACHE_DIR/preview_scope_selected.txt"
                fi
            elif grep -qxF "$chosen_id" "$CACHE_DIR/preview_scope_selected.txt" 2>/dev/null; then
                grep -vxF "$chosen_id" "$CACHE_DIR/preview_scope_selected.txt" > "$CACHE_DIR/preview_scope_selected.txt.tmp"
                mv "$CACHE_DIR/preview_scope_selected.txt.tmp" "$CACHE_DIR/preview_scope_selected.txt"
            else
                echo "$chosen_id" >> "$CACHE_DIR/preview_scope_selected.txt"
            fi
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            awk -F'|' '$2!="__ALL__"{print $2}' "$CACHE_DIR/preview_scope_list.txt" > "$CACHE_DIR/preview_scope_selected.txt"
            UI_RENDER_NEEDED=1
            ;;
        X)
            play_sound "change"
            > "$CACHE_DIR/preview_scope_selected.txt"
            UI_RENDER_NEEDED=1
            ;;
        start)
            if [ "$selected_count" -eq 0 ]; then
                play_sound "back"
                toast err "Nothing selected - press A on a console first"
                UI_RENDER_NEEDED=1
            else
                play_sound "change"
                refresh_previews_have_list

                > "$CACHE_DIR/preview_delete_targets.txt"
                while read -r repo_id; do
                    [ -z "$repo_id" ] && continue
                    local repo_list="$CACHE_DIR/console_${repo_id}.list"
                    [ -s "$repo_list" ] || continue
                    [ -s "$CACHE_DIR/preview_cache_have.txt" ] || continue
                    # Intersect this repo's known titles with what's actually cached
                    # as a preview - a single in-memory join, no per-title stat()s.
                    awk -F'|' '
                        NR==FNR { have[$0]=1; next }
                        ($1 in have) { print $1 }
                    ' "$CACHE_DIR/preview_cache_have.txt" "$repo_list" >> "$CACHE_DIR/preview_delete_targets.txt"
                done < "$CACHE_DIR/preview_scope_selected.txt"
                sort -u "$CACHE_DIR/preview_delete_targets.txt" -o "$CACHE_DIR/preview_delete_targets.txt"

                if [ -s "$CACHE_DIR/preview_delete_targets.txt" ]; then
                    STATE="CONFIRM_DELETE_PREVIEWS"
                else
                    toast info "No saved previews for those consoles"
                fi
                UI_RENDER_NEEDED=1
            fi
            ;;
        B)
            play_sound "back"
            > "$CACHE_DIR/preview_scope_selected.txt"
            STATE="SETTINGS"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_confirm_delete_previews() {
    local target_count=$(wc -l < "$CACHE_DIR/preview_delete_targets.txt" 2>/dev/null)
    [ -z "$target_count" ] && target_count=0

    ask_dialog "Delete saved previews?" "$(plural "$target_count" preview) - they download again" "when you browse those games." -- "Delete" "Cancel"
    [ "$DIALOG_RESULT" = "0" ] && KEY=A || KEY=B
    while true; do
        case "$KEY" in
            A)
                play_sound "change"
                while read -r name; do
                    [ -z "$name" ] && continue
                    rm -f "$CACHE_DIR/previews/${name}.png" "$CACHE_DIR/previews/${name}.png.none"
                done < "$CACHE_DIR/preview_delete_targets.txt"

                if [ -f "$CACHE_DIR/preview_cache_have.txt" ]; then
                    grep -vxFf "$CACHE_DIR/preview_delete_targets.txt" "$CACHE_DIR/preview_cache_have.txt" > "$CACHE_DIR/preview_cache_have.txt.tmp"
                    mv "$CACHE_DIR/preview_cache_have.txt.tmp" "$CACHE_DIR/preview_cache_have.txt"
                fi
                > "$CACHE_DIR/preview_scope_selected.txt"

                stat -c %Y "$CACHE_DIR/previews" 2>/dev/null > "$CACHE_DIR/preview_cache_mtime.txt"

                play_sound "confirm"
                toast ok "$(plural "$target_count" preview) deleted"

                STATE="SELECT_PREVIEW_REPO"
                UI_RENDER_NEEDED=1
                return
                ;;
            B)
                play_sound "back"
                STATE="SELECT_PREVIEW_REPO"
                UI_RENDER_NEEDED=1
                return
                ;;
        esac
    done
}

# Consoles that have at least one repo (directly or through a pack), as
# "CONSOLE|repos|name" sorted by name.
refresh_dl_consoles() {
    consoles_with_repos | while IFS='|' read -r c n; do
        echo "$c|$n|$(get_console_name "$c")"
    done | sort -f -t'|' -k3,3 > "$CACHE_DIR/dl_consoles.list"
}

# Console icons for cover flow, from Onion's emulator settings (each config.json has
# the ROM folder and an icon). "FOLDER|icon" lines, made once.
build_console_icons() {
    local out="$CACHE_DIR/console_icons.txt"
    [ -f "$out" ] && return
    awk '
        function flush() {
            if (rp != "" && ic != "") {
                if (ic !~ /^\//) ic = dir "/" ic
                print rp "|" ic
            }
            rp = ""; ic = ""
        }
        FNR == 1 { flush(); dir = FILENAME; sub(/\/[^\/]*$/, "", dir) }
        { sub(/\r$/, "") }
        /"rompath"[ \t]*:/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); sub(/\/+$/, "", v)
                             n = split(v, p, "/"); rp = toupper(p[n]) }
        /"icon"[ \t]*:/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); ic = v }
        END { flush() }' /mnt/SDCARD/Emu/*/config.json /mnt/SDCARD/RApp/*/config.json \
        /mnt/SDCARD/App/PackageManager/data/*/*/*/*/config.json 2>/dev/null > "$out"
}

# Console pictures: RomManager's own set (ui/consoles, from the Wasteland theme by
# Bernig - silhouettes by Dreambrace), so it looks the same whatever Onion theme is on.
# Folder -> picture name; a console not listed here tries its folder name, then the
# icon Onion's own settings give it.
CONSOLE_ICON_MAP="GBA gba GB gb GBC gbc SGB sgb FC fc NES fc FDS fds SFC sfc SNES sfc SATELLAVIEW satella
SUFAMI sufami MD md GENESIS md GG gg MS ms SMS ms SEGACD segacd THIRTYTWOX 32x 32X 32x SEGASGONE segasgone
PCE pce PCECD pcecd SGFX sgfx NEOGEO neogeo NEOCD neocd NGP ngp NGPC ngp ARCADE arcade CPS1 cps1
CPS2 cps2 CPS3 cps3 PS ps WS ws WSC ws ATARI atari ATARI2600 atari SEVENTYEIGHTHUNDRED 7800 ATARI7800 7800
FIFTYTWOHUNDRED 5200 LYNX lynx ATARILYNX lynx ATARIST atarist VB vb POKE poke POKEFAMI poke NDS nds
DOS dos PORTS ports GW gw MSX msx MSX2 msx PICO pico AMIGA amiga COMMODORE c64 C64 c64 SCUMMVM scummvm
TIC tic TIC80 tic VECTREX vectrex COLECO col INTELLIVISION itv SUPERVISION supervision VIDEOPAC vdp
ODYSSEY ody ZXS zxs CPC cpc MEGADUCK megaduck FAIRCHILD fairchild"

# Cover-flow lines for a console list: $1 list ("FOLDER|count|name" lines, or "+DL|n|label"
# for the Downloads row), $2 selected, $3 total. One awk for all of it: a few programs
# started per row is what made the console lists lag.
append_console_flow() {
    local list="$1" sel="$2" total="$3"
    build_console_icons
    UI_FRAME_BUF="${UI_FRAME_BUF}COVERFLOW:$sel:$total:$STATE\n$(awk -F'|' -v lo=$((sel - 6)) -v hi=$((sel + 6)) \
        -v sel="$sel" -v dir="/mnt/SDCARD/App/RomManager/ui/consoles" -v map="$CONSOLE_ICON_MAP" '
        BEGIN {
            n = split(map, m, /[ \n]+/)
            for (i = 1; i < n; i += 2) icon[m[i]] = m[i + 1]
        }
        FILENAME == ARGV[1] { onion[$1] = $2; next }
        {
            i = FNR - 1
            if (i < lo || i > hi) next
            p = "ICON:download"
            if ($1 != "+DL") {
                f = toupper($1)
                p = dir "/" ((f in icon) ? icon[f] : tolower(f)) ".png"
                if ((getline line < p) <= 0) p = (f in onion) ? onion[f] : "BLANK"
                close(p)
            }
            printf "COVER:%d:%s\n", i, p
            if (i == sel) label = $3
        }
        END { printf "CFLABEL:%s\n", label }' "$CACHE_DIR/console_icons.txt" "$list")\n"
}

# Where you were in each console's list, so going back in lands on the same game.
# "kind|folder|index" lines.
POS_FILE="$CACHE_DIR/positions.txt"
pos_save() {
    { awk -F'|' -v k="$1" -v f="$2" '!($1 == k && $2 == f)' "$POS_FILE" 2>/dev/null
      echo "$1|$2|$3"; } > "$POS_FILE.tmp" && mv -f "$POS_FILE.tmp" "$POS_FILE"
}

pos_load() {
    POS=$(awk -F'|' -v k="$1" -v f="$2" '$1 == k && $2 == f { v = $3 } END { print v + 0 }' "$POS_FILE" 2>/dev/null)
    POS=${POS:-0}
}

# Number of non-empty lines in a small file, counted without starting a program (sets N)
count_lines() {
    N=0
    [ -r "$1" ] || return 0
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        [ -n "$l" ] && N=$((N + 1))
    done < "$1"
}

# Common list window: sets LIST_START / LIST_END for selection $1 of $2 rows
list_window() {
    local sel="$1" total="$2"
    LIST_START=$((sel - 4))
    [ "$LIST_START" -lt 0 ] && LIST_START=0
    LIST_END=$((LIST_START + UI_MAX_ITEMS - 1))
    [ "$LIST_END" -ge "$total" ] && LIST_END=$((total - 1))
    if [ $((LIST_END - LIST_START + 1)) -lt "$UI_MAX_ITEMS" ] && [ "$total" -ge "$UI_MAX_ITEMS" ]; then
        LIST_START=$((LIST_END - UI_MAX_ITEMS + 1))
        [ "$LIST_START" -lt 0 ] && LIST_START=0
    fi
}

# The consoles you can download for, with the download queue as the first row when
# there's anything in it
state_dl_consoles() {
    if [ ! -s "$CACHE_DIR/dl_consoles.list" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No repos yet - add one in Manage Repositories\nFOOTER:A/ Add a repo  B/ Back\nART:NULL\n"
            render_ui
        fi
        get_key || return
        case "$KEY" in
            A) play_sound "change"; STATE="MANAGE_REPOS"; UI_RENDER_NEEDED=1 ;;
            B) play_sound "back"; STATE="MAIN_MENU"; UI_RENDER_NEEDED=1 ;;
        esac
        return
    fi

    local rows="$CACHE_DIR/dl_consoles.rows" queued=0
    # The rows (and the Downloads row's count) only change when the screen is opened or
    # the queue changes - not on every press
    if [ ! -f "$rows" ] || [ "$STATE" != "$LAST_FRAME_STATE" ] || { [ -f "$DLQ" ] && [ "$DLQ" -nt "$rows" ]; } \
        || [ "$CACHE_DIR/dl_consoles.list" -nt "$rows" ]; then
        count_lines "$DLQ"; queued=$N
        {
            if [ "$queued" -gt 0 ]; then
                local pend=$(dlq_pending) label
                if [ "${pend:-0}" -gt 0 ]; then label="Downloads ($pend left)"; else label="Downloads ($queued done)"; fi
                echo "+DL|$queued|$label"
            fi
            awk -F'|' '{ print $1 "|" $2 "|" $3 (($2 > 1) ? " (" $2 " repos)" : "") }' "$CACHE_DIR/dl_consoles.list"
        } > "$rows"
        count_lines "$rows"; DLC_TOTAL=$N
    fi
    local total_items=${DLC_TOTAL:-1}
    [ "$total_items" -le 0 ] && total_items=1
    [ "$DL_CONSOLE_INDEX" -ge "$total_items" ] && DL_CONSOLE_INDEX=0

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local view_hint="R/ Covers"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"
        local footer="A/ Open  $view_hint  B/ Back"
        local status="Download: pick a console  ·  $((DL_CONSOLE_INDEX + 1))/$total_items"
        if [ "$GAME_VIEW" = "covers" ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$status\nFOOTER:$footer\n"
            append_console_flow "$rows" "$DL_CONSOLE_INDEX" "$total_items"
            render_ui
        else
            cut -d'|' -f3 "$rows" > "$CACHE_DIR/dl_consoles.disp"
            draw_simple_list "$CACHE_DIR/dl_consoles.disp" "$DL_CONSOLE_INDEX" "$status" "$footer"
        fi
    fi

    get_key || return
    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$DL_CONSOLE_INDEX"; DL_CONSOLE_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        A)
            local console display
            IFS='|' read -r console display display <<EOF
$(sed -n "$((DL_CONSOLE_INDEX + 1))p" "$rows")
EOF
            if [ "$console" = "+DL" ]; then
                play_sound "change"
                DLQ_INDEX=0
                DOWNLOADS_BACK=DL_CONSOLES; STATE="DOWNLOADS"
                UI_RENDER_NEEDED=1
                return
            fi
            play_sound "change"
            DL_CHOSEN_FOLDER="$console"
            DL_CHOSEN_DISPLAY=$(awk -F'|' -v c="$console" '$1 == c { print $3; exit }' "$CACHE_DIR/dl_consoles.list")
            DL_FORCE_REFRESH=0
            DOWNLOAD_RETURN_STATE="DL_GAMES"
            # back where you were in this console's list last time
            pos_load dl "$console"; DL_INDEX=$POS
            reset_dl_filters
            STATE="FETCH_XML"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_inst_consoles() {
    if [ ! -s "$CACHE_DIR/local_consoles.cache" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No games on the SD card yet\nFOOTER:B/ Back\nART:NULL\n"
            render_ui
        fi
        get_key || return
        if [ "$KEY" = "B" ]; then
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    local list="$CACHE_DIR/local_consoles.cache" rows="$CACHE_DIR/inst_consoles.rows"
    # (worked out when the list changes, not on every press - each program started
    # here is a noticeable pause on the Mini)
    if [ ! -s "$rows" ] || [ "$list" -nt "$rows" ] || [ "$STATE" != "$LAST_FRAME_STATE" ]; then
        awk -F'|' '{ print $1 "|" $2 "|" $3 " (" $2 ")" }' "$list" > "$rows"
        count_lines "$rows"; INST_TOTAL=$N
    fi
    local total_items=${INST_TOTAL:-1}
    [ "$total_items" -le 0 ] && total_items=1
    # The list shrinks when a console's last game is deleted
    [ "$INST_INDEX" -ge "$total_items" ] && INST_INDEX=$((total_items - 1))

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local view_hint="R/ Covers"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"
        local games="$HOME_GAMES games"; [ "$HOME_GAMES" = "1" ] && games="1 game"
        local status="Installed: $games  ·  $((INST_INDEX + 1))/$total_items"
        if [ "$GAME_VIEW" = "covers" ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$status\nFOOTER:A/ Open  $view_hint  B/ Back\n"
            append_console_flow "$rows" "$INST_INDEX" "$total_items"
            render_ui
        else
            awk -F'|' '{ print $3 " (" $2 ")" }' "$list" > "$CACHE_DIR/inst_consoles.disp"
            draw_simple_list "$CACHE_DIR/inst_consoles.disp" "$INST_INDEX" "$status" "A/ Open  $view_hint  B/ Back"
        fi
    fi

    get_key || return
    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$INST_INDEX"; INST_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local fld_raw=$(sed -n "$((INST_INDEX + 1))p" "$list" | cut -d'|' -f1)
            [ -z "$fld_raw" ] && { UI_RENDER_NEEDED=1; return; }
            INST_CHOSEN_FOLDER="$fld_raw"
            INST_CHOSEN_DISPLAY=$(get_console_name "$INST_CHOSEN_FOLDER")
            list_rom_folder "$INST_CHOSEN_FOLDER" > "$CACHE_DIR/current_games.cache"
            if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
                toast info "No games in this folder"
                UI_RENDER_NEEDED=1
                return
            fi
            rm -f "$CACHE_DIR/current_games_full.cache"
            pos_load inst "$INST_CHOSEN_FOLDER"; INST_GAME_INDEX=$POS
            STATE="INST_GAMES"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# Loads the chosen console's game list from all its repos. File lists already read
# are reused (see REPO_CACHE_DAYS); DL_FORCE_REFRESH=1 re-reads them from the servers.
state_fetch_xml() {
    local list="$CACHE_DIR/console_$DL_CHOSEN_FOLDER.list"
    local status="$CACHE_DIR/.fetch_status"
    rm -f "$status"

    run_with_spinner "Loading $(echo "$DL_CHOSEN_DISPLAY" | cut -c 1-24)" \
        build_console_games "$DL_CHOSEN_FOLDER" "$list" "$status" "$DL_FORCE_REFRESH"
    local rc=$?
    DL_FORCE_REFRESH=0
    UI_RENDER_NEEDED=1

    if [ "$rc" -eq 130 ]; then
        play_sound "back"
        STATE="DL_CONSOLES"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        STATE="DL_CONSOLES"
        # Offline with nothing saved to show: say how to fix it
        wifi_on || { need_wifi; return; }
        play_sound "back"
        toast err "$(source_status_message "$status")"
        return
    fi
    # Some repos worked but not all - say so, but still show what loaded
    [ -s "$status" ] && toast info "Some repos couldn't be read - showing the rest"

    # (shown with the sort / filter choices applied)
    DL_INSTALLED_FOLDER=""
    apply_dl_filters
    if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
        DLF_SORT=repo; DLF_REGION=all; DLF_EXTRAS=show; DLF_INSTALLED=show
        apply_dl_filters
    fi
    STATE="DL_GAMES"
}

# Loads line $1 (0-based) of the current game list into GAME_* variables.
load_dl_entry() {
    local line=$(sed -n "$(($1 + 1))p" "$CACHE_DIR/current_games.cache")
    local mb
    IFS='|' read -r GAME_TITLE GAME_RAW mb GAME_BYTES <<EOF
$line
EOF
    # The file name is the title plus the URL's extension; only decode the URL (an
    # extra program run per press) when the extension itself looks encoded.
    case "${GAME_RAW##*.}" in
        *[%/]*) GAME_FILE=$(url_decode "${GAME_RAW##*/}") ;;
        *) GAME_FILE="$GAME_TITLE.${GAME_RAW##*.}" ;;
    esac
    GAME_BASE="${GAME_FILE%.*}"
}

# (The game list used to read keys with a background getkey; get_key now waits with
# a timeout instead, so there is nothing left to stop.)
stop_dl_key_listener() {
    :
}

# L2 / R2 in a list: jump to the next letter (or back to the start of this one / the
# previous one). $1 list, $2 current index, $3 1 or -1, $4 field with the name.
# Sets SEL and JUMP_LETTER.
letter_jump() {
    local r
    r=$(awk -F'|' -v cur=$(( $2 + 1 )) -v dir="$3" -v fld="$4" '
        function key(s) { sub(/^\{CHECK\}/, "", s); s = toupper(substr(s, 1, 1)); if (s !~ /[A-Z]/) s = "#"; return s }
        { k[NR] = key($fld) }
        END {
            n = NR; if (cur > n) cur = n; c = k[cur]
            if (dir > 0) {
                for (i = cur + 1; i <= n; i++) if (k[i] != c) { print i - 1 "|" k[i]; exit }
                print cur - 1 "|" c; exit
            }
            i = cur
            if (i > 1 && k[i - 1] == c) { while (i > 1 && k[i - 1] == c) i--; print i - 1 "|" c; exit }
            if (i <= 1) { print "0|" c; exit }
            i--; p = k[i]
            while (i > 1 && k[i - 1] == p) i--
            print i - 1 "|" p
        }' "$1")
    SEL=${r%%|*}
    JUMP_LETTER=${r#*|}
    case "$SEL" in ''|*[!0-9]*) SEL=$2 ;; esac
}

# Shows the letter jumped to, big, for a moment
show_letter() {
    [ -n "$RMUI_PID" ] && kill -0 "$RMUI_PID" 2>/dev/null && printf 'LETTER:%s\n' "$1" >&6
}

# Download list filters (Y): kept while the app runs
DLF_SORT=repo        # repo | az | size
DLF_REGION=all       # all | usa | europe | japan
DLF_EXTRAS=show      # show | hide (betas, demos, prototypes, hacks...)
DLF_INSTALLED=show   # show | hide

reset_dl_filters() {
    rm -f "$CACHE_DIR/current_games_full.cache"
}

dl_filters_active() {
    [ "$DLF_SORT$DLF_REGION$DLF_EXTRAS$DLF_INSTALLED" != "repoallshowshow" ]
}

# Names (without extension) of the games already on the SD card for DL_CHOSEN_FOLDER
refresh_dl_installed() {
    [ "$DL_INSTALLED_FOLDER" = "$DL_CHOSEN_FOLDER" ] && [ -f "$CACHE_DIR/dl_installed.txt" ] && return
    list_rom_folder "$DL_CHOSEN_FOLDER" | sed 's/\.[^.]*$//' > "$CACHE_DIR/dl_installed.txt"
    DL_INSTALLED_FOLDER="$DL_CHOSEN_FOLDER"
}

# Makes the shown list (current_games.cache) from the console's full list, with the
# filters and sort order applied
apply_dl_filters() {
    local src="$CACHE_DIR/console_$DL_CHOSEN_FOLDER.list" out="$CACHE_DIR/current_games.cache"
    refresh_dl_installed
    awk -F'|' -v region="$DLF_REGION" -v extras="$DLF_EXTRAS" -v hideinst="$DLF_INSTALLED" '
        NR == FNR { inst[$0] = 1; next }
        {
            t = tolower($1)
            if (hideinst == "hide" && ($1 in inst)) next
            if (extras == "hide" && t ~ /\((beta|proto|prototype|demo|sample|hack|pirate|unl|kiosk|debug|alpha)[^)]*\)|\[(b|h|t|p)[0-9]*\]/) next
            if (region == "usa" && t !~ /\([^)]*(usa|world)[^)]*\)/) next
            if (region == "europe" && t !~ /\([^)]*(europe|world|uk|germany|france|spain|italy|australia)[^)]*\)/) next
            if (region == "japan" && t !~ /\([^)]*(japan|world)[^)]*\)/) next
            print
        }' "$CACHE_DIR/dl_installed.txt" "$src" > "$out.f"
    case "$DLF_SORT" in
        az) sort -f -t'|' -k1,1 "$out.f" > "$out" ;;
        size) sort -t'|' -k4,4nr "$out.f" > "$out" ;;
        *) mv -f "$out.f" "$out" ;;
    esac
    rm -f "$out.f" "$CACHE_DIR/current_games_full.cache"
}

# The Sort & Filter screen for a download list
DLF_INDEX=0
state_dl_filter() {
    local rows="sort region extras installed reread"
    local total_items=5
    local row=$(echo $rows | cut -d' ' -f$((DLF_INDEX + 1)))
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local s r e i
        case "$DLF_SORT" in az) s="A to Z" ;; size) s="Biggest first" ;; *) s="As in the repo" ;; esac
        case "$DLF_REGION" in usa) r="USA" ;; europe) r="Europe" ;; japan) r="Japan" ;; *) r="All" ;; esac
        e="Show"; [ "$DLF_EXTRAS" = "hide" ] && e="Hide"
        i="Show"; [ "$DLF_INSTALLED" = "hide" ] && i="Hide"
        {
            echo "Sort  [$s]"
            echo "Region  [$r]"
            echo "Betas, Demos & Hacks  [$e]"
            echo "Games You Have  [$i]"
            echo "-> Re-read the repos now"
        } > "$CACHE_DIR/dl_filter.disp"
        local footer="<>/ Change  B/ Done"
        [ "$row" = "reread" ] && footer="A/ Re-read  B/ Done"
        draw_simple_list "$CACHE_DIR/dl_filter.disp" "$DLF_INDEX" "Sort & filter: $DL_CHOSEN_DISPLAY" "$footer"
    fi

    get_key || return
    local step=1
    case "$KEY" in
        up|down)
            play_sound "change"
            update_selection "$KEY" "$total_items" 1 "$DLF_INDEX"; DLF_INDEX=$SEL
            ;;
        left|right|A)
            [ "$KEY" = "left" ] && step=-1
            play_sound "change"
            case "$row" in
                sort)
                    if [ "$step" -gt 0 ]; then
                        case "$DLF_SORT" in repo) DLF_SORT=az ;; az) DLF_SORT=size ;; *) DLF_SORT=repo ;; esac
                    else
                        case "$DLF_SORT" in size) DLF_SORT=az ;; az) DLF_SORT=repo ;; *) DLF_SORT=size ;; esac
                    fi
                    ;;
                region)
                    if [ "$step" -gt 0 ]; then
                        case "$DLF_REGION" in all) DLF_REGION=usa ;; usa) DLF_REGION=europe ;; europe) DLF_REGION=japan ;; *) DLF_REGION=all ;; esac
                    else
                        case "$DLF_REGION" in japan) DLF_REGION=europe ;; europe) DLF_REGION=usa ;; usa) DLF_REGION=all ;; *) DLF_REGION=japan ;; esac
                    fi
                    ;;
                extras) if [ "$DLF_EXTRAS" = "hide" ]; then DLF_EXTRAS=show; else DLF_EXTRAS=hide; fi ;;
                installed) if [ "$DLF_INSTALLED" = "hide" ]; then DLF_INSTALLED=show; else DLF_INSTALLED=hide; fi ;;
                reread)
                    [ "$KEY" = "A" ] || { UI_RENDER_NEEDED=1; return; }
                    need_wifi || { UI_RENDER_NEEDED=1; return; }
                    DL_FORCE_REFRESH=1
                    STATE="FETCH_XML"
                    ;;
            esac
            ;;
        B|Y)
            play_sound "back"
            apply_dl_filters
            DL_INDEX=0
            if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
                toast info "Nothing matches - showing everything"
                DLF_SORT=repo; DLF_REGION=all; DLF_EXTRAS=show; DLF_INSTALLED=show
                apply_dl_filters
            fi
            STATE="DL_GAMES"
            ;;
    esac
    UI_RENDER_NEEDED=1
}

state_dl_games() {
    if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
        if [ -s "$CACHE_DIR/current_games_full.cache" ]; then
            # A search left nothing to show - drop the search instead of showing an empty list.
            mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            DL_INDEX=0
            UI_RENDER_NEEDED=1
        else
            STATE="DL_CONSOLES"
            UI_RENDER_NEEDED=1
            return
        fi
    fi

    # (counted again only when the list changed - not on every press)
    if [ -z "$DL_TOTAL_ITEMS" ] || [ "$STATE" != "$LAST_FRAME_STATE" ] || \
        [ "$CACHE_DIR/current_games.cache" -nt "$CACHE_DIR/.dl_counted" ]; then
        DL_TOTAL_ITEMS=$(wc -l < "$CACHE_DIR/current_games.cache")
        : > "$CACHE_DIR/.dl_counted"
        [ "$DL_TOTAL_ITEMS" -le 0 ] && DL_TOTAL_ITEMS=1
        [ "$DL_INDEX" -ge "$DL_TOTAL_ITEMS" ] && DL_INDEX=$((DL_TOTAL_ITEMS - 1))
    fi
    local total_items=$DL_TOTAL_ITEMS

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        refresh_dl_installed
        list_window "$DL_INDEX" "$total_items"
        local start_item=$LIST_START end_item=$LIST_END
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (DL_INDEX * 100) / (total_items - 1) ))

        load_dl_entry "$DL_INDEX"
        local target_dir="$ROMS_DIR/$DL_CHOSEN_FOLDER"

        local marks=""
        [ -f "$target_dir/$GAME_FILE" ] && marks="  ·  on SD card"
        is_favorite "$DL_CHOSEN_FOLDER" "$GAME_FILE" && marks="$marks  ·  favorite"
        # Download size, when the repo lists it (web folders don't)
        local size_text=""
        case "$GAME_BYTES" in ''|*[!0-9]*|0) ;; *) size_text=$(format_size "$GAME_BYTES") ;; esac
        local filt=""
        dl_filters_active && filt="  ·  filtered"
        [ -f "$CACHE_DIR/current_games_full.cache" ] && filt="  ·  search"

        local view_hint="R/ Covers"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"
        local footer="A/ Download  Y/ Sort  Sel/ Search  Start/ Fav  $view_hint  B/ Back"
        [ -f "$CACHE_DIR/current_games_full.cache" ] && footer="A/ Download  X/ Clear search  Start/ Fav  $view_hint  B/ Back"

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$(echo "$DL_CHOSEN_DISPLAY" | cut -c 1-20)${size_text:+  ·  $size_text}$marks$filt  ·  $((DL_INDEX + 1))/$total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:$footer\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        if [ "$GAME_VIEW" = "covers" ]; then
            append_coverflow "$DL_INDEX" "$total_items" "$CACHE_DIR/current_games.cache" dl "$DL_CHOSEN_FOLDER" "$size_text"
            render_ui
            start_cover_fetch
            UI_RENDER_NEEDED=0
        fi
    fi

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local target_dir="$ROMS_DIR/$DL_CHOSEN_FOLDER"
        # Whole titles (rmui cuts them to fit and scrolls the highlighted one); games
        # already on the SD card get a check mark
        local items=$(awk -F'|' -v s=$((start_item + 1)) -v e=$((end_item + 1)) -v n=$ITEM_CHARS '
            NR == FNR { inst[$0] = 1; next }
            FNR >= s && FNR <= e { print (($1 in inst) ? "{CHECK}" : "") substr($1, 1, n) }
            FNR > e { exit }' "$CACHE_DIR/dl_installed.txt" "$CACHE_DIR/current_games.cache")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        : > "$CACHE_DIR/.cover_wanted"
        if [ -s "$target_dir/Imgs/${GAME_BASE}.png" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$target_dir/Imgs/${GAME_BASE}.png\n"
        elif [ -s "$CACHE_DIR/previews/${GAME_BASE}.png" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$CACHE_DIR/previews/${GAME_BASE}.png\n"
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:BLANK\n"
            [ -f "$CACHE_DIR/previews/${GAME_BASE}.png.none" ] || echo "0|$GAME_BASE" > "$CACHE_DIR/.cover_wanted"
        fi

        local rel=$((DL_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$DL_CHOSEN_FOLDER-$total_items\n"
        render_ui
        # (no cover downloads while a game downloads - they'd slow it down)
        dl_worker_alive || start_cover_fetch
    fi

    # Wait for a button, waking now and then to show covers that finished downloading
    # in the background. (Long titles scroll in rmui - no redraws needed for that.)
    if ! get_key 400; then
        if [ -f "$CACHE_DIR/.cover_new" ]; then
            rm -f "$CACHE_DIR/.cover_new"
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$DL_INDEX"; DL_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        L2|R2)
            local dir=1
            [ "$KEY" = "L2" ] && dir=-1
            letter_jump "$CACHE_DIR/current_games.cache" "$DL_INDEX" "$dir" 1
            if [ "$SEL" != "$DL_INDEX" ]; then
                play_sound "change"
                DL_INDEX=$SEL
                show_letter "$JUMP_LETTER"
                UI_RENDER_NEEDED=1
            fi
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            DLF_INDEX=0
            rm -f "$CACHE_DIR/current_games_full.cache"
            STATE="DL_FILTER"
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "change"
            [ ! -f "$CACHE_DIR/current_games_full.cache" ] && cp "$CACHE_DIR/current_games.cache" "$CACHE_DIR/current_games_full.cache"
            STATE="SEARCH_GAMES"
            SEARCH_RETURN_STATE="DL_GAMES"
            OSK_X=0; OSK_Y=0; OSK_BUF=""; OSK_UPPER=0; OSK_LAYER=0
            UI_RENDER_NEEDED=1
            ;;
        start)
            load_dl_entry "$DL_INDEX"
            toggle_favorite "$DL_CHOSEN_FOLDER" "$GAME_FILE" "$GAME_TITLE"
            if is_favorite "$DL_CHOSEN_FOLDER" "$GAME_FILE"; then
                play_sound "confirm"
                toast ok "Added to favorites"
            else
                play_sound "back"
                toast info "Removed from favorites"
            fi
            UI_RENDER_NEEDED=1
            ;;
        X)
            if [ -f "$CACHE_DIR/current_games_full.cache" ]; then
                # Clear the active search
                play_sound "back"
                mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
                DL_INDEX=0
            else
                # Re-read the console's repos from their servers
                need_wifi || { UI_RENDER_NEEDED=1; return; }
                play_sound "change"
                DL_FORCE_REFRESH=1
                STATE="FETCH_XML"
            fi
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            if [ -f "$CACHE_DIR/current_games_full.cache" ]; then
                mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            else
                pos_save dl "$DL_CHOSEN_FOLDER" "$DL_INDEX"
                stop_cover_fetch
                STATE="DL_CONSOLES"
            fi
            UI_RENDER_NEEDED=1
            ;;
        A)
            load_dl_entry "$DL_INDEX"
            local target_dir="$ROMS_DIR/$DL_CHOSEN_FOLDER"
            if [ -f "$target_dir/$GAME_FILE" ]; then
                # Already on the SD card: play it (or delete it) from here
                play_sound "change"
                ask_dialog "You already have this game" "$(echo "$GAME_TITLE" | cut -c 1-34)" -- "Play" "Delete" "Cancel"
                case "$DIALOG_RESULT" in
                    0) launch_game "$DL_CHOSEN_FOLDER" "$GAME_FILE" ;;
                    1)
                        ask_dialog "Delete this game?" "$(echo "$GAME_TITLE" | cut -c 1-34)" -- "Delete" "Cancel"
                        if [ "$DIALOG_RESULT" = "0" ]; then
                            play_sound "back"
                            delete_game "$DL_CHOSEN_FOLDER" "$GAME_FILE"
                            DL_INSTALLED_FOLDER=""
                            toast info "Deleted: $GAME_TITLE"
                        fi
                        ;;
                esac
            else
                play_sound "change"
                confirm_download_game "$DL_CHOSEN_FOLDER"
            fi
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# Explains a failed download from curl's exit code and the HTTP status.
download_error_message() {
    local rc="$1" http="$2"
    case "$rc" in
        6|7) echo "No connection! Check your Wi-Fi." ;;
        28) echo "Download timed out. Try again." ;;
        18|52|56) echo "Connection dropped. Try again." ;;
        23) echo "Couldn't write to SD card (full?)" ;;
        0) echo "Server sent an empty file!" ;;
        22)
            case "$http" in
                404) echo "File is gone from repo. X/ Refresh list." ;;
                401|403) if [ -n "$IA_USER" ]; then echo "Your account can't download this file."; else echo "File needs a login: Settings > archive.org."; fi ;;
                5*) echo "archive.org error ($http). Try later." ;;
                *) echo "Download failed (HTTP $http)." ;;
            esac
            ;;
        *) echo "Download failed (error $rc)." ;;
    esac
}

# ------------------------------------------------------------------
# Download queue
#   Games are added to dl_queue.txt and downloaded one at a time by a background
#   worker, so you can keep browsing (and queue more) meanwhile. Unfinished downloads
#   are kept and carry on where they stopped (curl -C -), even after a restart.
#   Lines: id|status|folder|title|url|file|bytes|message
#   status: wait, run, done, fail
# ------------------------------------------------------------------

DLQ="$CACHE_DIR/dl_queue.txt"
DLQ_LOCK="$CACHE_DIR/.dlq.lock"
DL_PROG="/tmp/rm_dlprog"   # "percent|downloads left" - rmui shows it top right
DL_INFO="/tmp/rm_dlinfo"   # "id|bytes so far|total|bytes per second" - Downloads screen

# The queue is changed by this script and the worker: one at a time (mkdir is atomic)
dlq_lock() {
    local n=0
    while ! mkdir "$DLQ_LOCK" 2>/dev/null; do
        n=$((n + 1))
        # a lock left by a process that died - take it over
        [ "$n" -gt 60 ] && { rmdir "$DLQ_LOCK" 2>/dev/null; n=0; }
        sleep 0.05
    done
}

dlq_unlock() {
    rmdir "$DLQ_LOCK" 2>/dev/null
}

# Sets the status (and message) of queue entry $1
dlq_set() {
    dlq_lock
    awk -F'|' -v OFS='|' -v id="$1" -v st="$2" -v msg="$3" '$1 == id { $2 = st; $8 = msg } { print }' \
        "$DLQ" > "$DLQ.tmp" 2>/dev/null && mv -f "$DLQ.tmp" "$DLQ"
    dlq_unlock
}

dlq_remove() {
    dlq_lock
    awk -F'|' -v id="$1" '$1 != id' "$DLQ" > "$DLQ.tmp" 2>/dev/null && mv -f "$DLQ.tmp" "$DLQ"
    dlq_unlock
}

# Adds a game; prints nothing. Already queued (and not finished) - not added twice.
dlq_add() {
    local folder="$1" title="$2" url="$3" file="$4" bytes="$5" id
    touch "$DLQ"
    dlq_lock
    if awk -F'|' -v f="$folder" -v n="$file" '$3 == f && $6 == n && ($2 == "wait" || $2 == "run") { found = 1 } END { exit !found }' "$DLQ"; then
        dlq_unlock
        return 1
    fi
    id=$(awk -F'|' '$1 + 0 > m { m = $1 + 0 } END { print m + 1 }' "$DLQ")
    echo "$id|wait|$folder|$title|$url|$file|$bytes|" >> "$DLQ"
    dlq_unlock
    return 0
}

# How many are waiting or downloading
dlq_pending() {
    grep -c '^[0-9]*|\(wait\|run\)|' "$DLQ" 2>/dev/null
}

dl_worker_alive() {
    [ -n "$DL_WORKER_PID" ] && kill -0 "$DL_WORKER_PID" 2>/dev/null
}

# Size of a file without reading it (wc -c reads big files through)
file_bytes() {
    local s
    s=$(ls -ln "$1" 2>/dev/null | awk '{ print $5 }')
    echo "${s:-0}"
}

# Downloads queue entry $1 (the worker runs this). Writes progress for rmui and the
# Downloads screen, finishes the game off (cue sheet, box art, Onion's list, recent
# downloads) and says how it went with a notice.
dl_one() {
    local id="$1" folder="$2" title="$3" url="$4" file="$5" bytes="$6"
    local dir="$ROMS_DIR/$folder" tmp="$ROMS_DIR/$folder/.tmp_$file" code_file="/tmp/rm_dlcode"
    local left rc http size
    mkdir -p "$dir"
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    left=$(dlq_pending)

    # Web folders don't list sizes: ask the server (also catches a missing file early)
    if [ "$bytes" -eq 0 ] && [ "$(source_type "$url")" = "http" ]; then
        bytes=$(curl $IA_AUTH -s -I -L -k --connect-timeout 10 -m 20 -A "Mozilla/5.0" "$url" 2>/dev/null \
            | tr -d '\r' | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    fi

    local resume="-C -" tries=0
    while :; do
        rm -f "$code_file"
        (
            code=$(curl $IA_AUTH --fail -s -L -k $resume --retry 2 --retry-delay 2 --connect-timeout 15 \
                --speed-limit 1 --speed-time 60 -A "Mozilla/5.0" -w '%{http_code}' "$url" -o "$tmp" < /dev/null)
            echo "$?|$code" > "$code_file"
        ) &
        local cpid=$! prev=0 speed=0 now pct cancelled=0
        prev=$(file_bytes "$tmp")
        while kill -0 "$cpid" 2>/dev/null; do
            if [ -f "$CACHE_DIR/.dl_cancel_$id" ]; then
                kill_tree "$cpid"
                cancelled=1
                break
            fi
            sleep 0.5
            now=$(file_bytes "$tmp")
            # bytes per second, smoothed so the time left doesn't jump around
            speed=$(( (speed + (now - prev) * 2) / 2 ))
            [ "$speed" -lt 0 ] && speed=0
            prev=$now
            pct=0
            [ "$bytes" -gt 0 ] && pct=$(( now / (bytes / 100 + 1) ))
            [ "$pct" -gt 100 ] && pct=100
            echo "$pct|$left" > "$DL_PROG.tmp" && mv -f "$DL_PROG.tmp" "$DL_PROG"
            echo "$id|$now|$bytes|$speed" > "$DL_INFO.tmp" && mv -f "$DL_INFO.tmp" "$DL_INFO"
        done
        if [ "$cancelled" -eq 1 ]; then
            rm -f "$tmp" "$CACHE_DIR/.dl_cancel_$id"
            dlq_remove "$id"
            return
        fi
        wait "$cpid" 2>/dev/null
        rc=""; http=""
        [ -r "$code_file" ] && IFS='|' read -r rc http < "$code_file"
        rm -f "$code_file"
        rc=${rc:-1}
        # The server can't resume (no ranges): start that file again from the beginning
        if [ "$rc" = "33" ] && [ "$tries" -eq 0 ]; then
            rm -f "$tmp"
            resume=""
            tries=1
            continue
        fi
        break
    done

    size=$(file_bytes "$tmp")
    # Asked to resume a file that was already complete
    [ "$http" = "416" ] && [ "$bytes" -gt 0 ] && [ "$size" -eq "$bytes" ] && rc=0
    if [ "$rc" -eq 0 ] && [ "$bytes" -gt 0 ] && [ "$size" -ne "$bytes" ]; then
        # Shorter: the connection ended early (keep it to carry on). Longer: broken.
        if [ "$size" -gt "$bytes" ]; then
            rm -f "$tmp"
            rc=0
            size=0
        else
            rc=18
        fi
    fi

    if [ "$rc" -eq 0 ] && [ "$size" -gt 0 ]; then
        mv -f "$tmp" "$dir/$file"
        # Bin/cue disc images: the .cue sheet is a separate file next to the .bin
        local cue_url
        cue_url=$(echo "$url" | sed 's/\.[Bb][Ii][Nn]$/.cue/')
        if [ "$cue_url" != "$url" ]; then
            local cue_name=$(url_decode "${cue_url##*/}")
            curl $IA_AUTH --fail -s -L -k --retry 2 --connect-timeout 10 -A "Mozilla/5.0" "$cue_url" -o "$dir/$cue_name" < /dev/null
            [ -s "$dir/$cue_name" ] || rm -f "$dir/$cue_name"
        fi
        # Box art: the cover fetched when it was picked, or a fresh one
        local base="${file%.*}"
        if [ ! -s "$dir/Imgs/$base.png" ]; then
            mkdir -p "$dir/Imgs"
            if [ -s "$CACHE_DIR/.qart_$id.png" ]; then
                mv -f "$CACHE_DIR/.qart_$id.png" "$dir/Imgs/$base.png"
            elif [ "$AUTO_SCRAPE" -eq 1 ]; then
                fetch_libretro_art "$(get_libretro_system "$folder")" "$base" "$dir/Imgs/$base.png"
            fi
        fi
        rm -f "$CACHE_DIR/.qart_$id.png"
        refresh_onion_list "$folder"
        # Recent downloads: newest first, without an older entry for the same game
        { echo "$title|$folder|$file"
          awk -F'|' -v t="$title" -v d="$folder" '!($1 == t && $2 == d)' "$RECENT_DL_FILE" 2>/dev/null | head -n 19
        } > "$RECENT_DL_FILE.w" && mv -f "$RECENT_DL_FILE.w" "$RECENT_DL_FILE"
        dlq_set "$id" done ""
        worker_sound confirm
        toast ok "Ready to play: $title"
    else
        local msg=$(download_error_message "$rc" "$http")
        # Partial files that can carry on are kept; anything else goes
        case "$rc" in 18|28|52|56|6|7|35) ;; *) rm -f "$tmp" ;; esac
        dlq_set "$id" fail "$msg"
        worker_sound back
        toast err "Download failed: $title"
    fi
    touch "$CACHE_DIR/.dl_event"
}

# The worker: takes the next waiting game until none are left
dl_worker_loop() {
    local line id st folder title url file bytes msg
    while :; do
        dlq_lock
        line=$(grep -m 1 '^[0-9]*|wait|' "$DLQ" 2>/dev/null)
        if [ -n "$line" ]; then
            awk -F'|' -v OFS='|' -v id="${line%%|*}" '$1 == id { $2 = "run" } { print }' "$DLQ" > "$DLQ.tmp" \
                && mv -f "$DLQ.tmp" "$DLQ"
        fi
        dlq_unlock
        [ -z "$line" ] && break
        IFS='|' read -r id st folder title url file bytes msg <<EOF
$line
EOF
        dl_one "$id" "$folder" "$title" "$url" "$file" "$bytes"
    done
    rm -f "$DL_PROG" "$DL_INFO"
    touch "$CACHE_DIR/.dl_event"
}

# Starts the worker if there's something to download and it isn't running
dl_worker_start() {
    dl_worker_alive && return 0
    grep -q '^[0-9]*|wait|' "$DLQ" 2>/dev/null || return 0
    # (cover downloads would only slow it down)
    stop_cover_fetch
    dl_worker_loop &
    DL_WORKER_PID=$!
}

# Pauses downloading (leaving the app, starting a game): the partial file stays and
# carries on next time
dl_worker_stop() {
    dl_worker_alive && kill_tree "$DL_WORKER_PID"
    DL_WORKER_PID=""
    rm -f "$DL_PROG" "$DL_INFO"
    [ -f "$DLQ" ] || return
    dlq_lock
    awk -F'|' -v OFS='|' '$2 == "run" { $2 = "wait" } { print }' "$DLQ" > "$DLQ.tmp" && mv -f "$DLQ.tmp" "$DLQ"
    dlq_unlock
}

# Something finished in the background: refresh what the screens show
dl_events() {
    [ -f "$CACHE_DIR/.dl_event" ] || return
    rm -f "$CACHE_DIR/.dl_event"
    dl_worker_alive || DL_WORKER_PID=""
    force_update_local_consoles
    HOME_STALE=1
    DL_INSTALLED_FOLDER=""
    UI_RENDER_NEEDED=1
}

# At boot: hidden partial downloads not in the queue any more are deleted
clean_partial_downloads() {
    rmdir "$DLQ_LOCK" 2>/dev/null
    local keep="$CACHE_DIR/.dl_keep" f
    awk -F'|' '$2 != "done" { print "'"$ROMS_DIR"'/" $3 "/.tmp_" $6 }' "$DLQ" 2>/dev/null > "$keep"
    for f in "$ROMS_DIR"/*/.tmp_*; do
        [ -e "$f" ] || continue
        grep -qxF "$f" "$keep" || rm -f "$f"
    done
    rm -f "$keep" "$CACHE_DIR"/.dl_cancel_* "$DL_PROG" "$DL_INFO"
    # finished entries from before are dropped; unfinished ones wait to carry on
    if [ -f "$DLQ" ]; then
        awk -F'|' -v OFS='|' '$2 == "done" { next } $2 == "run" { $2 = "wait" } { print }' "$DLQ" > "$DLQ.tmp" \
            && mv -f "$DLQ.tmp" "$DLQ"
    fi
}

# At boot: offer to carry on with downloads that didn't finish
offer_resume_downloads() {
    local n=$(dlq_pending)
    [ "${n:-0}" -gt 0 ] || return
    ask_dialog "Finish your downloads?" "$(plural "$n" "download") didn't finish last time." \
        "They carry on from where they stopped." -- "Resume" "Later" "Clear"
    case "$DIALOG_RESULT" in
        0)
            if wifi_on; then
                dl_worker_start
                toast info "Downloading $(plural "$n" game) in the background"
            else
                toast err "Wi-Fi is off - downloads will wait"
            fi
            ;;
        2)
            dl_clear_unfinished
            toast info "Unfinished downloads cleared"
            ;;
    esac
}

dl_clear_unfinished() {
    local id st folder title url file rest
    while IFS='|' read -r id st folder title url file rest; do
        [ "$st" = "done" ] || rm -f "$ROMS_DIR/$folder/.tmp_$file" "$CACHE_DIR/.qart_$id.png"
    done < "$DLQ"
    rm -f "$DLQ"
}

# Wi-Fi must be on to go online. Says so (with what to do) when it's off.
need_wifi() {
    wifi_on && return 0
    play_sound "back"
    ask_dialog "Wi-Fi is off" "Turn it on in Onion: press Menu, then" "Settings > Network > Wi-Fi." -- "OK"
    return 1
}

# Asks to download the game in GAME_* (from a game list or favorites) and queues it.
# Returns 0 when it was queued.
confirm_download_game() {
    local folder="$1"
    local target_dir="$ROMS_DIR/$folder"
    need_wifi || return 1

    local bytes="${GAME_BYTES:-0}"
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    local free_kb=$(free_space_kb "$ROMS_DIR")
    local size_line="Size unknown"
    [ "$bytes" -gt 0 ] && size_line="$(format_size "$bytes")"
    case "$free_kb" in ''|*[!0-9]*) ;; *) size_line="$size_line  ·  $(format_size $((free_kb * 1024))) free" ;; esac
    if [ "$bytes" -gt 0 ] && [ -n "$free_kb" ] && [ "$free_kb" -lt $(( bytes / 1024 + 1024 )) ]; then
        play_sound "back"
        ask_dialog "Not enough space" "$(echo "$GAME_TITLE" | cut -c 1-34)" "Needs $(format_size "$bytes") - $size_line" -- "OK"
        return 1
    fi

    local pending=$(dlq_pending)
    local q_line="" btn="Download"
    if [ "${pending:-0}" -gt 0 ]; then
        q_line="$(plural "$pending" download) ahead of it in the queue"
        btn="Add to queue"
    fi
    if [ -n "$q_line" ]; then
        ask_dialog "Download this game?" "$(echo "$GAME_TITLE" | cut -c 1-34)" "$size_line" "$q_line" -- "$btn" "Cancel"
    else
        ask_dialog "Download this game?" "$(echo "$GAME_TITLE" | cut -c 1-34)" "$size_line" -- "$btn" "Cancel"
    fi
    [ "$DIALOG_RESULT" = "0" ] || { play_sound "back"; return 1; }
    play_sound "confirm"

    # The game only shows in Onion once its emulator is turned on - ask now, before
    # it's downloading in the background
    ensure_emulator "$folder" download

    if ! dlq_add "$folder" "$GAME_TITLE" "$GAME_RAW" "$GAME_FILE" "$bytes"; then
        toast info "Already downloading: $GAME_TITLE"
        return 1
    fi
    dl_worker_start
    if [ "${pending:-0}" -gt 0 ]; then
        toast ok "Added to the queue: $GAME_TITLE"
    else
        toast ok "Downloading: $GAME_TITLE"
    fi
    UI_RENDER_NEEDED=1
    return 0
}

# Kept for the old state name: confirms the highlighted game of the current list
state_confirm_download() {
    load_dl_entry "$DL_INDEX"
    confirm_download_game "$DL_CHOSEN_FOLDER"
    STATE="${DOWNLOAD_RETURN_STATE:-DL_GAMES}"
    UI_RENDER_NEEDED=1
}

# "1.2 MB/s, 3 min left"
speed_text() {
    local now="$1" total="$2" speed="$3" t=""
    [ "${speed:-0}" -gt 0 ] || { echo "starting..."; return; }
    t="$(format_size "$speed")/s"
    if [ "${total:-0}" -gt "$now" ]; then
        local secs=$(( (total - now) / speed ))
        if [ "$secs" -ge 3600 ]; then
            t="$t, $((secs / 3600)) h $(( (secs % 3600) / 60 )) min left"
        elif [ "$secs" -ge 60 ]; then
            t="$t, $(( (secs + 30) / 60 )) min left"
        else
            t="$t, ${secs}s left"
        fi
    fi
    echo "$t"
}

# The download queue: progress, speed and time left; retry, cancel, clear
DLQ_INDEX=0
state_downloads() {
    dl_events
    [ -f "$DLQ" ] || touch "$DLQ"
    local total_items=$(grep -c . "$DLQ")
    if [ "$total_items" -eq 0 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No downloads\nFOOTER:B/ Back\nART:NULL\nITEM:Nothing in the queue\nHIGHLIGHT:-1\n"
        render_ui
        get_key || return
        [ "$KEY" = "B" ] && { play_sound "back"; STATE="${DOWNLOADS_BACK:-DL_CONSOLES}"; UI_RENDER_NEEDED=1; }
        return
    fi
    [ "$DLQ_INDEX" -ge "$total_items" ] && DLQ_INDEX=$((total_items - 1))

    local info_id info_now info_total info_speed
    [ -r "$DL_INFO" ] && IFS='|' read -r info_id info_now info_total info_speed < "$DL_INFO"

    local q_id q_st q_folder q_title q_url q_file q_bytes q_msg
    IFS='|' read -r q_id q_st q_folder q_title q_url q_file q_bytes q_msg <<EOF
$(sed -n "$((DLQ_INDEX + 1))p" "$DLQ")
EOF

    local status
    case "$q_st" in
        run)
            if [ "$info_id" = "$q_id" ]; then
                status="Downloading: $(speed_text "$info_now" "$info_total" "$info_speed")"
            else
                status="Downloading..."
            fi
            ;;
        wait) if dl_worker_alive; then status="Waiting its turn"; else status="Paused - Start/ Resume"; fi ;;
        done) status="Ready to play" ;;
        fail) status="${q_msg:-Download failed}" ;;
    esac

    local footer="Y/ Cancel  B/ Back"
    case "$q_st" in
        done) footer="A/ Play  X/ Clear done  B/ Back" ;;
        fail) footer="A/ Retry  Y/ Remove  X/ Clear done  B/ Back" ;;
        wait) dl_worker_alive || footer="Start/ Resume  Y/ Remove  B/ Back" ;;
    esac

    awk -F'|' -v rid="$info_id" -v rnow="$info_now" -v rtot="$info_total" '{
        st = $2
        if (st == "run") {
            p = (rid == $1 && rtot > 0) ? int(rnow * 100 / rtot) "%" : "..."
            print p "  " $4
        }
        else if (st == "wait") print "Waiting  " $4
        else if (st == "done") print "{CHECK}" $4
        else print "Failed  " $4
    }' "$DLQ" > "$CACHE_DIR/dlq.disp"
    draw_simple_list "$CACHE_DIR/dlq.disp" "$DLQ_INDEX" "$status" "$footer"

    # While downloading, refresh twice a second
    if ! get_key 500; then
        UI_RENDER_NEEDED=1
        return
    fi
    case "$KEY" in
        down|up|left|right)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$DLQ_INDEX"; DLQ_INDEX=$SEL
            ;;
        A)
            if [ "$q_st" = "fail" ]; then
                need_wifi || return
                play_sound "confirm"
                dlq_set "$q_id" wait ""
                dl_worker_start
            elif [ "$q_st" = "done" ] && [ -f "$ROMS_DIR/$q_folder/$q_file" ]; then
                launch_game "$q_folder" "$q_file"
            fi
            ;;
        start)
            if ! dl_worker_alive && need_wifi; then
                play_sound "confirm"
                dl_worker_start
            fi
            ;;
        Y)
            play_sound "change"
            if [ "$q_st" = "run" ]; then
                ask_dialog "Cancel this download?" "$(echo "$q_title" | cut -c 1-34)" -- "Cancel download" "Keep going"
                if [ "$DIALOG_RESULT" = "0" ]; then
                    play_sound "back"
                    touch "$CACHE_DIR/.dl_cancel_$q_id"
                    toast info "Download cancelled"
                fi
            elif [ "$q_st" != "done" ]; then
                rm -f "$ROMS_DIR/$q_folder/.tmp_$q_file" "$CACHE_DIR/.qart_$q_id.png"
                dlq_remove "$q_id"
            fi
            ;;
        X)
            play_sound "back"
            dlq_lock
            awk -F'|' '$2 != "done"' "$DLQ" > "$DLQ.tmp" && mv -f "$DLQ.tmp" "$DLQ"
            dlq_unlock
            DLQ_INDEX=0
            ;;
        B)
            play_sound "back"
            STATE="${DOWNLOADS_BACK:-DL_CONSOLES}"
            ;;
    esac
    UI_RENDER_NEEDED=1
}

# A sound from the worker: straight to the mixer if it's running (the worker must not
# try to restart it - that would start a second one)
worker_sound() {
    [ "$SFX_ENABLED" -eq 1 ] && audio_mixer_alive && echo "sfx $SFX_DIR/$1.wav" >&9
}


state_inst_games() {
    if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
        if [ -s "$CACHE_DIR/current_games_full.cache" ]; then
            # A search (or deleting its last match) left nothing to show - drop the search.
            mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            INST_GAME_INDEX=0
            UI_RENDER_NEEDED=1
        else
            rm -f "$CACHE_DIR/current_games_full.cache"
            STATE="INST_CONSOLES"
            UI_RENDER_NEEDED=1
            return
        fi
    fi

    local total_items=$(wc -l < "$CACHE_DIR/current_games.cache")
    [ "$total_items" -le 0 ] && total_items=1
    [ "$INST_GAME_INDEX" -ge "$total_items" ] && INST_GAME_INDEX=$((total_items - 1))

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((INST_GAME_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((INST_GAME_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (INST_GAME_INDEX * 100) / (total_items - 1) ))

        local highlighted_file=$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
        local base_name="${highlighted_file%.*}"
        local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
        
        local fav_text=""
        is_favorite "$INST_CHOSEN_FOLDER" "$highlighted_file" && fav_text="  ·  favorite"
        local srch=""
        [ -f "$CACHE_DIR/current_games_full.cache" ] && srch="  ·  search"

        build_theme
        local truncated_console=$(echo "$INST_CHOSEN_DISPLAY" | cut -c 1-20)
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Installed: ${truncated_console}$fav_text$srch  ·  $human_pos/$total_items\n"
        local view_hint="R/ Covers"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Play  X/ Scrape  Y/ Delete  Start/ Fav  Sel/ Search  $view_hint  B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        if [ "$GAME_VIEW" = "covers" ]; then
            append_coverflow "$INST_GAME_INDEX" "$total_items" "$CACHE_DIR/current_games.cache" inst "$INST_CHOSEN_FOLDER"
            render_ui
        fi
    fi

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { 
            name = \$1;
            sub(/\.[^.]+$/, \"\", name); 
            print substr(name, 1, $ITEM_CHARS)
        }" "$CACHE_DIR/current_games.cache")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF
        
        if [ -s "${target_dir}/Imgs/${base_name}.png" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:${target_dir}/Imgs/${base_name}.png\n"
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:BLANK\n"
        fi

        local rel=$((INST_GAME_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$DL_CHOSEN_FOLDER$INST_CHOSEN_FOLDER-$total_items\n"
        render_ui
    fi

    get_key || return
    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$INST_GAME_INDEX"; INST_GAME_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        L2|R2)
            local dir=1
            [ "$KEY" = "L2" ] && dir=-1
            letter_jump "$CACHE_DIR/current_games.cache" "$INST_GAME_INDEX" "$dir" 1
            if [ "$SEL" != "$INST_GAME_INDEX" ]; then
                play_sound "change"
                INST_GAME_INDEX=$SEL
                show_letter "$JUMP_LETTER"
                UI_RENDER_NEEDED=1
            fi
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "change"
            [ ! -f "$CACHE_DIR/current_games_full.cache" ] && cp "$CACHE_DIR/current_games.cache" "$CACHE_DIR/current_games_full.cache"
            STATE="SEARCH_GAMES"
            SEARCH_RETURN_STATE="INST_GAMES"
            OSK_X=0; OSK_Y=0; OSK_BUF=""; OSK_UPPER=0; OSK_LAYER=0
            UI_RENDER_NEEDED=1
            ;;
        start)
            local game_line=$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
            toggle_favorite "$INST_CHOSEN_FOLDER" "$game_line" "${game_line%.*}"
            if is_favorite "$INST_CHOSEN_FOLDER" "$game_line"; then
                play_sound "confirm"
                toast ok "Added to favorites"
            else
                play_sound "back"
                toast info "Removed from favorites"
            fi
            UI_RENDER_NEEDED=1
            ;;
        X)
            play_sound "change"
            STATE="CONFIRM_SINGLE_SCRAPE"
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            STATE="CONFIRM_DELETE"
            UI_RENDER_NEEDED=1
            ;;
        A)
            local game_file=$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
            launch_game "$INST_CHOSEN_FOLDER" "$game_file"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            if [ -f "$CACHE_DIR/current_games_full.cache" ]; then
                mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            else
                pos_save inst "$INST_CHOSEN_FOLDER" "$INST_GAME_INDEX"
                update_local_consoles
                STATE="INST_CONSOLES"
            fi
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_favorites() {
    sed -i '/^$/d' "$FAV_FILE" 2>/dev/null

    if [ ! -s "$FAV_FILE" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No favorites yet\nFOOTER:B/ Back\nART:NULL\nITEM:Press Start on any game to add it here\nHIGHLIGHT:-1\n"
            render_ui
        fi
        get_key || return
        if [ "$KEY" = "B" ]; then
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    local total_items=$(wc -l < "$FAV_FILE")
    [ "$total_items" -le 0 ] && total_items=1
    [ "$FAV_INDEX" -ge "$total_items" ] && FAV_INDEX=$((total_items - 1))

    # The highlighted favorite: "folder|file|title"
    local fld fn ftitle installed=0
    IFS='|' read -r fld fn ftitle <<EOF
$(sed -n "$((FAV_INDEX + 1))p" "$FAV_FILE" | tr -d '\r')
EOF
    [ -n "$fn" ] && [ -f "$ROMS_DIR/$fld/$fn" ] && installed=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((FAV_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((FAV_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (FAV_INDEX * 100) / (total_items - 1) ))

        local base_name="${fn%.*}" art="BLANK"
        if [ -s "$ROMS_DIR/$fld/Imgs/$base_name.png" ]; then
            art="$ROMS_DIR/$fld/Imgs/$base_name.png"
        elif [ -s "$CACHE_DIR/previews/$base_name.png" ]; then
            art="$CACHE_DIR/previews/$base_name.png"
        fi

        local view_hint="R/ Covers" action="A/ Play  Y/ Delete"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"
        [ "$installed" -eq 0 ] && action="A/ Install"

        build_theme
        local note=""
        [ "$installed" -eq 0 ] && note="  ·  not downloaded"
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Favorites: $(get_console_name "$fld")$note  ·  $human_pos/$total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:$action  Start/ Unfav  $view_hint  B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        if [ "$GAME_VIEW" = "covers" ]; then
            append_coverflow "$FAV_INDEX" "$total_items" "$FAV_FILE" multi ""
        else
            local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$3, 1, $ITEM_CHARS) }" "$FAV_FILE")
            while read -r name; do
                [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
            done <<EOF
$items
EOF
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$art\n"
            local rel=$((FAV_INDEX - start_item))
            UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$total_items\n"
        fi
        render_ui
    fi

    get_key || return
    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$FAV_INDEX"; FAV_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        A)
            [ -z "$fn" ] && return
            if [ "$installed" -eq 1 ]; then
                launch_game "$fld" "$fn"
            else
                play_sound "change"
                # Find the game in its console's repos to get its download address
                local base_name="${fn%.*}"
                DL_CHOSEN_FOLDER="$fld"
                DL_CHOSEN_DISPLAY=$(get_console_name "$fld")
                local list="$CACHE_DIR/console_$fld.list" status="$CACHE_DIR/.fetch_status"
                run_with_spinner "Finding game in repos" build_console_games "$fld" "$list" "$status" 0
                local found=""
                [ -s "$list" ] && found=$(awk -F'|' -v t="$base_name" -v e=".${fn##*.}" '
                    $1 == t && tolower(substr($2, length($2) - length(e) + 1)) == tolower(e) { print; exit }' "$list")

                if [ -z "$found" ]; then
                    play_sound "back"
                    show_message "This game isn't in any repo for $fld anymore." 2
                else
                    echo "$found" > "$CACHE_DIR/current_games.cache"
                    DL_INDEX=0
                    DOWNLOAD_RETURN_STATE="FAVORITES"
                    STATE="CONFIRM_DOWNLOAD"
                fi
            fi
            UI_RENDER_NEEDED=1
            ;;
        Y)
            [ "$installed" -eq 1 ] || return
            play_sound "change"
            ask_dialog "Delete this game?" "$(echo "${ftitle:-${fn%.*}}" | cut -c 1-34)" "$(get_console_name "$fld")" \
                "It's taken out of favorites too." -- "Delete" "Cancel"
            if [ "$DIALOG_RESULT" = "0" ]; then
                play_sound "back"
                delete_game "$fld" "$fn"
                CF_LAST_SEL=""
            fi
            UI_RENDER_NEEDED=1
            ;;
        start)
            play_sound "back"
            remove_favorite "$fld" "$fn"
            CF_LAST_SEL=""
            toast info "Removed from favorites"
            local remaining=$(wc -l < "$FAV_FILE")
            [ "$FAV_INDEX" -ge "$remaining" ] && FAV_INDEX=$((remaining - 1))
            [ "$FAV_INDEX" -lt 0 ] && FAV_INDEX=0
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# X on an installed game: fetch its box art (asks first if it already has some)
state_confirm_single_scrape() {
    local game_file=$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
    local base_name="${game_file%.*}"
    local target_dir="$ROMS_DIR/$INST_CHOSEN_FOLDER"
    STATE="INST_GAMES"
    UI_RENDER_NEEDED=1
    if [ -s "$target_dir/Imgs/$base_name.png" ]; then
        ask_dialog "Get new box art?" "$(echo "$base_name" | cut -c 1-34)" "Its current cover is replaced." -- "Get art" "Cancel"
        [ "$DIALOG_RESULT" = "0" ] || { play_sound "back"; return; }
    fi
    need_wifi || return
    play_sound "change"
    toast info "Looking for box art..."
    mkdir -p "$target_dir/Imgs"
    local tmp="$CACHE_DIR/.scrape_art.png"
    rm -f "$tmp"
    if fetch_libretro_art "$(get_libretro_system "$INST_CHOSEN_FOLDER")" "$base_name" "$tmp" && [ -s "$tmp" ]; then
        mv -f "$tmp" "$target_dir/Imgs/$base_name.png"
        # the renderer keeps pictures by name: make it load the new one
        [ -n "$RMUI_PID" ] && echo "FLUSH_CACHE" >&6
        play_sound "confirm"
        toast ok "Box art found"
    else
        rm -f "$tmp"
        play_sound "back"
        toast err "No box art found for this game"
    fi
}

# Lists the files that belong to a game: the file itself, plus its disc companions -
# the tracks a .cue sheet points at, or the .cue sheet next to a .bin.
# Onion's emulator for a ROM folder: the Emu/*/config.json whose "rompath" points at
# Roms/<folder>. Prints the emulator's launch script.
find_emulator() {
    local folder="$1" cfg
    for cfg in /mnt/SDCARD/Emu/*/config.json /mnt/SDCARD/RApp/*/config.json; do
        [ -f "$cfg" ] || continue
        if tr -d '\r' < "$cfg" | awk -v f="$folder" '
            /"rompath"/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); sub(/\/+$/, "", v)
                          n = split(v, p, "/"); if (toupper(p[n]) == toupper(f)) found = 1 }
            END { exit !found }'; then
            local dir="${cfg%/config.json}"
            local launch=$(tr -d '\r' < "$cfg" | awk '/"launch"/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); print v; exit }')
            [ -f "$dir/${launch:-launch.sh}" ] || continue
            echo "$dir/${launch:-launch.sh}"
            return 0
        fi
    done
    return 1
}

# Onion ships every emulator as a package, but only the ones turned on in its Package
# Manager are copied into /mnt/SDCARD/Emu. This finds the (not yet enabled) package for
# a ROM folder in the Package Manager's store. Prints "layer|package".
find_emulator_package() {
    local folder="$1" layer cfg rest
    for layer in Emu RApp; do
        for cfg in /mnt/SDCARD/App/PackageManager/data/$layer/*/$layer/*/config.json; do
            [ -f "$cfg" ] || continue
            if tr -d '\r' < "$cfg" | awk -v f="$folder" '
                /"rompath"/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); sub(/\/+$/, "", v)
                              n = split(v, p, "/"); if (toupper(p[n]) == toupper(f)) found = 1 }
                END { exit !found }'; then
                rest="${cfg#/mnt/SDCARD/App/PackageManager/data/$layer/}"
                echo "$layer|${rest%%/*}"
                return 0
            fi
        done
    done
    return 1
}

# Turns an emulator package on the way Onion's Package Manager does: with Onion's own
# install script (which copies the package onto the SD card), or a plain copy.
enable_emulator_package() {
    local layer="$1" pkg="$2" data="/mnt/SDCARD/App/PackageManager/data/$1" f
    if [ -f /mnt/SDCARD/.tmp_update/script/pacman_install.sh ]; then
        sh /mnt/SDCARD/.tmp_update/script/pacman_install.sh "$data" "$pkg" >/dev/null 2>&1
    else
        for f in "$data/$pkg"/*; do
            cp -rf "$f" /mnt/SDCARD/
        done
    fi
    sync
}

# Makes sure Onion has an emulator for a ROM folder, offering to turn it on if it's
# only in the Package Manager. $2: "launch" or "download" (changes the wording).
# Returns 0 when one is there.
ensure_emulator() {
    local folder="$1" why="$2" name=$(get_console_name "$1")
    [ -n "$(find_emulator "$folder")" ] && return 0
    local found=$(find_emulator_package "$folder")
    if [ -z "$found" ]; then
        [ "$why" = "launch" ] && show_message "Onion has no emulator for $name on this device." 2.5
        return 1
    fi
    local pkg="${found#*|}"
    play_sound "change"
    if [ "$why" = "launch" ]; then
        ask_dialog "Turn on $name?" "Its emulator is off in Onion's" "Package Manager. Turn on:" "$(echo "$pkg" | cut -c 1-34)" -- "Turn on" "Cancel"
    else
        ask_dialog "Turn on $name?" "Onion won't show this game until" "its emulator is on. Turn on:" "$(echo "$pkg" | cut -c 1-34)" -- "Turn on" "Later"
    fi
    [ "$DIALOG_RESULT" = "0" ] || return 1
    busy_frame "Turning on $name..."
    enable_emulator_package "${found%%|*}" "$pkg"
    if [ -n "$(find_emulator "$folder")" ]; then
        play_sound "confirm"
        show_message "$name is on! It shows in Onion's game list." 1.8
        return 0
    fi
    play_sound "back"
    show_message "Couldn't turn it on - use Onion's Package Manager." 2.5
    return 1
}

# Starts a game by handing it to Onion: Onion runs .tmp_update/cmd_to_run.sh after this
# app closes, and /tmp/quick_switch tells it to keep that command instead of going
# back to the main menu - the way Onion's own GameSwitcher starts games.
launch_game() {
    local folder="$1" file="$2" emu
    ensure_emulator "$folder" launch || return 1
    emu=$(find_emulator "$folder")
    # A disc's .bin plays through its .cue sheet
    case "$file" in
        *.[Bb][Ii][Nn])
            [ -f "$ROMS_DIR/$folder/${file%.*}.cue" ] && file="${file%.*}.cue"
            ;;
    esac
    # Downloads stop while a game runs (they carry on when RomManager opens again)
    if dl_worker_alive; then
        ask_dialog "Pause your downloads?" "Downloads stop while you play and" "carry on when you come back." -- "Play" "Cancel"
        [ "$DIALOG_RESULT" = "0" ] || { play_sound "back"; return 1; }
    fi
    play_sound "confirm"
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Starting ${file%.*}...\nART:NULL\n"
    local art="$ROMS_DIR/$folder/Imgs/${file%.*}.png"
    if [ -s "$art" ]; then
        UI_FRAME_BUF="${UI_FRAME_BUF}COVERFLOW:0:1:launch\nCOVER:0:$art\nCFLABEL:${file%.*}\n"
    fi
    render_ui
    # Onion runs this file once the app has closed. It has to stay ONE line of the
    # form  ... "emulator" "rom"  - Onion reads the ROM's path from it line by line
    # (an extra line here once made every game "not found"). With Default Launcher on,
    # the line starts with a shell trap that opens RomManager again when the game ends.
    local hook=""
    if [ "$LAUNCHER" = "1" ]; then
        write_after_game_hook
        hook="trap 'sh $RM_AFTER_HOOK' EXIT; "
    fi
    printf '%sLD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so "%s" "%s"\n' "$hook" "$emu" "$ROMS_DIR/$folder/$file" \
        > /mnt/SDCARD/.tmp_update/cmd_to_run.sh
    add_onion_recent "$folder" "$file" "$emu"
    touch /tmp/quick_switch
    sync
    shutdown_app
}

# Puts the game at the top of Onion's recent list (Roms/recentlist.json), the list
# Onion's game switcher and Recents show - Onion's menu does this for games it starts.
# Same line format as Onion's (one JSON object per line, newest first), with the
# rompath written the way Onion writes it (emulator folder/../../Roms/...), and any
# older entry for the game removed.
add_onion_recent() {
    local folder="$1" file="$2" emu="$3" list=/mnt/SDCARD/Roms/recentlist.json
    [ -f /mnt/SDCARD/.tmp_update/config/.showRecents ] || list=/mnt/SDCARD/Roms/recentlist-hidden.json
    local emudir="${emu%/*}"
    json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    local label=$(json_esc "${file%.*}")
    local rom=$(json_esc "$emudir/../../Roms/$folder/$file")
    local img=$(json_esc "$emudir/../../Roms/$folder/Imgs/${file%.*}.png")
    local launch=$(json_esc "$emu")
    {
        printf '{"label":"%s","launch":"%s","type":5,"imgpath":"%s","rompath":"%s"}\n' "$label" "$launch" "$img" "$rom"
        [ -f "$list" ] && awk -v t="/Roms/$folder/$(json_esc "$file")\"" 'index($0, t) == 0' "$list"
    } > "$list.rm_tmp" && mv -f "$list.rm_tmp" "$list"
    sync
}

# ---- Default Launcher ----
# While RomManager is open, games started from it come back to it - and so does B in
# Onion's game switcher (Menu in a game, or Menu here). Closing RomManager ends that:
# nothing opens it again until you do.
#
# The game's command line in cmd_to_run.sh starts with "trap 'sh /tmp/rm_after.sh' EXIT",
# so when the game ends that script puts RomManager's command back in cmd_to_run.sh and
# touches /tmp/quick_switch - Onion then runs it instead of going to its menu. The hook
# lives in /tmp (gone after a restart) and its path doesn't mention /mnt/SDCARD/App/,
# which Onion would take for an app launch.
RM_AFTER_HOOK=/tmp/rm_after.sh
RM_RELAUNCH='cd /mnt/SDCARD/App/RomManager; sh ./launch.sh'

write_after_game_hook() {
    cat > "$RM_AFTER_HOOK" <<'HOOK'
#!/bin/sh
# RomManager (Settings > Default Launcher): runs when a game started from RomManager ends
c=/mnt/SDCARD/.tmp_update/cmd_to_run.sh
if [ -f "$c" ] && ! grep -q "rm_after" "$c"; then
    # Onion's game switcher already picked the next game: come back after that one
    grep -q "/mnt/SDCARD/Roms/\|/\.\./\.\./Roms/" "$c" && sed -i "1s|^|trap 'sh /tmp/rm_after.sh' EXIT; |" "$c"
    exit 0
fi
echo 'cd /mnt/SDCARD/App/RomManager; sh ./launch.sh' > "$c"
touch /tmp/quick_switch
# (tells RomManager it is coming back from a game: no boot screen, same screen as before)
touch /tmp/rm_return
# Menu was pressed in the game: Onion shows its game switcher first - watch it
if [ -f /mnt/SDCARD/.tmp_update/.runGameSwitcher ]; then
    w=/mnt/SDCARD/App/RomManager/lib/switcher_watch.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$w" </dev/null >/dev/null 2>&1 &
    else
        sh "$w" </dev/null >/dev/null 2>&1 &
    fi
fi
sync
exit 0
HOOK
}

# Menu: Onion's game switcher, the same as in Onion's own menu
open_game_switcher() {
    [ -n "$SWITCHER_ASKING" ] && return 1
    if dl_worker_alive; then
        SWITCHER_ASKING=1
        ask_dialog "Pause your downloads?" "Downloads stop while you're away" "and carry on when you come back." -- "Go" "Cancel"
        SWITCHER_ASKING=""
        UI_RENDER_NEEDED=1
        [ "$DIALOG_RESULT" = "0" ] || { play_sound "back"; return 1; }
    fi
    play_sound "confirm"
    touch /mnt/SDCARD/.tmp_update/.runGameSwitcher
    if [ "$LAUNCHER" = "1" ]; then
        # Onion runs the switcher once we close; our command stays in cmd_to_run.sh so
        # Onion comes back here afterwards, and the watcher puts it back if B in the
        # switcher deletes it
        write_after_game_hook
        echo "$RM_RELAUNCH" > /mnt/SDCARD/.tmp_update/cmd_to_run.sh
        if command -v setsid >/dev/null 2>&1; then
            setsid sh ./lib/switcher_watch.sh </dev/null >/dev/null 2>&1 &
        else
            sh ./lib/switcher_watch.sh </dev/null >/dev/null 2>&1 &
        fi
    fi
    sync
    shutdown_app
}

# The screen you were on, saved on the way out: coming back from a game always returns
# there; opening RomManager from Onion only with Open To > Where I Left Off
save_spot() {
    # (field 3: the game name only - download-list lines carry "|size" after it)
    echo "$STATE|$INST_CHOSEN_FOLDER|$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache" 2>/dev/null | cut -d"|" -f1)|$INST_GAME_INDEX|$FAV_INDEX|$RECENT_INDEX|$DL_CONSOLE_INDEX|$SET_INDEX|$MAIN_INDEX|$DL_CHOSEN_FOLDER|$DL_INDEX" \
        > "$CACHE_DIR/resume.txt"
}

# Back to the saved screen, on the same game. $1: 1 when coming back from a game.
resume_spot() {
    local f="$CACHE_DIR/resume.txt" st folder file gi fav_i rec_i dl_i set_i main_i dl_fld dl_gi
    [ -f "$f" ] || return
    IFS='|' read -r st folder file gi fav_i rec_i dl_i set_i main_i dl_fld dl_gi < "$f"
    rm -f "$f"
    [ "$1" = "1" ] || [ "$START_SCREEN" = "last" ] || return
    MAIN_INDEX=${main_i:-0}
    case "$st" in
        INST_CONSOLES) update_local_consoles; INST_INDEX=0; MAIN_INDEX=1; STATE="INST_CONSOLES" ;;
        DL_GAMES|DL_FILTER)
            # the download list is still in current_games.cache
            MAIN_INDEX=0
            refresh_dl_consoles
            DL_CONSOLE_INDEX=${dl_i:-0}
            STATE="DL_CONSOLES"
            if [ -n "$dl_fld" ] && [ -s "$CACHE_DIR/current_games.cache" ]; then
                DL_CHOSEN_FOLDER="$dl_fld"
                DL_CHOSEN_DISPLAY=$(get_console_name "$dl_fld")
                DL_INDEX=${dl_gi:-0}
                DL_TOTAL_ITEMS=""
                STATE="DL_GAMES"
            fi
            ;;
        DL_CONSOLES|FETCH_XML|SEARCH_GAMES)
            MAIN_INDEX=0
            refresh_dl_consoles
            DL_CONSOLE_INDEX=${dl_i:-0}
            STATE="DL_CONSOLES"
            ;;
        SETTINGS) SET_INDEX=${set_i:-0}; MAIN_INDEX=5; STATE="SETTINGS" ;;
        MANAGE_REPOS) MAIN_INDEX=4; STATE="MANAGE_REPOS" ;;
        INST_GAMES)
            [ -d "$ROMS_DIR/$folder" ] || return
            INST_CHOSEN_FOLDER="$folder"
            INST_CHOSEN_DISPLAY=$(get_console_name "$folder")
            list_rom_folder "$folder" > "$CACHE_DIR/current_games.cache"
            rm -f "$CACHE_DIR/current_games_full.cache"
            # find the game by name (the list may have changed)
            INST_GAME_INDEX=$(awk -v f="$file" '$0 == f { print NR - 1; exit }' "$CACHE_DIR/current_games.cache")
            INST_GAME_INDEX=${INST_GAME_INDEX:-${gi:-0}}
            INST_INDEX=$(awk -F'|' -v f="$folder" '$1 == f { print NR - 1; exit }' "$CACHE_DIR/local_consoles.cache")
            INST_INDEX=${INST_INDEX:-0}
            MAIN_INDEX=1
            STATE="INST_GAMES"
            ;;
        FAVORITES) FAV_INDEX=${fav_i:-0}; MAIN_INDEX=2; STATE="FAVORITES" ;;
        RECENT_DOWNLOADS) prune_recent; RECENT_INDEX=${rec_i:-0}; MAIN_INDEX=3; STATE="RECENT_DOWNLOADS" ;;
        DOWNLOADS) MAIN_INDEX=0; refresh_dl_consoles; STATE="DOWNLOADS" ;;
    esac
}

game_files_for() {
    local dir="$1" file="$2"
    echo "$file"
    case "$file" in
        *.[Cc][Uu][Ee])
            # FILE "Game (Track 1).bin" BINARY - only plain names in the same folder
            tr -d '\r' < "$dir/$file" 2>/dev/null | awk -F'"' 'toupper($1) ~ /^[ \t]*FILE[ \t]*$/ && $2 !~ /\// { print $2 }' \
                | while read -r track; do
                    [ -f "$dir/$track" ] && echo "$track"
                done
            ;;
        *.[Bb][Ii][Nn])
            local cue
            # Stop at the first hit: the SD card ignores case, so both names can be one file.
            for cue in "${file%.*}.cue" "${file%.*}.CUE"; do
                if [ -f "$dir/$cue" ]; then
                    echo "$cue"
                    break
                fi
            done
            ;;
    esac
}

# Deletes a game with its disc files (.cue/.bin) and box art, and takes it out of
# favorites and recent downloads. Onion's list for the console is refreshed.
delete_game() {
    local folder="$1" file="$2" dir="$ROMS_DIR/$1" f
    game_files_for "$dir" "$file" | sort -u | while IFS= read -r f; do
        [ -z "$f" ] && continue
        rm -f "$dir/$f" "$dir/Imgs/${f%.*}.png"
        remove_favorite "$folder" "$f"
    done
    awk -F'|' -v d="$folder" -v t="${file%.*}" '!($2 == d && $1 == t)' "$RECENT_DL_FILE" > "$RECENT_DL_FILE.tmp" 2>/dev/null
    mv -f "$RECENT_DL_FILE.tmp" "$RECENT_DL_FILE"
    refresh_onion_list "$folder"
    force_update_local_consoles
}

# The file of a recent download ("title|folder|file" lines; older ones have no file,
# so it's looked up by title). Prints nothing if it's gone.
recent_entry_file() {
    local title="$1" dir="$ROMS_DIR/$2" file="$3"
    if [ -n "$file" ] && [ -f "$dir/$file" ]; then
        echo "$file"
        return
    fi
    ls -1 "$dir" 2>/dev/null | awk -v t="$title" 'index($0, t ".") == 1 && substr($0, length(t) + 2) !~ /\./ { print; exit }'
}

# Drops recent downloads that were deleted since, and fills in missing file names.
prune_recent() {
    local title folder file found
    [ -s "$RECENT_DL_FILE" ] || return
    while IFS='|' read -r title folder file; do
        [ -z "$title" ] && continue
        found=$(recent_entry_file "$title" "$folder" "$file")
        [ -n "$found" ] && echo "$title|$folder|$found"
    done < "$RECENT_DL_FILE" > "$RECENT_DL_FILE.tmp"
    mv -f "$RECENT_DL_FILE.tmp" "$RECENT_DL_FILE"
}

# Y on an installed game: delete it (with its disc files and box art) after asking
state_confirm_delete() {
    local game_file=$(sed -n "$((INST_GAME_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
    local target_dir="$ROMS_DIR/$INST_CHOSEN_FOLDER"
    local delete_list="$CACHE_DIR/.delete_files"
    game_files_for "$target_dir" "$game_file" | sort -u > "$delete_list"
    local file_count=$(wc -l < "$delete_list")
    STATE="INST_GAMES"
    UI_RENDER_NEEDED=1

    local note="Its box art is deleted too."
    [ "$file_count" -gt 1 ] && note="All $file_count of its files are deleted."
    ask_dialog "Delete this game?" "$(echo "${game_file%.*}" | cut -c 1-34)" "$note" -- "Delete" "Cancel"
    if [ "$DIALOG_RESULT" != "0" ]; then
        play_sound "back"
        rm -f "$delete_list"
        return
    fi
    play_sound "back"
    delete_game "$INST_CHOSEN_FOLDER" "$game_file"
    # Take the deleted files out of the list in place, so the cursor stays where it was
    local list
    for list in "$CACHE_DIR/current_games.cache" "$CACHE_DIR/current_games_full.cache"; do
        [ -f "$list" ] || continue
        grep -vxFf "$delete_list" "$list" > "$list.tmp"
        mv "$list.tmp" "$list"
    done
    rm -f "$delete_list"
    toast info "Deleted: ${game_file%.*}"
}

reset_return_list_position() {
    [ "$SEARCH_RETURN_STATE" = "DL_GAMES" ] && DL_INDEX=0
    [ "$SEARCH_RETURN_STATE" = "INST_GAMES" ] && INST_GAME_INDEX=0
}

# Leaves the search keyboard and shows the filtered list - unless nothing matches, in
# which case it stays put and says so, instead of dropping into an empty list.
finish_search() {
    if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
        play_sound "back"
        show_message "No matches! Edit search or Sel/ Cancel." 1.5
        return
    fi
    play_sound "confirm"
    reset_return_list_position
    STATE="$SEARCH_RETURN_STATE"
}

state_search_games() {
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local match_count=$(wc -l < "$CACHE_DIR/current_games.cache")
        local caps_txt="OFF"
        [ "$OSK_UPPER" -eq 1 ] && caps_txt="ON"

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Search: $(plural "$match_count" match matches)  ·  caps $caps_txt\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Type  B/ Delete  L/ Space  R/ Caps  Start/ Done  Sel/ Cancel\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}OSK:$OSK_X:$OSK_Y:$OSK_BUF\nOSK_KEYS:$(osk_keys)\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        up|down|left|right|R)
            play_sound "change"
            handle_osk_navigation
            UI_RENDER_NEEDED=1
            ;;
        L)
            # Space separates search words ("mario 3"). No leading or double spaces.
            case "$OSK_BUF" in
                ""|*" ") play_sound "back" ;;
                *) play_sound "change"; OSK_BUF="${OSK_BUF} " ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            OSK_BUF="${OSK_BUF%?}"
            apply_search_filter
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "back"
            cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            rm -f "$CACHE_DIR/current_games_full.cache"
            STATE="$SEARCH_RETURN_STATE"
            UI_RENDER_NEEDED=1
            ;;
        start|X)
            finish_search
            UI_RENDER_NEEDED=1
            ;;
        A)
            local char=$(osk_char)
            if [ -n "$char" ]; then
                play_sound "change"
                OSK_BUF="${OSK_BUF}${char}"
            elif [ "$OSK_Y" -eq 5 ]; then
                case "$OSK_X" in
                    3) play_sound "change"; OSK_UPPER=$((1 - OSK_UPPER)) ;;
                    4) play_sound "back"; OSK_BUF="${OSK_BUF%?}" ;;
                    5)
                        play_sound "back"
                        cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
                        rm -f "$CACHE_DIR/current_games_full.cache"
                        STATE="$SEARCH_RETURN_STATE"
                        ;;
                    6) apply_search_filter; finish_search ;;
                esac
            fi

            [ "$STATE" = "SEARCH_GAMES" ] && apply_search_filter
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_recent_downloads() {
    if [ ! -s "$RECENT_DL_FILE" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No downloads yet\nFOOTER:B/ Back\nART:NULL\nITEM:Games you download show up here\nHIGHLIGHT:-1\n"
            render_ui
        fi
        get_key || return
        if [ "$KEY" = "B" ]; then
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    local total_items=$(wc -l < "$RECENT_DL_FILE")
    [ "$total_items" -le 0 ] && total_items=1
    [ "$RECENT_INDEX" -ge "$total_items" ] && RECENT_INDEX=$((total_items - 1))

    # The highlighted game: "title|folder|file"
    local r_title r_folder r_file
    IFS='|' read -r r_title r_folder r_file <<EOF
$(sed -n "$((RECENT_INDEX + 1))p" "$RECENT_DL_FILE")
EOF

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((RECENT_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((RECENT_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (RECENT_INDEX * 100) / (total_items - 1) ))

        local art="BLANK"
        [ -s "$ROMS_DIR/$r_folder/Imgs/${r_file%.*}.png" ] && art="$ROMS_DIR/$r_folder/Imgs/${r_file%.*}.png"

        local fav_text="" view_hint="R/ Covers"
        is_favorite "$r_folder" "$r_file" && fav_text="  ·  favorite"
        [ "$GAME_VIEW" = "covers" ] && view_hint="R/ List"

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Recent: $(get_console_name "$r_folder")$fav_text  ·  $human_pos/$total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Play  Y/ Delete  Start/ Fav  $view_hint  B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        if [ "$GAME_VIEW" = "covers" ]; then
            # Cover flow reads "folder|file|title" lines, like favorites
            awk -F'|' '{ print $2 "|" $3 "|" $1 }' "$RECENT_DL_FILE" > "$CACHE_DIR/.recent_cf"
            append_coverflow "$RECENT_INDEX" "$total_items" "$CACHE_DIR/.recent_cf" multi ""
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$art\n"
            local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$1, 1, $ITEM_CHARS) }" "$RECENT_DL_FILE")
            while read -r name; do
                [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
            done <<EOF
$items
EOF
            local rel=$((RECENT_INDEX - start_item))
            UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$total_items\n"
        fi
        render_ui
    fi

    get_key || return
    [ "$GAME_VIEW" = "covers" ] && coverflow_key

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$RECENT_INDEX"; RECENT_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        R)
            play_sound "change"
            toggle_game_view
            UI_RENDER_NEEDED=1
            ;;
        start)
            [ -z "$r_file" ] && return
            play_sound "confirm"
            toggle_favorite "$r_folder" "$r_file" "$r_title"
            if is_favorite "$r_folder" "$r_file"; then toast ok "Added to favorites"; else toast info "Removed from favorites"; fi
            UI_RENDER_NEEDED=1
            ;;
        A)
            launch_game "$r_folder" "$r_file"
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            ask_dialog "Delete this game?" "$(echo "$r_title" | cut -c 1-34)" "$(get_console_name "$r_folder")" -- "Delete" "Cancel"
            if [ "$DIALOG_RESULT" = "0" ]; then
                play_sound "back"
                delete_game "$r_folder" "$r_file"
                CF_LAST_SEL=""
            fi
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}


# ------------------------------------------------------------------
# Manage Repositories
#   MANAGE_REPOS -> REPO_SOURCE_INPUT -> REPO_PICK_CONSOLE -> CHECK_REPO -> (PACK_CONFIRM)
# Repos are stored in repos.txt (see lib/sources.sh), which can also be edited on a PC.
# ------------------------------------------------------------------

REPO_FORMATS=" zip chd bin 7z rar iso|cso"

# One line per menu row: "+" for the Add row, then "n|console|source|format".
refresh_repo_rows() {
    {
        echo "+"
        repos_list | awk '{ print NR "|" $0 }'
    } > "$CACHE_DIR/repo_rows.list"
}

# Shared list drawing for the repo screens: rows from $1 (display text in field 1),
# selection $2, status $3, footer $4.
draw_simple_list() {
    local list="$1" index="$2" status="$3" footer="$4"
    local total_items=$(wc -l < "$list")
    [ "$total_items" -le 0 ] && total_items=1
    local start_item=$((index - 4))
    [ "$start_item" -lt 0 ] && start_item=0
    local end_item=$((start_item + UI_MAX_ITEMS - 1))
    [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
    if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then
        start_item=$((end_item - UI_MAX_ITEMS + 1))
        [ "$start_item" -lt 0 ] && start_item=0
    fi
    local scroll_pct=0
    [ "$total_items" -gt 1 ] && scroll_pct=$(( (index * 100) / (total_items - 1) ))

    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$status\nFOOTER:$footer\n"
    UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\nART:NULL\n"
    local items=$(awk -F'|' -v s=$((start_item + 1)) -v e=$((end_item + 1)) -v n=$ITEM_CHARS 'NR >= s && NR <= e { print substr($1, 1, n) }' "$list")
    while IFS= read -r name; do
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
    done <<EOF
$items
EOF
    UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$((index - start_item))\nLISTPOS:$start_item:$list-$total_items\n"
    render_ui
}

# Shows a pop-up window over the current screen and waits for a choice:
#   ask_dialog "Title" "line" "line" -- "Save" "Cancel"
# Sets DIALOG_RESULT to the chosen button (0 = first), or -1 if B was pressed.
# (With the old renderer it shows as a plain list instead.)
ask_dialog() {
    local title="$1" lines="" btns="" items="" nb=0 sel=0 i b
    shift
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        lines="${lines}DIALOG_LINE:$1\n"
        items="${items}ITEM:$1\n"
        shift
    done
    [ "$1" = "--" ] && shift

    nb=$#
    while :; do
        btns=""
        i=0
        for b in "$@"; do
            btns="${btns}DIALOG_BTN:$b\n"
            i=$((i + 1))
        done
        local labels="" mark
        i=0
        for b in "$@"; do
            mark=" "; [ "$i" -eq "$sel" ] && mark=">"
            labels="$labels $mark$b"
            i=$((i + 1))
        done
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$title\n${items}FOOTER:$labels  (A/ choose)\nART:NULL\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}DIALOG:$title\n${lines}${btns}DIALOG_SEL:$sel\n"
        render_ui
        get_key || continue
        case "$KEY" in
            left|up) play_sound "change"; sel=$(( (sel + nb - 1) % nb )) ;;
            right|down) play_sound "change"; sel=$(( (sel + 1) % nb )) ;;
            A) DIALOG_RESULT=$sel; UI_RENDER_NEEDED=1; return ;;
            B) play_sound "back"; DIALOG_RESULT=-1; UI_RENDER_NEEDED=1; return ;;
        esac
    done
}

# Puts a pack's detected folders in a friendly order: consoles first, skipped last.
pack_rows_sort() {
    local d="$CACHE_DIR/pack_detect.txt"
    awk -F'|' '{ print (($2 == "-") ? "1" : "0") "|" $0 }' "$d" | sort -t'|' -k1,1 -k3,3 | cut -d'|' -f2- > "$d.sorted"
    mv -f "$d.sorted" "$d"
}

# Writes the pack screen's lines (pack_detect.disp) from pack_detect.txt.
pack_rows_build() {
    local d="$CACHE_DIR/pack_detect.txt" folder console count note name label
    : > "$CACHE_DIR/pack_detect.disp"
    while IFS='|' read -r folder console count note; do
        name="${folder##*/}"; name="${name%.zip}"
        if [ "$console" = "-" ]; then
            if [ -n "$note" ]; then
                label="Skip: $note (incompatible)"
            else
                label="Skip: $name (not a console)"
            fi
        else
            label="$(get_console_name "$console") - $count games"
        fi
        echo "$label" | tr '|' '/' >> "$CACHE_DIR/pack_detect.disp"
    done < "$d"
}

state_manage_repos() {
    [ -f "$CACHE_DIR/repo_rows.list" ] || refresh_repo_rows
    local total_items=$(wc -l < "$CACHE_DIR/repo_rows.list")
    [ "$REPO_INDEX" -ge "$total_items" ] && REPO_INDEX=$((total_items - 1))

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        awk -F'|' '
            $1 == "+" { print "+ Add a repository"; next }
            {
                c = ($2 == "*") ? "PACK" : $2
                s = $3; sub(/^[a-z]+:\/\//, "", s); sub(/^[^@\/]*@/, "", s); sub(/\/+$/, "", s)
                print sprintf("%-5s %s", c, s)
            }' "$CACHE_DIR/repo_rows.list" > "$CACHE_DIR/repo_rows.disp"

        local row=$(sed -n "$((REPO_INDEX + 1))p" "$CACHE_DIR/repo_rows.list")
        local status="Repositories - also editable in repos.txt"
        local footer="A/ Add  B/ Back"
        if [ "$row" != "+" ]; then
            local c=$(echo "$row" | cut -d'|' -f2) f=$(echo "$row" | cut -d'|' -f4)
            if [ "$c" = "*" ]; then
                local mapped=$(awk -F'|' '$2 != "-"' "$(pack_map_file "$(echo "$row" | cut -d'|' -f3)")" 2>/dev/null | wc -l)
                status="Pack: $mapped folders mapped to consoles"
                footer="A/ Edit  Y/ Remove  Start/ Folders  B/ Back"
            else
                status="$(get_console_name "$c") | Extra format: ${f:-none}"
                footer="A/ Edit  Y/ Remove  X/ Format  Sel/ Console  B/ Back"
            fi
        fi
        draw_simple_list "$CACHE_DIR/repo_rows.disp" "$REPO_INDEX" "$status" "$footer"
    fi

    get_key || return
    local row=$(sed -n "$((REPO_INDEX + 1))p" "$CACHE_DIR/repo_rows.list")
    local n c src fmt
    IFS='|' read -r n c src fmt <<EOF
$row
EOF

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$REPO_INDEX"; REPO_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            if [ "$row" = "+" ]; then
                REPO_EDIT_N=0; REPO_EDIT_CONSOLE=""; REPO_EDIT_FORMAT=""; OSK_BUF=""
            else
                REPO_EDIT_N=$n; REPO_EDIT_CONSOLE=$c; REPO_EDIT_FORMAT=$fmt; OSK_BUF=$src
            fi
            OSK_X=0; OSK_Y=0; OSK_UPPER=0; OSK_LAYER=0
            STATE="REPO_SOURCE_INPUT"
            UI_RENDER_NEEDED=1
            ;;
        Y)
            [ "$row" = "+" ] && return
            play_sound "change"
            REPO_EDIT_N=$n; REPO_EDIT_SOURCE=$src; REPO_EDIT_CONSOLE=$c
            STATE="CONFIRM_REPO_DELETE"
            UI_RENDER_NEEDED=1
            ;;
        X)
            [ "$row" = "+" ] || [ "$c" = "*" ] && return
            play_sound "change"
            # Next format in the list (empty = just the console's usual file types)
            local next=$(echo "$REPO_FORMATS" | tr ' ' '\n' | awk -v cur="$fmt" 'NR == 1 { first = $0 } found { print; done = 1; exit } $0 == cur { found = 1 } END { if (!done) print first }')
            repos_set "$n" "$c" "$src" "$next"
            rm -f "$CACHE_DIR/console_$c.list"
            refresh_repo_rows
            UI_RENDER_NEEDED=1
            ;;
        select)
            [ "$row" = "+" ] || [ "$c" = "*" ] && return
            play_sound "change"
            REPO_EDIT_N=$n; REPO_EDIT_SOURCE=$src; REPO_EDIT_CONSOLE=$c; REPO_EDIT_FORMAT=$fmt
            open_console_picker change
            ;;
        start)
            [ "$c" = "*" ] || return
            play_sound "change"
            REPO_EDIT_N=$n; REPO_EDIT_SOURCE=$src; REPO_EDIT_CONSOLE="*"; REPO_EDIT_FORMAT=$fmt
            STATE="PACK_SCAN"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            rm -f "$CACHE_DIR/repo_rows.list"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_confirm_repo_delete() {
    STATE="MANAGE_REPOS"
    UI_RENDER_NEEDED=1
    ask_dialog "Remove this repo?" "$(source_label "$REPO_EDIT_SOURCE" | cut -c 1-34)" "Games you downloaded stay." -- "Remove" "Cancel"
    if [ "$DIALOG_RESULT" = "0" ]; then
        play_sound "back"
        repos_set "$REPO_EDIT_N" ""
        rm -f "$(pack_map_file "$REPO_EDIT_SOURCE")" "$CACHE_DIR"/console_*.list
        refresh_repo_rows
        toast info "Repo removed"
    else
        play_sound "back"
    fi
}

# archive.org login (Settings): email, then password, then a check with archive.org.
# Only the session cookies are kept (caches/ia_cookies.txt) - never the password.
# Logged in, items that need an account can be added and downloaded.
state_ia_login_input() {
    local is_pass=0
    [ "$STATE" = "IA_LOGIN_PASS" ] && is_pass=1
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local layer_hint="L/ Symbols"
        [ "$OSK_LAYER" = 1 ] && layer_hint="L/ Letters"
        local shown="$OSK_BUF" prompt="archive.org login: your email"
        if [ "$is_pass" -eq 1 ]; then
            shown=$(printf '%s' "$OSK_BUF" | sed 's/./*/g')
            prompt="archive.org password for $IA_EMAIL"
        fi
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$prompt\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Type  B/ Delete  $layer_hint  R/ Caps  Start/ Next  Sel/ Cancel\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}OSK:$OSK_X:$OSK_Y:$shown\nOSK_KEYS:$(osk_keys)\n"
        render_ui
    fi

    get_key || return

    local done=0
    case "$KEY" in
        up|down|left|right|R)
            play_sound "change"
            handle_osk_navigation
            ;;
        L)
            play_sound "change"
            OSK_LAYER=$((1 - OSK_LAYER))
            ;;
        B)
            play_sound "back"
            OSK_BUF="${OSK_BUF%?}"
            ;;
        select)
            play_sound "back"
            OSK_BUF=""
            STATE="SETTINGS"
            ;;
        start|X)
            done=1
            ;;
        A)
            local char=$(osk_char)
            if [ -n "$char" ]; then
                play_sound "change"
                OSK_BUF="${OSK_BUF}${char}"
            elif [ "$OSK_Y" -eq 5 ]; then
                case "$OSK_X" in
                    3)
                        play_sound "change"
                        if [ "$OSK_LAYER" = 1 ]; then OSK_LAYER=0; else OSK_UPPER=$((1 - OSK_UPPER)); fi
                        ;;
                    4) play_sound "back"; OSK_BUF="${OSK_BUF%?}" ;;
                    5) play_sound "back"; OSK_BUF=""; STATE="SETTINGS" ;;
                    6) done=1 ;;
                esac
            fi
            ;;
    esac
    UI_RENDER_NEEDED=1
    [ "$done" -eq 1 ] || return

    if [ -z "$OSK_BUF" ]; then
        play_sound "back"
        return
    fi
    play_sound "confirm"
    if [ "$is_pass" -eq 0 ]; then
        IA_EMAIL=$(echo "$OSK_BUF" | tr -d ' ')
        OSK_BUF=""; OSK_X=0; OSK_Y=0; OSK_LAYER=0; OSK_UPPER=0
        STATE="IA_LOGIN_PASS"
        return
    fi

    local reply="$CACHE_DIR/.login_reply"
    rm -f "$reply"
    run_with_spinner "Logging in to archive.org" ia_login_task "$IA_EMAIL" "$OSK_BUF" "$reply"
    local rc=$?
    local reason=$(cat "$reply" 2>/dev/null)
    rm -f "$reply"
    # The login ran in a background task: pick up the cookies it saved
    ia_refresh_auth
    if [ "$rc" -eq 0 ]; then
        OSK_BUF=""
        IA_EMAIL=""
        rm -f "$CACHE_DIR"/console_*.list
        show_message "Logged in as $IA_USER!" 1.8
        STATE="SETTINGS"
        return
    fi
    [ "$rc" -eq 130 ] && return
    play_sound "back"
    case "$reason" in
        account_not_found) show_message "No archive.org account with that email." 2.5; STATE="IA_LOGIN_EMAIL"; OSK_BUF="$IA_EMAIL" ;;
        account_bad_password) show_message "Wrong password - try again." 2; OSK_BUF="" ;;
        no_connect) show_message "Can't reach archive.org - check Wi-Fi." 2.5 ;;
        *) show_message "Login failed (${reason:-unknown reason})." 2.5 ;;
    esac
}

ia_login_task() {
    ia_login "$1" "$2" > "$3"
}

# archive.org ID suggestions while typing. A short pause in typing asks archive.org's
# search for items whose ID starts with what's typed - only software items with
# archive/disc-image files and ROM-ish words (rom, nintendo, sega, ...) in their
# details, most downloaded first - so it suggests ROM sets, not random uploads.
# Results land in .suggest ("query" line, then IDs) and are reused while the typed
# text still matches, so typing on doesn't need a new search for every letter.
suggest_start() {
    local q="$1" out="$CACHE_DIR/.suggest"
    SUGGEST_ASKED="$q"
    (
        curl -s -k -G --connect-timeout 5 -m 10 "https://archive.org/advancedsearch.php" \
            --data-urlencode "q=identifier:$q* AND mediatype:software AND format:(ZIP OR 7z OR RAR OR \"ISO Image\" OR Unknown) AND (rom OR roms OR romset OR nintendo OR sega OR playstation OR gameboy OR \"game boy\" OR nes OR snes OR gba OR mame OR arcade OR \"no-intro\" OR redump OR emulator OR emulation)" \
            --data-urlencode "fl[]=identifier" --data-urlencode "sort[]=downloads desc" \
            --data-urlencode "rows=12" --data-urlencode "output=json" 2>/dev/null \
            | grep -o '"identifier":"[^"]*"' | cut -d'"' -f4 > "$out.ids"
        { echo "$q"; cat "$out.ids"; } > "$out.new"
        mv -f "$out.new" "$out"
        rm -f "$out.ids"
    ) &
    SUGGEST_PID=$!
}

# Sets SUGGEST to the best known ID that continues the typed text (or empty).
suggest_pick() {
    SUGGEST=""
    [ -s "$CACHE_DIR/.suggest" ] || return
    SUGGEST=$(awk -v b="$OSK_BUF" 'NR == 1 { if (index(tolower(b), tolower($0)) != 1) exit; next }
        length($0) > length(b) && tolower(substr($0, 1, length(b))) == tolower(b) { print; exit }' "$CACHE_DIR/.suggest")
}

# Whether the typed text could be an archive.org ID worth suggesting for
suggest_wanted() {
    [ ${#OSK_BUF} -ge 3 ] || return 1
    case "$OSK_BUF" in *:*|*/*|*" "*|*@*) return 1 ;; esac
    return 0
}

# Typing a repo address: L switches between letters and a symbol layer (. / : @ ...).
state_repo_source_input() {
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local layer_hint="L/ Symbols"
        [ "$OSK_LAYER" = 1 ] && layer_hint="L/ Letters"
        SUGGEST=""
        suggest_wanted && suggest_pick
        build_theme
        if [ -n "$SUGGEST" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Suggested: $SUGGEST\n"
            UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:Start/ Use it  A/ Type  B/ Delete  $layer_hint  X/ Next  Sel/ Cancel\n"
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:archive.org ID, http:// or ftp:// folder\n"
            UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Type  B/ Delete  $layer_hint  R/ Caps  Start/ Next  Sel/ Cancel\n"
        fi
        UI_FRAME_BUF="${UI_FRAME_BUF}OSK:$OSK_X:$OSK_Y:$OSK_BUF\nOSK_HINT:$SUGGEST\nOSK_KEYS:$(osk_keys)\n"
        render_ui
    fi

    # Short waits so suggestions can be looked up during a pause in typing
    if ! get_key 350; then
        if [ -n "$SUGGEST_PID" ] && ! kill -0 "$SUGGEST_PID" 2>/dev/null; then
            # A search finished: show what it found
            SUGGEST_PID=""
            UI_RENDER_NEEDED=1
        elif [ -z "$SUGGEST_PID" ] && suggest_wanted && [ "$OSK_BUF" != "$SUGGEST_ASKED" ]; then
            # Only search again if the last results can't cover the new text
            suggest_pick
            [ -z "$SUGGEST" ] && suggest_start "$OSK_BUF"
        fi
        return
    fi

    case "$KEY" in
        start)
            if [ -n "$SUGGEST" ]; then
                play_sound "confirm"
                OSK_BUF="$SUGGEST"
            else
                repo_source_done
            fi
            UI_RENDER_NEEDED=1
            return
            ;;
    esac

    case "$KEY" in
        up|down|left|right|R)
            play_sound "change"
            handle_osk_navigation
            UI_RENDER_NEEDED=1
            ;;
        L)
            play_sound "change"
            OSK_LAYER=$((1 - OSK_LAYER))
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            OSK_BUF="${OSK_BUF%?}"
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "back"
            STATE="MANAGE_REPOS"
            UI_RENDER_NEEDED=1
            ;;
        X)
            repo_source_done
            UI_RENDER_NEEDED=1
            ;;
        A)
            local char=$(osk_char)
            if [ -n "$char" ]; then
                play_sound "change"
                OSK_BUF="${OSK_BUF}${char}"
            elif [ "$OSK_Y" -eq 5 ]; then
                case "$OSK_X" in
                    3)
                        play_sound "change"
                        if [ "$OSK_LAYER" = 1 ]; then OSK_LAYER=0; else OSK_UPPER=$((1 - OSK_UPPER)); fi
                        ;;
                    4) play_sound "back"; OSK_BUF="${OSK_BUF%?}" ;;
                    5) play_sound "back"; STATE="MANAGE_REPOS" ;;
                    6) repo_source_done ;;
                esac
            fi
            UI_RENDER_NEEDED=1
            ;;
    esac
}

repo_source_done() {
    # Spaces sneak in easily on the keyboard and never belong in an address
    OSK_BUF=$(echo "$OSK_BUF" | tr -d ' ')
    if [ -z "$OSK_BUF" ]; then
        play_sound "back"
        show_message "Type an archive.org ID or a folder address first." 1.5
        return
    fi
    play_sound "confirm"
    REPO_EDIT_SOURCE="$OSK_BUF"
    if [ "$REPO_EDIT_N" -eq 0 ]; then
        open_console_picker new
    else
        STATE="CHECK_REPO"
    fi
}

# Console picker. Modes: "new" (new repo: pack or a console), "change" (move a repo
# to another console), "packrow" (choose the console for one folder of a pack).
open_console_picker() {
    CONSOLE_PICK_MODE="$1"
    {
        [ "$1" = "new" ] && echo "*|Multi-console pack (auto-detect)"
        [ "$1" = "packrow" ] && echo "-|Skip this folder"
        for dir in "$ROMS_DIR"/*; do
            [ -d "$dir" ] || continue
            local f="${dir##*/}"
            echo "$f|$f - $(get_console_name "$f")"
        done
    } > "$CACHE_DIR/console_choices.list"
    CONSOLE_PICK_INDEX=0
    STATE="REPO_PICK_CONSOLE"
    UI_RENDER_NEEDED=1
}

state_repo_pick_console() {
    local total_items=$(wc -l < "$CACHE_DIR/console_choices.list")
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        cut -d'|' -f2 "$CACHE_DIR/console_choices.list" > "$CACHE_DIR/console_choices.disp"
        local status="Which console is this repo for?"
        [ "$CONSOLE_PICK_MODE" = "packrow" ] && status="Console for folder: $(echo "${PACK_ROW_FOLDER##*/}" | cut -c 1-22)"
        draw_simple_list "$CACHE_DIR/console_choices.disp" "$CONSOLE_PICK_INDEX" "$status" "A/ Choose   B/ Back"
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$CONSOLE_PICK_INDEX"; CONSOLE_PICK_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local pick=$(sed -n "$((CONSOLE_PICK_INDEX + 1))p" "$CACHE_DIR/console_choices.list" | cut -d'|' -f1)
            case "$CONSOLE_PICK_MODE" in
                new)
                    REPO_EDIT_CONSOLE="$pick"
                    STATE="CHECK_REPO"
                    ;;
                change)
                    repos_set "$REPO_EDIT_N" "$pick" "$REPO_EDIT_SOURCE" "$REPO_EDIT_FORMAT"
                    rm -f "$CACHE_DIR"/console_*.list
                    refresh_repo_rows
                    STATE="MANAGE_REPOS"
                    ;;
                packrow)
                    awk -F'|' -v f="$PACK_ROW_FOLDER" -v c="$pick" 'BEGIN { OFS = "|" } $1 == f { $2 = c } { print }' \
                        "$CACHE_DIR/pack_detect.txt" > "$CACHE_DIR/pack_detect.tmp"
                    mv "$CACHE_DIR/pack_detect.tmp" "$CACHE_DIR/pack_detect.txt"
                    STATE="PACK_CONFIRM"
                    ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            case "$CONSOLE_PICK_MODE" in
                new) STATE="REPO_SOURCE_INPUT" ;;
                packrow) STATE="PACK_CONFIRM" ;;
                *) STATE="MANAGE_REPOS" ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# archive.org checks that only the metadata API can answer: the ID's real spelling
# (IDs are case-sensitive), and whether the item is private, a collection or taken
# down. Sets ARCHIVE_ID on success; writes a status word to $2 on failure.
check_archive_item() {
    local id="$1" status="$2" meta rc
    meta=$(curl $IA_AUTH -s -L -k --connect-timeout 10 -m 20 "https://archive.org/metadata/$id/metadata")
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$meta" ]; then
        curl_status "$rc" 000 archive > "$status"
        [ -s "$status" ] || echo "no_connect" > "$status"
        return 1
    fi
    if echo "$meta" | grep -q "Couldn't locate item"; then
        id=$(curl -s -L -k --connect-timeout 10 -m 20 -G \
            --data-urlencode "q=identifier:$1" --data-urlencode "fl[]=identifier" \
            --data-urlencode "rows=1" --data-urlencode "output=json" \
            "https://archive.org/advancedsearch.php" | grep -o '"identifier":"[^"]*"' | head -n1 | cut -d'"' -f4)
        [ -z "$id" ] && { echo "not_found" > "$status"; return 1; }
        meta=$(curl $IA_AUTH -s -L -k --connect-timeout 10 -m 20 "https://archive.org/metadata/$id/metadata")
    fi
    if echo "$meta" | grep -q "Couldn't get 'metadata'"; then
        echo "dark" > "$status"; return 1
    fi
    # Private items can still work for a logged-in account (Settings), so only stop
    # here when not logged in
    if [ -z "$IA_AUTH" ] && echo "$meta" | grep -q '"access-restricted-item":"true"'; then
        echo "restricted" > "$status"; return 1
    fi
    if echo "$meta" | grep -q '"mediatype":"collection"'; then
        echo "collection" > "$status"; return 1
    fi
    ARCHIVE_ID="$id"
    echo "$id" > "$CACHE_DIR/.archive_id"
    return 0
}

# Downloads the repo's file list and checks it has games for its console (or, for a
# pack, finds its console folders). Bad repos get a message saying what's wrong and
# go back to the keyboard with the address still typed in.
check_repo_task() {
    local src="$1" status="$2"
    if [ "$(source_type "$src")" = "archive" ]; then
        check_archive_item "$src" "$status" || return 1
        src=$(cat "$CACHE_DIR/.archive_id")
    fi
    ensure_source_index "$src" "$status" 1 || return 1
    # For a single console, list its games the same way the game list will (this also
    # opens console zips), so the count shown is the real one
    rm -f "$CACHE_DIR/.check_games"
    if [ "$REPO_EDIT_CONSOLE" != "*" ]; then
        source_games "$REPO_EDIT_CONSOLE" "$src" "$REPO_EDIT_FORMAT" "" > "$CACHE_DIR/.check_games"
    fi
    return 0
}

state_check_repo() {
    local status="$CACHE_DIR/.check_status"
    rm -f "$status" "$CACHE_DIR/.archive_id"
    run_with_spinner "Checking repo" check_repo_task "$REPO_EDIT_SOURCE" "$status"
    local rc=$?
    STATE="REPO_SOURCE_INPUT"
    UI_RENDER_NEEDED=1
    if [ "$rc" -eq 130 ]; then
        play_sound "back"
        show_message "Check cancelled - repo not saved." 1.5
        return
    fi
    if [ "$rc" -ne 0 ]; then
        play_sound "back"
        show_message "$(source_status_message "$status")" 3
        return
    fi
    # archive.org may have corrected the ID's spelling
    [ -s "$CACHE_DIR/.archive_id" ] && REPO_EDIT_SOURCE=$(cat "$CACHE_DIR/.archive_id")
    local idx=$(source_index_file "$REPO_EDIT_SOURCE")

    if [ "$REPO_EDIT_CONSOLE" = "*" ]; then
        detect_pack_consoles "$idx" > "$CACHE_DIR/pack_detect.txt"
        pack_rows_sort
        if [ ! -s "$CACHE_DIR/pack_detect.txt" ]; then
            play_sound "back"
            show_message "No console folders in that repo. Pick one console?" 3
            return
        fi
        PACK_INDEX=0
        STATE="PACK_CONFIRM"; PACK_POPUP=1
        return
    fi

    local count=$(wc -l < "$CACHE_DIR/.check_games" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        local found=$(cut -d'|' -f1 "$idx" | grep '\.' | sed 's/.*\.//' | tr 'A-Z' 'a-z' \
            | sort | uniq -c | sort -rn | head -n 4 | awk '{ printf "%s.%s", (NR > 1 ? " " : ""), $2 }')
        echo "no_matches|$found" > "$status"
        play_sound "back"
        show_message "$(source_status_message "$status")" 3
        return
    fi

    # Ask before saving; a repo holding several consoles can be added whole instead
    local others=$(awk -F'|' -v c="$REPO_EDIT_CONSOLE" '$2 != "-" && $2 != c { print $2 }' "$(repo_folder_map "$idx")" | sort -u | wc -l)
    # The games found, shown behind the pop-up
    sort -f -t'|' -k1,1 "$CACHE_DIR/.check_games" | cut -d'|' -f1 > "$CACHE_DIR/.check_titles"
    draw_simple_list "$CACHE_DIR/.check_titles" 0 "$count $(get_console_name "$REPO_EDIT_CONSOLE") games found" "A/ Choose"
    play_sound "confirm"
    if [ "$others" -gt 0 ] && [ "$REPO_EDIT_N" -eq 0 ]; then
        ask_dialog "Repo found!" "$(source_label "$REPO_EDIT_SOURCE" | cut -c 1-34)" \
            "$count $(get_console_name "$REPO_EDIT_CONSOLE") games" "(it has $others more consoles too)" -- "Save" "Edit" "Add all" "Cancel"
    else
        ask_dialog "Repo found!" "$(source_label "$REPO_EDIT_SOURCE" | cut -c 1-34)" \
            "$count $(get_console_name "$REPO_EDIT_CONSOLE") games" -- "Save" "Edit" "Cancel"
        [ "$DIALOG_RESULT" = "2" ] && DIALOG_RESULT=3
    fi
    rm -f "$CACHE_DIR/.check_titles"
    case "$DIALOG_RESULT" in
        0) ;;
        1)
            # Back to the address (still typed in) to change it
            OSK_BUF="$REPO_EDIT_SOURCE"
            STATE="REPO_SOURCE_INPUT"
            UI_RENDER_NEEDED=1
            return
            ;;
        2)
            # Whole pack: review its consoles like a pack added from the start
            REPO_EDIT_CONSOLE="*"
            detect_pack_consoles "$idx" > "$CACHE_DIR/pack_detect.txt"
            pack_rows_sort
            PACK_INDEX=0
            STATE="PACK_CONFIRM"; PACK_POPUP=1
            UI_RENDER_NEEDED=1
            return
            ;;
        *)
            STATE="MANAGE_REPOS"
            UI_RENDER_NEEDED=1
            return
            ;;
    esac

    if [ "$REPO_EDIT_N" -eq 0 ]; then
        repos_add "$REPO_EDIT_CONSOLE" "$REPO_EDIT_SOURCE" "$REPO_EDIT_FORMAT"
    else
        repos_set "$REPO_EDIT_N" "$REPO_EDIT_CONSOLE" "$REPO_EDIT_SOURCE" "$REPO_EDIT_FORMAT"
    fi
    rm -f "$CACHE_DIR/console_$REPO_EDIT_CONSOLE.list"
    refresh_repo_rows
    play_sound "confirm"
    show_message "Repo saved! $count games for $(get_console_name "$REPO_EDIT_CONSOLE")." 1.8
    STATE="MANAGE_REPOS"
}

# Re-scans an existing pack's folders, keeping the console choices made before.
state_pack_scan() {
    local status="$CACHE_DIR/.check_status"
    run_with_spinner "Reading pack" ensure_source_index "$REPO_EDIT_SOURCE" "$status" 0
    local rc=$?
    UI_RENDER_NEEDED=1
    if [ "$rc" -ne 0 ]; then
        STATE="MANAGE_REPOS"
        [ "$rc" -eq 130 ] && return
        play_sound "back"
        show_message "$(source_status_message "$status")" 3
        return
    fi
    local map=$(pack_map_file "$REPO_EDIT_SOURCE")
    detect_pack_consoles "$(source_index_file "$REPO_EDIT_SOURCE")" > "$CACHE_DIR/pack_detect.txt"
    if [ -f "$map" ]; then
        awk -F'|' -v OFS='|' 'NR == FNR { old[$1] = $2; next } ($1 in old) { $2 = old[$1] } { print }' \
            "$map" "$CACHE_DIR/pack_detect.txt" > "$CACHE_DIR/pack_detect.tmp"
        mv "$CACHE_DIR/pack_detect.tmp" "$CACHE_DIR/pack_detect.txt"
    fi
    pack_rows_sort
    PACK_INDEX=0
    STATE="PACK_CONFIRM"
}

# Saves the pack as reviewed on the pack screen.
pack_save() {
    play_sound "confirm"
    cp "$CACHE_DIR/pack_detect.txt" "$(pack_map_file "$REPO_EDIT_SOURCE")"
    if [ "$REPO_EDIT_N" -eq 0 ]; then
        repos_add "*" "$REPO_EDIT_SOURCE"
    else
        repos_set "$REPO_EDIT_N" "*" "$REPO_EDIT_SOURCE" "$REPO_EDIT_FORMAT"
    fi
    rm -f "$CACHE_DIR"/console_*.list
    refresh_repo_rows
    local consoles=$(awk -F'|' '$2 != "-" { print $2 }' "$CACHE_DIR/pack_detect.txt" | sort -u | wc -l)
    show_message "Pack saved! Games for $consoles consoles." 1.8
    STATE="MANAGE_REPOS"
    UI_RENDER_NEEDED=1
}

# Summary lines for the pack pop-ups
pack_summary() {
    PACK_N_CONSOLES=$(awk -F'|' '$2 != "-" { print $2 }' "$CACHE_DIR/pack_detect.txt" | sort -u | wc -l)
    PACK_N_GAMES=$(awk -F'|' '$2 != "-" { n += $3 } END { print n + 0 }' "$CACHE_DIR/pack_detect.txt")
    PACK_N_SKIP=$(awk -F'|' '$2 == "-"' "$CACHE_DIR/pack_detect.txt" | wc -l)
}

# Shows which console each folder of a pack was matched to; A changes one, Start saves.
# A newly found pack opens with a pop-up over the list: Save straight away, Edit (the
# pop-up goes and the list can be changed), or Cancel.
state_pack_confirm() {
    local total_items=$(wc -l < "$CACHE_DIR/pack_detect.txt")
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        pack_rows_build
        local consoles=$(awk -F'|' '$2 != "-" { print $2 }' "$CACHE_DIR/pack_detect.txt" | sort -u | wc -l)
        draw_simple_list "$CACHE_DIR/pack_detect.disp" "$PACK_INDEX" "Found $consoles consoles - A on a row to change it" "A/ Change  Start/ Save  B/ Cancel"
    fi

    if [ "$PACK_POPUP" = "1" ]; then
        PACK_POPUP=0
        pack_summary
        play_sound "confirm"
        local skip_line="$PACK_N_SKIP folders skipped"
        [ "$PACK_N_SKIP" -eq 0 ] && skip_line="Nothing skipped"
        ask_dialog "Repo found!" "$(source_label "$REPO_EDIT_SOURCE" | cut -c 1-34)" \
            "$PACK_N_CONSOLES consoles, about $PACK_N_GAMES games" "$skip_line" -- "Save" "Edit" "Cancel"
        case "$DIALOG_RESULT" in
            0) pack_save ;;
            1) UI_RENDER_NEEDED=1 ;;
            *) play_sound "back"; STATE="MANAGE_REPOS"; UI_RENDER_NEEDED=1 ;;
        esac
        return
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$PACK_INDEX"; PACK_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            PACK_ROW_FOLDER=$(sed -n "$((PACK_INDEX + 1))p" "$CACHE_DIR/pack_detect.txt" | cut -d'|' -f1)
            open_console_picker packrow
            ;;
        start)
            if ! awk -F'|' '$2 != "-" { found = 1 } END { exit !found }' "$CACHE_DIR/pack_detect.txt"; then
                play_sound "back"
                show_message "Pick a console for at least one folder." 1.5
                UI_RENDER_NEEDED=1
                return
            fi
            play_sound "change"
            pack_summary
            ask_dialog "Save this pack?" "$(source_label "$REPO_EDIT_SOURCE" | cut -c 1-34)" \
                "$PACK_N_CONSOLES consoles, about $PACK_N_GAMES games" "$PACK_N_SKIP folders skipped" -- "Save" "Back"
            [ "$DIALOG_RESULT" = "0" ] && pack_save
            ;;
        B)
            play_sound "back"
            ask_dialog "Leave without saving?" "The pack won't be added." -- "Leave" "Stay"
            [ "$DIALOG_RESULT" = "0" ] && STATE="MANAGE_REPOS"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

# A "please wait" screen: rmui's spinner in the middle, $1 under it and on the status
# line, $2 the button hints
busy_frame() {
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$1\nFOOTER:${2:-}\nBUSY:$1\nART:NULL\n"
    render_ui
}

# Runs a command in the background while showing a spinner; B cancels it.
# Returns the command's exit code, or 130 if the player cancelled.
run_with_spinner() {
    local msg="$1"
    shift
    rm -f /tmp/task_active /tmp/task_cancel /tmp/task_rc
    touch /tmp/task_active
    (
        "$@"
        echo $? > /tmp/task_rc
        rm -f /tmp/task_active
    ) &
    local task_pid=$!
    start_cancel_listener /tmp/task_cancel

    # rmui spins the spinner by itself: one frame, then just wait. (The old renderer
    # gets a text spinner, redrawn.)
    local spin_idx=0 spin_char="|"
    busy_frame "$msg" "B/ Cancel"
    while [ -f /tmp/task_active ]; do
        if [ -f /tmp/task_cancel ]; then
            kill_tree $task_pid
            stop_cancel_listener
            rm -f /tmp/task_active /tmp/task_cancel /tmp/task_rc
            return 130
        fi
        if [ -z "$RMUI_PID" ]; then
            spin_idx=$(( (spin_idx + 1) % 4 ))
            case $spin_idx in 0) spin_char="|";; 1) spin_char="/";; 2) spin_char="-";; 3) spin_char="\\";; esac
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$msg [$spin_char]\nFOOTER:B/ Cancel\nART:NULL\n"
            render_ui
        fi
        sleep 0.15
    done

    stop_cancel_listener
    local rc=$(cat /tmp/task_rc 2>/dev/null)
    rm -f /tmp/task_rc /tmp/task_cancel
    return ${rc:-1}
}

state_scrape_art() {
    busy_frame "Looking for games without box art..."

    > "$CACHE_DIR/missing_art.txt"
    update_local_consoles

    for folder in $(cat "$CACHE_DIR/local_consoles.cache" | cut -d'|' -f1); do
        local libretro_sys=$(get_libretro_system "$folder")
        [ -z "$libretro_sys" ] && continue
        
        local target_dir="/mnt/SDCARD/Roms/$folder"
        local ignore="$ROM_IGNORE"
        
        ls -1p "$target_dir" 2>/dev/null | grep -ivE "$ignore" | while read -r rom_path; do
            local file_name="${rom_path##*/}"
            local base_name="${file_name%.*}"
            
            if [ ! -s "$target_dir/Imgs/${base_name}.png" ]; then
                echo "$folder|${base_name}|${libretro_sys}" >> "$CACHE_DIR/missing_art.txt"
            fi
        done
    done

    local total_missing=$(wc -l < "$CACHE_DIR/missing_art.txt")
    
    if [ "$total_missing" -eq 0 ]; then
        toast ok "Every game already has box art"
        STATE="SETTINGS"
    else
        STATE="CONFIRM_SCRAPE"
        MISSING_INDEX=0
    fi
    UI_RENDER_NEEDED=1
}

state_confirm_scrape() {
    local total_items=$(wc -l < "$CACHE_DIR/missing_art.txt")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((MISSING_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((MISSING_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (MISSING_INDEX * 100) / (total_items - 1) ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$(plural "$total_items" game) without box art  ·  $human_pos/$total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Get box art for all  B/ Cancel\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$2, 1, $ITEM_CHARS) }" "$CACHE_DIR/missing_art.txt")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((MISSING_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\nLISTPOS:$start_item:$STATE-$DL_CHOSEN_FOLDER$INST_CHOSEN_FOLDER-$total_items\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$MISSING_INDEX"; MISSING_INDEX=$SEL
            UI_RENDER_NEEDED=1
            ;;
        A)
            need_wifi || { UI_RENDER_NEEDED=1; return; }
            play_sound "change"
            STATE="DO_SCRAPE"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="SETTINGS"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_do_scrape() {
    local total_missing=$(wc -l < "$CACHE_DIR/missing_art.txt")
    local current_missing=0
    > "$CACHE_DIR/scraped_history.txt"

    local pids=""

    while read -r line; do
        current_missing=$((current_missing + 1))
        local folder=$(echo "$line" | cut -d'|' -f1)
        local base_name=$(echo "$line" | cut -d'|' -f2)
        local libretro_sys=$(echo "$line" | cut -d'|' -f3)
        
        push_history "$CACHE_DIR/scraped_history.txt" "$base_name"
        local pct=$(( (current_missing * 100) / total_missing ))
        
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scraping $current_missing of $total_missing\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:-1\nPROGRESS:$pct\nART:NULL\n"
        
        local history=$(awk -v s=1 -v e=8 'NR>=s && NR<=e { print substr($0, 1, 28) }' "$CACHE_DIR/scraped_history.txt")
        while read -r sc_line; do
            [ -n "$sc_line" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${sc_line}\n"
        done <<EOF
$history
EOF
        render_ui
        
        mkdir -p "/mnt/SDCARD/Roms/$folder/Imgs"
        
        fetch_libretro_art "$libretro_sys" "$base_name" "/mnt/SDCARD/Roms/$folder/Imgs/${base_name}.png" &
        pids="$pids $!"
        
        while true; do
            local running_jobs=0
            local active_pids=""
            for p in $pids; do
                if kill -0 $p 2>/dev/null; then
                    running_jobs=$((running_jobs + 1))
                    active_pids="$active_pids $p"
                fi
            done
            pids="$active_pids"
            
            if [ "$running_jobs" -ge 4 ]; then
                sleep 0.1
            else
                break
            fi
        done

    done < "$CACHE_DIR/missing_art.txt"
    
    for p in $pids; do wait $p 2>/dev/null; done

    play_sound "confirm"
    toast ok "Box art scrape finished"
    STATE="SETTINGS"
    UI_RENDER_NEEDED=1
}

state_prefetch_covers_scan() {
    consoles_with_repos > "$CACHE_DIR/.prefetch_consoles"
    local total_repos=$(wc -l < "$CACHE_DIR/.prefetch_consoles")
    [ "$total_repos" -le 0 ] && total_repos=1

    mkdir -p "$CACHE_DIR/previews"
    > "$CACHE_DIR/prefetch_covers.txt"

    rm -f /tmp/scan_active /tmp/scan_cancel
    touch /tmp/scan_active
    echo "0|Starting..." > "$CACHE_DIR/scan_progress.txt"

    # Runs the actual filesystem/network work in the background so the UI can keep
    # redrawing (progress + cancel) instead of freezing for the whole scan. Per-repo
    # queue lines are buffered in memory and flushed with a single append, instead of
    # opening the output file once per game - on SD card storage, thousands of tiny
    # writes (one per title) were the main reason this used to look like a hang.
    (
        local repo_num=0
        while IFS='|' read -r sys_fld repo_count; do
            [ -f /tmp/scan_cancel ] && break
            local sys_name=$(get_console_name "$sys_fld")

            local libretro_sys=$(get_libretro_system "$sys_fld")
            [ -z "$libretro_sys" ] && continue

            repo_num=$((repo_num + 1))
            echo "${repo_num}|${sys_name}" > "$CACHE_DIR/scan_progress.txt"

            local list_file="$CACHE_DIR/console_$sys_fld.list"
            build_console_games "$sys_fld" "$list_file" "$CACHE_DIR/.scan_status" 0
            [ -s "$list_file" ] || continue

            local target_dir="/mnt/SDCARD/Roms/${sys_fld}"
            local queue=""

            while IFS='|' read -r title raw_name mb bytes; do
                [ -z "$title" ] && continue
                [ -s "$CACHE_DIR/previews/${title}.png" ] && continue
                [ -f "$CACHE_DIR/previews/${title}.png.none" ] && continue

                if [ -s "${target_dir}/Imgs/${title}.png" ]; then
                    # Already downloaded and has its own cover on the SD card - reuse it
                    # instead of fetching it again from the network.
                    cp "${target_dir}/Imgs/${title}.png" "$CACHE_DIR/previews/${title}.png" 2>/dev/null
                    continue
                fi

                queue="${queue}${title}|${libretro_sys}
"
            done < "$list_file"

            [ -n "$queue" ] && printf '%s' "$queue" >> "$CACHE_DIR/prefetch_covers.txt"
        done < "$CACHE_DIR/.prefetch_consoles"

        rm -f /tmp/scan_active
    ) &
    local worker_pid=$!

    start_cancel_listener /tmp/scan_cancel

    while [ -f /tmp/scan_active ]; do
        if [ -f /tmp/scan_cancel ]; then
            # Stop immediately rather than waiting for the current repo's list to finish.
            kill_tree $worker_pid
            break
        fi
        local progress=$(cat "$CACHE_DIR/scan_progress.txt" 2>/dev/null)
        local repo_num=$(echo "$progress" | cut -d'|' -f1)
        local repo_name=$(echo "$progress" | cut -d'|' -f2 | cut -c 1-24)
        [ -z "$repo_num" ] && repo_num=0

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scanning [$repo_num/$total_repos]: ${repo_name}\nART:NULL\nFOOTER:B/ Cancel\n"
        render_ui
        sleep 0.2
    done

    stop_cancel_listener
    local was_cancelled=0
    [ -f /tmp/scan_cancel ] && was_cancelled=1
    rm -f /tmp/scan_active /tmp/scan_cancel

    if [ "$was_cancelled" -eq 1 ]; then
        play_sound "back"
        toast info "Scan cancelled"
        STATE="SETTINGS"
    elif [ -s "$CACHE_DIR/prefetch_covers.txt" ]; then
        sort -u "$CACHE_DIR/prefetch_covers.txt" -o "$CACHE_DIR/prefetch_covers.txt"
        STATE="CONFIRM_PREFETCH_COVERS"
    else
        toast ok "Every preview is already saved"
        STATE="SETTINGS"
    fi
    UI_RENDER_NEEDED=1
}

state_confirm_prefetch_covers() {
    local total_items=$(wc -l < "$CACHE_DIR/prefetch_covers.txt")
    [ "$total_items" -le 0 ] && total_items=1
    UI_RENDER_NEEDED=1
    # previews are stored small, about 20KB each
    ask_dialog "Download previews?" "$(plural "$total_items" cover) for games you don't have" "About $(format_size $((total_items * 20480))) on the SD card." -- "Download" "Cancel"
    if [ "$DIALOG_RESULT" = "0" ] && need_wifi; then
        play_sound "change"
        STATE="DO_PREFETCH_COVERS"
    else
        play_sound "back"
        STATE="SETTINGS"
    fi
}

state_do_prefetch_covers() {
    local total_items=$(wc -l < "$CACHE_DIR/prefetch_covers.txt")
    [ "$total_items" -le 0 ] && total_items=1
    mkdir -p "$CACHE_DIR/previews"

    rm -f /tmp/prefetch_active /tmp/prefetch_cancel
    touch /tmp/prefetch_active
    > "$CACHE_DIR/prefetch_history.txt"
    echo 0 > "$CACHE_DIR/prefetch_progress.txt"

    (
        local current_item=0
        local pids=""
        while read -r line; do
            [ -f /tmp/prefetch_cancel ] && break
            current_item=$((current_item + 1))
            local base_name=$(echo "$line" | cut -d'|' -f1)
            local libretro_sys=$(echo "$line" | cut -d'|' -f2)

            push_history "$CACHE_DIR/prefetch_history.txt" "$base_name"
            echo "$current_item" > "$CACHE_DIR/prefetch_progress.txt"

            fetch_libretro_art_preview "$libretro_sys" "$base_name" "$CACHE_DIR/previews/${base_name}.png" &
            pids="$pids $!"

            while true; do
                local running_jobs=0
                local active_pids=""
                for p in $pids; do
                    if kill -0 $p 2>/dev/null; then
                        running_jobs=$((running_jobs + 1))
                        active_pids="$active_pids $p"
                    fi
                done
                pids="$active_pids"

                if [ "$running_jobs" -ge 4 ]; then
                    sleep 0.1
                else
                    break
                fi
            done
        done < "$CACHE_DIR/prefetch_covers.txt"

        for p in $pids; do wait $p 2>/dev/null; done
        rm -f /tmp/prefetch_active
    ) &
    local worker_pid=$!

    start_cancel_listener /tmp/prefetch_cancel
    local was_cancelled=0

    while [ -f /tmp/prefetch_active ]; do
        local current_item=$(cat "$CACHE_DIR/prefetch_progress.txt" 2>/dev/null)
        [ -z "$current_item" ] && current_item=0
        local pct=$(( (current_item * 100) / total_items ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Fetching Previews $current_item of $total_items\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:-1\nPROGRESS:$pct\nART:NULL\nFOOTER:B/ Cancel\n"

        local history=$(awk -v s=1 -v e=8 'NR>=s && NR<=e { print substr($0, 1, 28) }' "$CACHE_DIR/prefetch_history.txt" 2>/dev/null)
        while read -r hist_line; do
            [ -n "$hist_line" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${hist_line}\n"
        done <<EOF
$history
EOF
        render_ui

        if [ -f /tmp/prefetch_cancel ]; then
            play_sound "back"
            kill_tree $worker_pid
            was_cancelled=1
            break
        fi

        sleep 0.2
    done

    stop_cancel_listener
    rm -f /tmp/prefetch_active /tmp/prefetch_cancel

    if [ "$was_cancelled" -eq 1 ]; then
        toast info "Preview download cancelled"
    else
        play_sound "confirm"
        toast ok "Previews downloaded"
    fi

    STATE="SETTINGS"
    UI_RENDER_NEEDED=1
}

# ==========================================
# 7. BOOT SEQUENCE
# ==========================================

# Repo handling lives in lib/sources.sh; first launch converts the old archives.txt
. ./lib/sources.sh
# Updates from GitHub
. ./lib/update.sh
theme_settings

# The boot screen: logo, a loading bar that follows the real steps, what was found,
# and a tip. The renderer starts first so it's up straight away.
STATE="BOOT"
BOOT_INFO1=""
BOOT_INFO2=""
set -- "Tip: press R in a game list to browse cover art" \
    "Tip: press Select in a game list to search it" \
    "Tip: press Start on a game to add it to your favorites" \
    "Tip: L2 / R2 jump to the next letter in long lists" \
    "Tip: press Y in a download list to sort and filter it" \
    "Tip: downloads keep going while you browse" \
    "Tip: one repo can hold games for many consoles - add it as a pack" \
    "Tip: log in to archive.org in Settings for members-only items"
shift $(( ${RANDOM:-0} % $# ))
BOOT_TIP=$1
set --

boot_frame() {
    [ "$RETURNING" = "1" ] && return
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}BOOT:v$RM_VERSION\nBOOT_STEP:$1\nBOOT_PROGRESS:$2\nBOOT_TIP:$BOOT_TIP\n"
    UI_FRAME_BUF="${UI_FRAME_BUF}BOOT_CREDIT:by plusCloud\n"
    UI_FRAME_BUF="${UI_FRAME_BUF}BOOT_THANKS:with help from brenonsc  ·  icons by Bernig\n"
    [ -n "$BOOT_INFO1" ] && UI_FRAME_BUF="${UI_FRAME_BUF}BOOT_INFO:$BOOT_INFO1\n"
    [ -n "$BOOT_INFO2" ] && UI_FRAME_BUF="${UI_FRAME_BUF}BOOT_INFO:$BOOT_INFO2\n"
    render_ui
}

# Back from a game started here (the after-game hook leaves /tmp/rm_return): no boot
# screen - straight back to the screen you left, sound starting just after it shows
RETURNING=0
if [ -f /tmp/rm_return ]; then
    RETURNING=1
    rm -f /tmp/rm_return
fi

start_renderer
start_input
boot_frame "Starting up..." 5

# An update downloaded in the background last time: install it and start the new
# version (not when coming back from a game - that waits for the next start)
if [ "$RETURNING" != "1" ] && [ -s "$UPDATE_DIR/ready" ]; then
    boot_frame "Installing update..." 10
    if update_apply_staged; then
        boot_frame "Updated - restarting..." 100
        sleep 0.5
        stop_renderer
        stop_input
        exit "$UPDATE_RESTART_CODE"
    fi
fi

migrate_archives
migrate_console_codes
# Listing pages and covers left behind if the app was closed mid-task. Partial
# downloads still in the download queue are kept, so they can carry on.
rm -f "$CACHE_DIR"/.tmp_repo_* "$CACHE_DIR"/.view_art_* 2>/dev/null
clean_partial_downloads

boot_frame "Starting sound..." 20
if [ "$RETURNING" = "1" ]; then
    AUDIO_DEFERRED=1 # (render_ui starts it after the first screen)
else
    init_audio
    start_bgm
fi

boot_frame "Counting your games..." 45
shrink_old_previews
# (a game can't have changed the ROM folders: the counts made before it still hold)
[ "$RETURNING" = "1" ] || rm -f "$CACHE_DIR/local_consoles.cache"
update_local_consoles
refresh_home_counts
BOOT_INFO1="$HOME_GAMES games on $HOME_CONSOLES consoles"
[ "$HOME_CONSOLES" = "1" ] && BOOT_INFO1="$HOME_GAMES games on 1 console"

boot_frame "Checking Wi-Fi and repos..." 75
update_statusbar
wifi_txt="Wi-Fi off"
wifi_on && wifi_txt="Wi-Fi on"
free_txt=$(free_space_kb /mnt/SDCARD)
case "$free_txt" in ''|*[!0-9]*) free_txt="" ;; *) free_txt="  ·  $(format_size $((free_txt * 1024))) free" ;; esac
BOOT_INFO2="$HOME_REPOS repos  ·  $wifi_txt$free_txt"
[ "$HOME_REPOS" = "1" ] && BOOT_INFO2="1 repo  ·  $wifi_txt$free_txt"
# (in the background - a new version is downloaded and installed at the next start)
update_auto_check

boot_frame "Ready!" 100
# (long enough to see the bar fill up)
[ "$RETURNING" = "1" ] || sleep 0.35

STATE="MAIN_MENU"
# Settings > Open To: straight to the installed games, or back where you left off.
# Back from a game: always where you were.
if [ "$START_SCREEN" = "installed" ] && [ "$RETURNING" != "1" ]; then
    MAIN_INDEX=1
    STATE="INST_CONSOLES"
fi
resume_spot "$RETURNING"

# First time: a word about where games should come from
if [ "$DISCLAIMER_SEEN" != "1" ]; then
    ask_dialog "Before you start" "RomManager doesn't come with any games:" "it downloads from the sources you add." \
        "Only download games you own, and" "respect the copyright laws where you live." -- "I understand"
    DISCLAIMER_SEEN=1
    save_settings
fi

# Downloads that didn't finish last time
offer_resume_downloads

# Just restarted after an update
if [ -s "$CACHE_DIR/.just_updated" ]; then
    toast ok "Updated to RomManager $RM_VERSION"
    rm -f "$CACHE_DIR/.just_updated"
fi

UI_RENDER_NEEDED=1

# ==========================================
# 8. MAIN DISPATCH LOOP
# ==========================================
while true
do
    # For the crash log: which screen the app was on
    [ "$STATE" != "$LOGGED_STATE" ] && { echo "$STATE" > /tmp/rm_state; LOGGED_STATE=$STATE; }
    # (no renderer running: the deferred sound start happens here instead)
    if [ "$AUDIO_DEFERRED" = "1" ] && [ -z "$RMUI_PID" ]; then
        AUDIO_DEFERRED=0
        init_audio
        start_bgm
    fi
    # Background downloads that finished: refresh lists (cheap check when nothing did)
    [ -f "$CACHE_DIR/.dl_event" ] && dl_events
    case "$STATE" in
        MAIN_MENU) state_main_menu ;;
        DOWNLOADS) state_downloads ;;
        DL_FILTER) state_dl_filter ;;
        DL_CONSOLES) state_dl_consoles ;;
        FETCH_XML) state_fetch_xml ;;
        DL_GAMES) state_dl_games ;;
        CONFIRM_DOWNLOAD) state_confirm_download ;;
        INST_CONSOLES) state_inst_consoles ;;
        INST_GAMES) state_inst_games ;;
        FAVORITES) state_favorites ;;
        SETTINGS) state_settings ;;
        CREDITS) state_credits ;;
        SELECT_PREVIEW_REPO) state_select_preview_repo ;;
        CONFIRM_DELETE_PREVIEWS) state_confirm_delete_previews ;;
        CONFIRM_SINGLE_SCRAPE) state_confirm_single_scrape ;;
        CONFIRM_DELETE) state_confirm_delete ;;
        SEARCH_GAMES) state_search_games ;;
        RECENT_DOWNLOADS) state_recent_downloads ;;
        MANAGE_REPOS) state_manage_repos ;;
        CONFIRM_REPO_DELETE) state_confirm_repo_delete ;;
        REPO_SOURCE_INPUT) state_repo_source_input ;;
        REPO_PICK_CONSOLE) state_repo_pick_console ;;
        CHECK_REPO) state_check_repo ;;
        PACK_SCAN) state_pack_scan ;;
        PACK_CONFIRM) state_pack_confirm ;;
        IA_LOGIN_EMAIL|IA_LOGIN_PASS) state_ia_login_input ;;
        SCRAPE_ART) state_scrape_art ;;
        CONFIRM_SCRAPE) state_confirm_scrape ;;
        DO_SCRAPE) state_do_scrape ;;
        PREFETCH_COVERS_SCAN) state_prefetch_covers_scan ;;
        CONFIRM_PREFETCH_COVERS) state_confirm_prefetch_covers ;;
        DO_PREFETCH_COVERS) state_do_prefetch_covers ;;
        *) STATE="MAIN_MENU"; UI_RENDER_NEEDED=1 ;;
    esac
done
