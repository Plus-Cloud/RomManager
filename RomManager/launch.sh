#!/bin/sh
cd /mnt/SDCARD/App/RomManager

# ==========================================
# 1. GLOBAL NAMESPACE & CONFIG
# ==========================================
export PATH="./bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH"
export LD_LIBRARY_PATH="./libs:./bin:/usr/lib:/customer/lib:/config/lib:/lib:$LD_LIBRARY_PATH"

UI_FRAME="/tmp/ui_frame.txt"
UI_RENDERER="./bin/ui_renderer"
chmod +x "$UI_RENDERER"

CACHE_DIR="/mnt/SDCARD/App/RomManager/caches"
RECENT_DL_FILE="$CACHE_DIR/recent_downloads.txt"
FAV_FILE="$CACHE_DIR/favorites.txt"
ARCHIVES_FILE="archives.txt"
SETTINGS_FILE="settings.ini"
SFX_DIR="/mnt/SDCARD/App/RomManager/sounds"

mkdir -p "$CACHE_DIR/previews"
touch "$RECENT_DL_FILE"
touch "$FAV_FILE"

# Default Settings
BGM_ENABLED=1
SFX_ENABLED=1
UI_MAX_ITEMS=10
AUTO_SCRAPE=1
REPO_CACHE_DAYS=7

[ -f "$SETTINGS_FILE" ] && . "$SETTINGS_FILE"

UI_RENDER_NEEDED=1
UI_FRAME_BUF=""

# ==========================================
# 2. STATE GLOBALS
# ==========================================
STATE="MAIN_MENU"

MAIN_INDEX=0
DL_INDEX=0
INST_INDEX=0
REPO_INDEX=0
RECENT_INDEX=0
MISSING_INDEX=0
FAV_INDEX=0
SET_INDEX=0
FOLDER_SELECT_INDEX=0
PREVIEW_REPO_INDEX=0

MARQUEE_POS=0
MARQUEE_TICK=0
DL_KEY_LISTENER_PID=""

DL_CHOSEN_FOLDER=""
DL_CHOSEN_DISPLAY=""
DL_ARCHIVE_ID=""
DL_EXT=""

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
}

start_bgm() {
    [ "$BGM_ENABLED" -eq 0 ] && return
    
    # Do nothing if background process thread is verified up
    if [ -f /tmp/bgm_child.pid ]; then
        local current_pid=$(cat /tmp/bgm_child.pid)
        if [ -n "$current_pid" ] && kill -0 "$current_pid" 2>/dev/null; then
            return
        fi
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
                case "$CMD_BGM_MP3" in *madplay*) seek_flag="-S $offset" ;; *ffplay*) seek_flag="-ss $offset" ;; esac
                case "$CMD_BGM_WAV" in *ffplay*)  seek_flag="-ss $offset" ;; esac
            fi

            # Execute targets and map start time references
            if [ -f "$SFX_DIR/bgm.mp3" ] && [ -n "$CMD_BGM_MP3" ]; then
                echo $(date +%s) > /tmp/bgm_start_epoch
                $CMD_BGM_MP3 $seek_flag "$SFX_DIR/bgm.mp3" </dev/null >/dev/null 2>&1 &
                echo $! > /tmp/bgm_child.pid
                wait $!
            elif [ -f "$SFX_DIR/bgm.wav" ] && [ -n "$CMD_BGM_WAV" ]; then
                local filesize=$(wc -c < "$SFX_DIR/bgm.wav" 2>/dev/null | tr -d ' ')
                if [ "$filesize" -gt 1000 ]; then
                    echo $(date +%s) > /tmp/bgm_start_epoch
                    $CMD_BGM_WAV $seek_flag "$SFX_DIR/bgm.wav" </dev/null >/dev/null 2>&1 &
                    echo $! > /tmp/bgm_child.pid
                    wait $!
                fi
            fi

            # Check if exit was natural (end of song) vs intentional interruption
            if [ -f /tmp/bgm_playing ] && [ ! -f /tmp/bgm_interrupted ]; then
                echo "0" > /tmp/bgm_position
            fi
            
            sleep 0.4
        done
    ) &
    BGM_PID=$!
}

stop_bgm() {
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

trap "stop_bgm; exit 0" INT TERM QUIT

play_sound() {
    [ "$SFX_ENABLED" -eq 0 ] && return
    local sound_file="$SFX_DIR/$1.wav"
    [ -f "$sound_file" ] || return
    [ -z "$CMD_SFX" ] && return
    
    if [ -n "$SFX_PID" ]; then
        kill "$SFX_PID" 2>/dev/null
    fi
    if [ -f /tmp/sfx_child.pid ]; then
        kill $(cat /tmp/sfx_child.pid) 2>/dev/null
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
        $CMD_SFX "$sound_file" </dev/null >/dev/null 2>&1 &
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
    echo "BGM_ENABLED=$BGM_ENABLED" > "$SETTINGS_FILE"
    echo "SFX_ENABLED=$SFX_ENABLED" >> "$SETTINGS_FILE"
    echo "UI_MAX_ITEMS=$UI_MAX_ITEMS" >> "$SETTINGS_FILE"
    echo "AUTO_SCRAPE=$AUTO_SCRAPE" >> "$SETTINGS_FILE"
    echo "REPO_CACHE_DAYS=$REPO_CACHE_DAYS" >> "$SETTINGS_FILE"
    
    if [ "$BGM_ENABLED" -eq 0 ]; then stop_bgm; else start_bgm; fi
}

get_key() {
    KEY=$(./bin/getkey)
    if [ -z "$KEY" ]; then
        sleep 0.08
        return 1
    fi
    sleep 0.02
    return 0
}

update_selection() {
    local key="$1"
    local total="$2"
    local max="$3"
    local current="$4"
    [ "$total" -le 0 ] && total=1
    case "$key" in
        down) current=$((current + 1)); [ "$current" -ge "$total" ] && current=0 ;;
        up) current=$((current - 1)); [ "$current" -lt 0 ] && current=$((total - 1)) ;;
        right) current=$((current + max)); [ "$current" -ge "$total" ] && current=$((total - 1)) ;;
        left) current=$((current - max)); [ "$current" -lt 0 ] && current=0 ;;
    esac
    echo "$current"
}

handle_osk_navigation() {
    case "$KEY" in
        right) OSK_X=$((OSK_X + 1)); [ "$OSK_X" -gt 6 ] && OSK_X=0 ;;
        left) OSK_X=$((OSK_X - 1)); [ "$OSK_X" -lt 0 ] && OSK_X=6 ;;
        down) OSK_Y=$((OSK_Y + 1)); [ "$OSK_Y" -gt 5 ] && OSK_Y=0 ;;
        up) OSK_Y=$((OSK_Y - 1)); [ "$OSK_Y" -lt 0 ] && OSK_Y=5 ;;
        R|R1) OSK_UPPER=$((1 - OSK_UPPER)) ;;
    esac
}

build_theme() {
    UI_FRAME_BUF="THEME_BG:0xFF051105\nTHEME_TEXT:0xFF33FF33\nTHEME_HL:0xFF33FF33\nTHEME_HL_TEXT:0xFF051105\nTHEME_DIM:0xFF33FF33\nFONT:/mnt/SDCARD/App/RomManager/ui/font.ttf:22\nBACKGROUND:/mnt/SDCARD/App/RomManager/ui/bg.png\nTITLE:ROM MANAGER\n"
}

render_ui() {
    printf "%b" "$UI_FRAME_BUF" > "$UI_FRAME"
    $UI_RENDERER "$UI_FRAME"
    UI_RENDER_NEEDED=0
}

invalidate_game_cache() {
    rm -f "$CACHE_DIR/current_games.cache"
    rm -f "$CACHE_DIR/current_games_full.cache"
}

toggle_favorite() {
    local entry="$1"
    if grep -qF "$entry" "$FAV_FILE" 2>/dev/null; then
        grep -vF "$entry" "$FAV_FILE" > "$FAV_FILE.tmp" && mv "$FAV_FILE.tmp" "$FAV_FILE"
    else
        echo "$entry" >> "$FAV_FILE"
    fi
    sed -i '/^$/d' "$FAV_FILE"
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
        # ARCADE, CPS1/2/3, NEOGEO, DOS, PORTS, GW, SCUMMVM: no single-file raw dump
        # format in common use - these are always distributed as zip/7z archives,
        # already covered by the universal defaults.
        *) echo "" ;;
    esac
}

get_console_name() {
    case "$1" in
        "GBA") echo "Game Boy Advance" ;;
        "PS") echo "PlayStation 1" ;;
        "FC") echo "Nintendo NES" ;;
        "SFC") echo "Super Nintendo" ;;
        "SATELLAVIEW") echo "Satellaview" ;;
        "GB") echo "Game Boy" ;;
        "GBC") echo "Game Boy Color" ;;
        "MD") echo "Sega Genesis" ;;
        "GG") echo "Sega Game Gear" ;;
        "SMS") echo "Sega Master System" ;;
        "PCE") echo "TurboGrafx-16" ;;
        "NEOGEO") echo "Neo Geo" ;;
        "ARCADE") echo "Arcade" ;;
        "NGP") echo "Neo Geo Pocket" ;;
        "NGPC") echo "Neo Geo Pocket Color" ;;
        "WS") echo "WonderSwan" ;;
        "WSC") echo "WonderSwan Color" ;;
        "SNES") echo "Super Nintendo" ;;
        "NES") echo "Nintendo NES" ;;
        "ATARI2600") echo "Atari 2600" ;;
        "ATARI7800") echo "Atari 7800" ;;
        "ATARILYNX") echo "Atari Lynx" ;;
        "VB") echo "Virtual Boy" ;;
        "SEGACD") echo "Sega CD" ;;
        "FDS") echo "Famicom Disk System" ;;
        "POKEFAMI") echo "Pokemon Mini" ;;
        "NDS") echo "Nintendo DS" ;;
        "N64") echo "Nintendo 64" ;;
        "CPS1") echo "Capcom Play System 1" ;;
        "CPS2") echo "Capcom Play System 2" ;;
        "CPS3") echo "Capcom Play System 3" ;;
        "DOS") echo "MS-DOS" ;;
        "PORTS") echo "Ports" ;;
        "GW") echo "Game & Watch" ;;
        "MSX") echo "MSX" ;;
        "MSX2") echo "MSX2" ;;
        "PICO") echo "Pico-8" ;;
        "SGB") echo "Super Game Boy" ;;
        "FIFTYTWO00") echo "Atari 5200" ;;
        "AMIGA") echo "Commodore Amiga" ;;
        "C64") echo "Commodore 64" ;;
        "NEOCD") echo "Neo Geo CD" ;;
        "SCUMMVM") echo "ScummVM" ;;
        "PSP") echo "PlayStation Portable" ;;
        "DC") echo "Sega Dreamcast" ;;
        "32X") echo "Sega 32X" ;;
        "PCFX") echo "PC-FX" ;;
        "TIC80") echo "TIC-80" ;;
        "VECTREX") echo "Vectrex" ;;
        *) echo "$1" ;; 
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

fetch_libretro_art_preview() {
    local sys="$1"
    local base="$2"
    local out="$3"
    [ -z "$sys" ] && return 1
    if fetch_libretro_art "$sys" "$base" "$out" "1"; then
        return 0
    else
        touch "${out}.none"
        return 1
    fi
}

# Scrapes an archive.org item's file listing and writes a decoded "title|raw_filename|Unknown MB|0"
# cache file (title is percent-decoded and extension-stripped for display; raw_filename stays
# percent-encoded, since it's used verbatim to build download URLs). Shared by the repo browser
# (FETCH_XML) and the bulk cover prefetcher, so both cache identically-shaped list files.
fetch_repo_list() {
    local archive_id="$1"
    local ext="$2"
    local out_file="$3"
    local folder="$4"
    local status_file="$5"

    local ext_regex="zip|7z|rar|chd"
    local auto_ext=$(get_auto_extensions "$folder")
    [ -n "$auto_ext" ] && ext_regex="${auto_ext}|${ext_regex}"
    [ -n "$ext" ] && ext_regex="${ext}|${ext_regex}"

    # Large repos (thousands of files) can have a multi-megabyte listing page - give it
    # a generous ceiling instead of the tighter timeout used for small API calls, so a
    # slow connection doesn't get cut off mid-download and reported as "empty".
    local tmp_page="$CACHE_DIR/.tmp_repo_page_$$"
    curl -s -L -k --retry 2 --retry-delay 1 --connect-timeout 15 -m 90 "https://archive.org/download/${archive_id}/" -o "$tmp_page"

    if [ ! -s "$tmp_page" ]; then
        rm -f "$tmp_page"
        [ -n "$status_file" ] && echo "no_connection" > "$status_file"
        return 1
    fi

    local tmp_list="$CACHE_DIR/.tmp_repo_list_$$"
    grep -iEo 'href="[^"]*\.('"$ext_regex"')[^"]*"' "$tmp_page" | cut -d'"' -f2 > "$tmp_list"
    rm -f "$tmp_page"

    if [ -s "$tmp_list" ]; then
        awk '
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
            function urldecode(s,    result, i, c) {
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
                return result
            }
            {
                filename = $0;
                title = filename;
                sub(/^.*\//, "", title);
                sub(/\.[^.]+$/, "", title);
                title = urldecode(title);
                print title "|" filename "|Unknown MB|0";
            }
        ' "$tmp_list" | sort -u > "$out_file"
    fi
    rm -f "$tmp_list"

    if [ ! -s "$out_file" ]; then
        [ -n "$status_file" ] && echo "no_matches" > "$status_file"
        return 1
    fi
    return 0
}

refresh_previews_have_list() {
    local previews_mtime=$(stat -c %Y "$CACHE_DIR/previews" 2>/dev/null || echo 0)
    local last_scanned_mtime=$(cat "$CACHE_DIR/preview_cache_mtime.txt" 2>/dev/null)
    if [ "$previews_mtime" != "$last_scanned_mtime" ] || [ ! -f "$CACHE_DIR/preview_cache_have.txt" ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scanning Preview Cache...\nART:NULL\n"
        render_ui
        ls "$CACHE_DIR/previews" 2>/dev/null | grep '\.png$' | sed 's/\.png$//' | sort > "$CACHE_DIR/preview_cache_have.txt"
        echo "$previews_mtime" > "$CACHE_DIR/preview_cache_mtime.txt"
    fi
}

update_local_consoles() {
    [ -f "$CACHE_DIR/local_consoles.cache" ] && return
    
    > "$CACHE_DIR/local_consoles.cache"
    for dir in /mnt/SDCARD/Roms/*; do
        [ -d "$dir" ] || continue
        local folder_name="${dir##*/}"
        local count=$(ls -1 "$dir" 2>/dev/null | grep -ivE -c "^\.|miyoogames\.xml|\.db$|\.png$|\.jpg$|\.txt$|\.json$|^Imgs$")
        if [ "$count" -gt 0 ]; then
            local pretty_name=$(get_console_name "$folder_name")
            echo "${folder_name}|${count}|${pretty_name}" >> "$CACHE_DIR/local_consoles.cache"
        fi
    done
    if [ -s "$CACHE_DIR/local_consoles.cache" ]; then
        sort -u "$CACHE_DIR/local_consoles.cache" -o "$CACHE_DIR/local_consoles.cache"
    fi
}

force_update_local_consoles() {
    rm -f "$CACHE_DIR/local_consoles.cache"
    update_local_consoles
}

initialize_database() {
    if [ ! -f "$ARCHIVES_FILE" ]; then
        cat <<EOF > "$ARCHIVES_FILE"
Nintendo NES|FC||zip
Super Nintendo|SFC||zip
Game Boy|GB||zip
Game Boy Color|GBC||gbc
Game Boy Advance|GBA||zip
Sega Genesis|MD||zip
PlayStation 1|PS||chd
Sega Game Gear|GG||zip
Sega Master System|SMS||zip
TurboGrafx-16|PCE||pce
Neo Geo|NEOGEO||zip
Arcade|ARCADE||zip
EOF
    fi
}

# ==========================================
# 6. STATE FUNCTIONS
# ==========================================

state_main_menu() {
    local total_items=8

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Main Menu\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Download ROMs Database\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Installed ROMs Directory\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Favorite Games\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Scrape Missing Box Art\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Prefetch Repo Previews\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Manage Repositories\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Recent Downloads\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Settings & Tools\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$MAIN_INDEX\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ OK    B/ Exit\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            MAIN_INDEX=$(update_selection "$KEY" "$total_items" 1 "$MAIN_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            case "$MAIN_INDEX" in
                0) STATE="DL_CONSOLES" ;;
                1) update_local_consoles; STATE="INST_CONSOLES" ;;
                2) STATE="FAVORITES" ;;
                3) STATE="SCRAPE_ART" ;;
                4) STATE="PREFETCH_COVERS_SCAN" ;;
                5) STATE="MANAGE_REPOS" ;;
                6) STATE="RECENT_DOWNLOADS" ;;
                7) STATE="SETTINGS" ;;
            esac
            UI_RENDER_NEEDED=1
            ;;
        B|menu)
            play_sound "back"
            stop_bgm
            exit 0
            ;;
    esac
}

state_settings() {
    local total_items=8

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Settings\n"
        
        local bgm_txt="OFF"; [ "$BGM_ENABLED" -eq 1 ] && bgm_txt="ON"
        local sfx_txt="OFF"; [ "$SFX_ENABLED" -eq 1 ] && sfx_txt="ON"
        local scrape_txt="OFF"; [ "$AUTO_SCRAPE" -eq 1 ] && scrape_txt="ON"
        
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Background Music  [$bgm_txt]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Sound Effects      [$sfx_txt]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Max List Items     [$UI_MAX_ITEMS]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Auto Scrape Cover [$scrape_txt]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:Repo Cache (Days) [$REPO_CACHE_DAYS]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:-> Clear Repo Cache\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:-> Manage Preview Cache\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:-> Rebuild Local Database\n"
        
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$SET_INDEX\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Toggle   B/ Save & Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            SET_INDEX=$(update_selection "$KEY" "$total_items" 1 "$SET_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            case "$SET_INDEX" in
                0) BGM_ENABLED=$((1 - BGM_ENABLED)); if [ "$BGM_ENABLED" -eq 0 ]; then stop_bgm; else start_bgm; fi ;;
                1) SFX_ENABLED=$((1 - SFX_ENABLED)) ;;
                2) UI_MAX_ITEMS=$((UI_MAX_ITEMS + 2)); [ "$UI_MAX_ITEMS" -gt 14 ] && UI_MAX_ITEMS=6 ;;
                3) AUTO_SCRAPE=$((1 - AUTO_SCRAPE)) ;;
                4) 
                    case "$REPO_CACHE_DAYS" in
                        1) REPO_CACHE_DAYS=7 ;;
                        7) REPO_CACHE_DAYS=30 ;;
                        30) REPO_CACHE_DAYS=1 ;;
                    esac
                    ;;
                5)
                    rm -f "$CACHE_DIR"/*.list
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Repo Cache Cleared!\n"
                    render_ui; sleep 1.5
                    ;;
                6)
                    PREVIEW_REPO_INDEX=0
                    > "$CACHE_DIR/preview_scope_selected.txt"
                    STATE="SELECT_PREVIEW_REPO"
                    ;;
                7)
                    force_update_local_consoles
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Local Database Rebuilt!\n"
                    render_ui; sleep 1.5
                    ;;
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

state_select_preview_repo() {
    awk -F'|' 'BEGIN{print "[ALL REPOSITORIES]|__ALL__"} $3!=""{print $1"|"$3}' "$ARCHIVES_FILE" > "$CACHE_DIR/preview_scope_list.txt"

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
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Manage Preview Cache ($selected_count selected)\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Toggle  Y/ All  X/ None  Start/ Delete  B/ Back  [$human_pos/$total_items]\n"
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
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            PREVIEW_REPO_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$PREVIEW_REPO_INDEX")
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
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Nothing Selected!\n"
                render_ui
                sleep 1
                UI_RENDER_NEEDED=1
            else
                play_sound "change"
                refresh_previews_have_list

                > "$CACHE_DIR/preview_delete_targets.txt"
                while read -r repo_id; do
                    [ -z "$repo_id" ] && continue
                    local repo_list="$CACHE_DIR/${repo_id}.list"
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
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No Cached Previews for Selection!\n"
                    render_ui
                    sleep 1.5
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

    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Delete $target_count cached preview(s)?\nHIGHLIGHT:0\nFOOTER:A/ Yes, Delete   B/ Cancel\nART:NULL\n"
    render_ui

    while true; do
        get_key || continue

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
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:$target_count Preview(s) Deleted!\n"
                render_ui
                sleep 1.5

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

state_dl_consoles() {
    local total_items=$(wc -l < "$ARCHIVES_FILE")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((DL_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((DL_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (DL_INDEX * 100) / (total_items - 1) ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Internet Archive DB\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page   A/ OK   B/ Back  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$1, 1, 28) }" "$ARCHIVES_FILE")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((DL_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            DL_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$DL_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local entry=$(sed -n "$((DL_INDEX + 1))p" "$ARCHIVES_FILE" | tr -d '\r')
            DL_CHOSEN_DISPLAY=$(echo "$entry" | cut -d'|' -f1)
            DL_CHOSEN_FOLDER=$(echo "$entry" | cut -d'|' -f2)
            DL_ARCHIVE_ID=$(echo "$entry" | cut -d'|' -f3)
            DL_EXT=$(echo "$entry" | cut -d'|' -f4)

            if [ -z "$DL_ARCHIVE_ID" ]; then
                play_sound "back"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No Repo Set! Add one in Manage Repos.\n"
                render_ui
                sleep 2
                UI_RENDER_NEEDED=1
                return
            fi

            local cache_file="$CACHE_DIR/${DL_ARCHIVE_ID}.list"
            DOWNLOAD_RETURN_STATE="DL_GAMES"
            
            if [ -s "$cache_file" ]; then
                local NOW=$(date +%s)
                local MOD=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
                local AGE=$((NOW - MOD))
                local MAX_AGE=$((REPO_CACHE_DAYS * 86400))
                if [ "$AGE" -gt "$MAX_AGE" ]; then
                    rm -f "$cache_file"
                fi
            fi

            if [ -s "$cache_file" ]; then
                cp "$cache_file" "$CACHE_DIR/current_games.cache"
                rm -f "$CACHE_DIR/current_games_full.cache"
                STATE="DL_GAMES"
            else
                STATE="FETCH_XML"
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

state_fetch_xml() {
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Connecting to Server...\nPROGRESS:0\n"
    render_ui

    local cache_file="$CACHE_DIR/${DL_ARCHIVE_ID}.list"
    local status_file="$CACHE_DIR/.fetch_status"

    rm -f /tmp/xml_active /tmp/xml_cancel "$status_file"

    (
        fetch_repo_list "$DL_ARCHIVE_ID" "$DL_EXT" "$cache_file" "$DL_CHOSEN_FOLDER" "$status_file"
        rm -f /tmp/xml_active
    ) &
    local curl_pid=$!

    (
        while [ -f /tmp/xml_active ]; do
            k=$(./bin/getkey)
            if [ "$k" = "B" ]; then
                touch /tmp/xml_cancel
                break
            fi
        done
    ) &
    local key_pid=$!

    local prog_val=0
    local spin_idx=0

    while [ -f /tmp/xml_active ]; do
        if [ -f /tmp/xml_cancel ]; then
            play_sound "back"
            kill -9 $curl_pid 2>/dev/null
            rm -f /tmp/xml_active "$cache_file" /tmp/xml_cancel
            STATE="DL_CONSOLES"
            UI_RENDER_NEEDED=1
            kill -9 $key_pid 2>/dev/null
            return
        fi

        spin_idx=$(( (spin_idx + 1) % 4 ))
        local spin_char=""
        case $spin_idx in 0) spin_char="|";; 1) spin_char="/";; 2) spin_char="-";; 3) spin_char="\\";; esac

        prog_val=$(( (prog_val + 5) % 100 ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Connecting... [$spin_char]\nPROGRESS:$prog_val\nFOOTER:B/ Cancel\n"
        render_ui
        sleep 0.1
    done

    kill -9 $key_pid 2>/dev/null

    if [ -s "$cache_file" ]; then
        cp "$cache_file" "$CACHE_DIR/current_games.cache"
        rm -f "$CACHE_DIR/current_games_full.cache"
        STATE="DL_GAMES"
        DL_INDEX=0
        MARQUEE_POS=0
        MARQUEE_TICK=0
    else
        local reason=$(cat "$status_file" 2>/dev/null)
        play_sound "back"
        build_theme
        if [ "$reason" = "no_connection" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Connection Failed! Check your network.\n"
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No Matching Files Found in Repo!\n"
        fi
        render_ui
        sleep 2
        STATE="DL_CONSOLES"
    fi
    UI_RENDER_NEEDED=1
}

state_dl_games() {
    if [ ! -s "$CACHE_DIR/current_games.cache" ] && [ ! -f "$CACHE_DIR/current_games_full.cache" ]; then
        [ -n "$DL_KEY_LISTENER_PID" ] && kill -9 "$DL_KEY_LISTENER_PID" 2>/dev/null
        DL_KEY_LISTENER_PID=""
        STATE="DL_CONSOLES"
        UI_RENDER_NEEDED=1
        return
    fi

    local total_items=$(wc -l < "$CACHE_DIR/current_games.cache")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((DL_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((DL_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (DL_INDEX * 100) / (total_items - 1) ))

        local game_line=$(sed -n "$((DL_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
        local title=$(echo "$game_line" | cut -d'|' -f1)
        
        local raw_file_name=$(echo "$game_line" | cut -d'|' -f2)
        local safe_file_name="${raw_file_name##*/}"
        safe_file_name=$(url_decode "$safe_file_name")
        
        local base_name="${safe_file_name%.*}"
        local target_dir="/mnt/SDCARD/Roms/$DL_CHOSEN_FOLDER"
        
        local is_installed=0
        local is_fav=0
        local inst_text=""
        
        [ -f "$target_dir/$safe_file_name" ] && { is_installed=1; inst_text="[Downloaded ✓]"; }
        
        local match_str="${DL_CHOSEN_FOLDER}|${safe_file_name}|${title}"
        grep -qF "$match_str" "$FAV_FILE" 2>/dev/null && { is_fav=1; inst_text="$inst_text [★ FAVORITE]"; }

        build_theme
        local truncated_console=$(echo "$DL_CHOSEN_DISPLAY" | cut -c 1-20)
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:${truncated_console} DB $inst_text\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ DL   Start/ Fav   Sel/ Search   B/ Back  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        local hl_line=$((DL_INDEX + 1))
        local items=$(awk -F'|' -v hl_line="$hl_line" -v mq_pos="$MARQUEE_POS" "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) {
            name = \$1;
            sub(/\.[^.]+$/, \"\", name);
            if (NR == hl_line && length(name) > 28) {
                padded = name \"   \" name;
                print substr(padded, mq_pos + 1, 28);
            } else {
                print substr(name, 1, 28);
            }
        }" "$CACHE_DIR/current_games.cache")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        if [ "$is_installed" -eq 1 ] && [ -s "$target_dir/Imgs/${base_name}.png" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$target_dir/Imgs/${base_name}.png\n"
        elif [ -s "$CACHE_DIR/previews/${base_name}.png" ]; then
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:$CACHE_DIR/previews/${base_name}.png\n"
        else
            UI_FRAME_BUF="${UI_FRAME_BUF}ART:BLANK\n"
        fi

        local rel=$((DL_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    # ./bin/getkey blocks until a key event arrives, so calling it directly here (like every
    # other screen does) would freeze the marquee animation while the player isn't touching
    # anything - this screen would just sit waiting for the next press with no idle ticks in
    # between. Run it in a background listener instead (the same trick FETCH_XML/DOWNLOAD use
    # for their cancel-listeners) and poll for its result; while it's still waiting, this is
    # an idle tick and the marquee gets to advance.
    if [ -z "$DL_KEY_LISTENER_PID" ]; then
        rm -f "$CACHE_DIR/.dl_key_result"
        ( ./bin/getkey > "$CACHE_DIR/.dl_key_result" 2>/dev/null ) &
        DL_KEY_LISTENER_PID=$!
    fi

    if kill -0 "$DL_KEY_LISTENER_PID" 2>/dev/null; then
        KEY=""
    else
        KEY=$(cat "$CACHE_DIR/.dl_key_result" 2>/dev/null)
        DL_KEY_LISTENER_PID=""
    fi

    if [ -z "$KEY" ]; then
        sleep 0.08
        local hl_title=$(sed -n "$((DL_INDEX + 1))p" "$CACHE_DIR/current_games.cache" | cut -d'|' -f1)
        if [ ${#hl_title} -gt 28 ]; then
            MARQUEE_TICK=$((MARQUEE_TICK + 1))
            if [ "$MARQUEE_TICK" -ge 3 ]; then
                MARQUEE_TICK=0
                MARQUEE_POS=$(( (MARQUEE_POS + 1) % (${#hl_title} + 3) ))
                UI_RENDER_NEEDED=1
            fi
        fi
        return
    fi
    sleep 0.02

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            DL_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$DL_INDEX")
            MARQUEE_POS=0
            MARQUEE_TICK=0
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "change"
            [ ! -f "$CACHE_DIR/current_games_full.cache" ] && cp "$CACHE_DIR/current_games.cache" "$CACHE_DIR/current_games_full.cache"
            STATE="SEARCH_GAMES"
            SEARCH_RETURN_STATE="DL_GAMES"
            OSK_X=0; OSK_Y=0; OSK_BUF=""; OSK_UPPER=0
            UI_RENDER_NEEDED=1
            ;;
        start)
            play_sound "confirm"
            local game_line=$(sed -n "$((DL_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
            local title=$(echo "$game_line" | cut -d'|' -f1)
            local raw_file_name=$(echo "$game_line" | cut -d'|' -f2)
            local safe_file_name="${raw_file_name##*/}"
            safe_file_name=$(url_decode "$safe_file_name")
            toggle_favorite "${DL_CHOSEN_FOLDER}|${safe_file_name}|${title}"
            UI_RENDER_NEEDED=1
            ;;
        X)
            play_sound "back"
            rm -f "$CACHE_DIR/${DL_ARCHIVE_ID}.list"
            rm -f "$CACHE_DIR/current_games_full.cache"
            STATE="DL_CONSOLES"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            if [ -f "$CACHE_DIR/current_games_full.cache" ]; then
                mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            else
                STATE="DL_CONSOLES"
            fi
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local game_line=$(sed -n "$((DL_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
            local raw_file_name=$(echo "$game_line" | cut -d'|' -f2)
            local safe_file_name="${raw_file_name##*/}"
            safe_file_name=$(url_decode "$safe_file_name")
            local target_dir="/mnt/SDCARD/Roms/$DL_CHOSEN_FOLDER"

            if [ -f "$target_dir/$safe_file_name" ]; then
                local base_name="${safe_file_name%.*}"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:You already have this ROM!\n"
                if [ -s "$target_dir/Imgs/${base_name}.png" ]; then
                    UI_FRAME_BUF="${UI_FRAME_BUF}ART:$target_dir/Imgs/${base_name}.png\n"
                else
                    UI_FRAME_BUF="${UI_FRAME_BUF}ART:BLANK\n"
                fi
                render_ui
                sleep 1.5
            else
                STATE="CONFIRM_DOWNLOAD"
            fi
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_confirm_download() {
    local game_line=$(sed -n "$((DL_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
    local game_title=$(echo "$game_line" | cut -d'|' -f1 | cut -c 1-22)
    local raw_file_name=$(echo "$game_line" | cut -d'|' -f2)
    local safe_file_name="${raw_file_name##*/}"
    safe_file_name=$(url_decode "$safe_file_name")
    local game_size_mb=$(echo "$game_line" | cut -d'|' -f3)
    local game_size_bytes=$(echo "$game_line" | cut -d'|' -f4) 
    local base_name="${safe_file_name%.*}"

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Fetching Preview...\nITEM:$game_title\nHIGHLIGHT:0\n"
        render_ui

        if [ ! -s "$CACHE_DIR/previews/${base_name}.png" ]; then
            local libretro_sys=$(get_libretro_system "$DL_CHOSEN_FOLDER")
            fetch_libretro_art "$libretro_sys" "$base_name" "$CACHE_DIR/previews/${base_name}.png"
        fi
        UI_RENDER_NEEDED=0
    fi

    local preview_path="BLANK"
    [ -s "$CACHE_DIR/previews/${base_name}.png" ] && preview_path="$CACHE_DIR/previews/${base_name}.png"

    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Download? ($game_size_mb)\nITEM:$game_title\nHIGHLIGHT:0\nFOOTER:A/ Confirm   B/ Cancel\nART:$preview_path\n"
    render_ui

    while true; do
        get_key || continue

        case "$KEY" in
            A)
                play_sound "change"
                local target_dir="/mnt/SDCARD/Roms/$DL_CHOSEN_FOLDER"
                mkdir -p "$target_dir"

                local download_url="https://archive.org/download/${DL_ARCHIVE_ID}/${raw_file_name}"

                rm -f /tmp/dl_active /tmp/dl_cancel
                touch /tmp/dl_active

                (
                    curl --fail --retry 3 --retry-delay 1 -f -s -L -k --connect-timeout 10 -A "Mozilla/5.0" "$download_url" -o "$target_dir/.tmp_$safe_file_name" < /dev/null
                    rm -f /tmp/dl_active
                ) &
                local dl_pid=$!
                
                (
                    while [ -f /tmp/dl_active ]; do
                        k=$(./bin/getkey)
                        if [ "$k" = "B" ]; then
                            touch /tmp/dl_cancel
                            break
                        fi
                    done
                ) &
                local key_pid=$!
                
                local dl_cancelled=0
                local prog_val=0
                
                while [ -f /tmp/dl_active ]; do
                    if [ -f /tmp/dl_cancel ]; then
                        play_sound "back"
                        kill -9 $dl_pid 2>/dev/null
                        rm -f /tmp/dl_active /tmp/dl_cancel
                        rm -f "$target_dir/.tmp_$safe_file_name"
                        dl_cancelled=1
                        break
                    fi
                
                    local current_bytes=$(wc -c < "$target_dir/.tmp_$safe_file_name" 2>/dev/null | tr -d ' ')
                    [ -z "$current_bytes" ] && current_bytes=0
                    
                    if [ -n "$game_size_bytes" ] && [ "$game_size_bytes" -gt 0 ]; then
                        prog_val=$(( (current_bytes * 100) / game_size_bytes ))
                        [ "$prog_val" -gt 100 ] && prog_val=100
                    else
                        prog_val=$(( (prog_val + 2) % 100 ))
                    fi
                    
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Downloading ${game_title}...\n"
                    UI_FRAME_BUF="${UI_FRAME_BUF}PROGRESS:$prog_val\nFOOTER:B/ Cancel\nART:$preview_path\n"
                    render_ui
                    sleep 0.2
                done
                
                kill -9 $key_pid 2>/dev/null
                
                local FILESIZE=$(wc -c < "$target_dir/.tmp_$safe_file_name" 2>/dev/null | tr -d ' ')
                [ -z "$FILESIZE" ] && FILESIZE=0

                if [ "$dl_cancelled" -eq 1 ]; then
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Download Cancelled!\nART:$preview_path\n"
                    render_ui
                    sleep 1.5
                elif [ "$FILESIZE" -ge 1024 ]; then
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Finalising Download...\nPROGRESS:90\nART:$preview_path\n"
                    render_ui

                    mv "$target_dir/.tmp_$safe_file_name" "$target_dir/$safe_file_name"
                    invalidate_game_cache
                    force_update_local_consoles

                    # Bin/Cue disc images: the .cue sheet is a separate file on the archive
                    # sharing the same base name as the .bin - fetch it alongside automatically.
                    # Detected from the actual downloaded file's extension (not a per-repo
                    # setting), so it works whether .bin showed up via the automatic PS1
                    # extension or a manually configured repo format.
                    local cue_raw_name=$(echo "$raw_file_name" | sed 's/\.[Bb][Ii][Nn]$/.cue/')
                    if [ "$cue_raw_name" != "$raw_file_name" ]; then
                        local safe_cue_name="${cue_raw_name##*/}"
                        safe_cue_name=$(url_decode "$safe_cue_name")
                        local cue_url="https://archive.org/download/${DL_ARCHIVE_ID}/${cue_raw_name}"

                        build_theme
                        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Downloading matching .cue...\nPROGRESS:95\nART:$preview_path\n"
                        render_ui

                        curl --fail --retry 3 --retry-delay 1 -f -s -L -k --connect-timeout 10 -A "Mozilla/5.0" "$cue_url" -o "$target_dir/$safe_cue_name" < /dev/null
                        if [ ! -s "$target_dir/$safe_cue_name" ]; then
                            rm -f "$target_dir/$safe_cue_name"
                            build_theme
                            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Warning: .cue file not found on repo!\nART:$preview_path\n"
                            render_ui
                            sleep 1.5
                        fi
                    fi

                    if [ "$preview_path" != "BLANK" ]; then
                        mkdir -p "$target_dir/Imgs"
                        cp "$preview_path" "$target_dir/Imgs/${base_name}.png"
                    elif [ "$AUTO_SCRAPE" -eq 1 ]; then
                        local libretro_sys=$(get_libretro_system "$DL_CHOSEN_FOLDER")
                        mkdir -p "$target_dir/Imgs"
                        fetch_libretro_art "$libretro_sys" "$base_name" "$target_dir/Imgs/${base_name}.png"
                    fi
                    
                    rm -f "$target_dir/miyoocache.bin"
                    rm -f "$target_dir/miyoogames.xml"

                    echo "${game_title}|${DL_CHOSEN_FOLDER}" > "$CACHE_DIR/tmp_recent.txt"
                    [ -f "$RECENT_DL_FILE" ] && cat "$RECENT_DL_FILE" >> "$CACHE_DIR/tmp_recent.txt"
                    head -n 20 "$CACHE_DIR/tmp_recent.txt" > "$RECENT_DL_FILE"
                    rm -f "$CACHE_DIR/tmp_recent.txt"

                    play_sound "confirm"
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Ready to Play!\nPROGRESS:100\nART:$preview_path\n"
                    render_ui
                    sleep 1.2
                else
                    rm -f "$target_dir/.tmp_$safe_file_name"
                    play_sound "back"
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Download Corrupt/Failed!\nART:$preview_path\n"
                    render_ui
                    sleep 2
                fi
                
                STATE="${DOWNLOAD_RETURN_STATE:-DL_GAMES}"
                UI_RENDER_NEEDED=1
                return
                ;;
            B)
                play_sound "back"
                STATE="${DOWNLOAD_RETURN_STATE:-DL_GAMES}"
                UI_RENDER_NEEDED=1
                return
                ;;
        esac
    done
}

state_inst_consoles() {
    if [ ! -s "$CACHE_DIR/local_consoles.cache" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:B/ Back\nSTATUS:No Local ROM Directories Found\n"
            render_ui
        fi
        get_key || return
        if [ "$KEY" = "B" ] || [ "$KEY" = "menu" ]; then
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    local total_items=$(wc -l < "$CACHE_DIR/local_consoles.cache")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((INST_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((INST_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (INST_INDEX * 100) / (total_items - 1) ))

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Installed Folders\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page   A/ Open   B/ Back  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { 
            disp = \$3 \" (\" \$2 \")\";
            print substr(disp, 1, 28) 
        }" "$CACHE_DIR/local_consoles.cache")
        
        while read -r disp_str; do
            [ -n "$disp_str" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${disp_str}\n"
        done <<EOF
$items
EOF

        local rel=$((INST_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            INST_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$INST_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local fld_raw=$(sed -n "$((INST_INDEX + 1))p" "$CACHE_DIR/local_consoles.cache" | cut -d'|' -f1)
            INST_CHOSEN_FOLDER="$fld_raw"
            INST_CHOSEN_DISPLAY=$(get_console_name "$INST_CHOSEN_FOLDER")
            local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
            
            ls -1 "$target_dir" 2>/dev/null | grep -ivE "^\.|miyoogames\.xml|\.db$|\.png$|\.jpg$|\.txt$|\.json$|^Imgs$" > "$CACHE_DIR/current_games.cache"
            
            if [ ! -s "$CACHE_DIR/current_games.cache" ]; then
                 build_theme
                 UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No ROMs Found!\n"
                 render_ui
                 sleep 1.5
                 UI_RENDER_NEEDED=1
                 return
            fi
            
            rm -f "$CACHE_DIR/current_games_full.cache"
            STATE="INST_GAMES"
            INST_INDEX=0
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_inst_games() {
    if [ ! -s "$CACHE_DIR/current_games.cache" ] && [ ! -f "$CACHE_DIR/current_games_full.cache" ]; then
        STATE="INST_CONSOLES"
        UI_RENDER_NEEDED=1
        return
    fi

    local total_items=$(wc -l < "$CACHE_DIR/current_games.cache")
    [ "$total_items" -le 0 ] && total_items=1
    
    if [ "$total_items" -eq 0 ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No matches found.\nFOOTER:B/ Clear Search\nART:NULL\nITEM: \nHIGHLIGHT:-1\n"
            render_ui
        fi
        get_key || return
        if [ "$KEY" = "B" ]; then
            play_sound "back"
            cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            rm -f "$CACHE_DIR/current_games_full.cache"
            INST_INDEX=0
            UI_RENDER_NEEDED=1
        fi
        return
    fi

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((INST_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((INST_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (INST_INDEX * 100) / (total_items - 1) ))

        local highlighted_file=$(sed -n "$((INST_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
        local base_name="${highlighted_file%.*}"
        local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
        
        local is_fav=0
        local fav_text=""
        
        local match_str="${INST_CHOSEN_FOLDER}|${highlighted_file}|${base_name}"
        grep -qF "$match_str" "$FAV_FILE" 2>/dev/null && { is_fav=1; fav_text=" [★ FAVORITE]"; }

        build_theme
        local truncated_console=$(echo "$INST_CHOSEN_DISPLAY" | cut -c 1-20)
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Local -> ${truncated_console} $fav_text\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Scrape   Y/ Del  Start/ Fav   Sel/ Search   B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { 
            name = \$1;
            sub(/\.[^.]+$/, \"\", name); 
            print substr(name, 1, 28) 
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

        local rel=$((INST_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            INST_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$INST_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "change"
            [ ! -f "$CACHE_DIR/current_games_full.cache" ] && cp "$CACHE_DIR/current_games.cache" "$CACHE_DIR/current_games_full.cache"
            STATE="SEARCH_GAMES"
            SEARCH_RETURN_STATE="INST_GAMES"
            OSK_X=0; OSK_Y=0; OSK_BUF=""; OSK_UPPER=0
            UI_RENDER_NEEDED=1
            ;;
        start)
            play_sound "confirm"
            local game_line=$(sed -n "$((INST_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
            local base_name="${game_line%.*}"
            toggle_favorite "${INST_CHOSEN_FOLDER}|${game_line}|${base_name}"
            UI_RENDER_NEEDED=1
            ;;
        X)
            play_sound "change"
            local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
            ls -1 "$target_dir" 2>/dev/null | grep -ivE "^\.|miyoogames\.xml|\.db$|\.png$|\.jpg$|\.txt$|\.json$|^Imgs$" > "$CACHE_DIR/current_games.cache"
            rm -f "$CACHE_DIR/current_games_full.cache"
            INST_INDEX=0
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            STATE="CONFIRM_DELETE"
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            STATE="CONFIRM_SINGLE_SCRAPE"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            if [ -f "$CACHE_DIR/current_games_full.cache" ]; then
                mv "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"
            else
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
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No Favorites Found\nFOOTER:B/ Back\nART:NULL\nITEM: \nHIGHLIGHT:-1\n"
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

        local entry=""
        local base_name="null"
        local fld=""
        local target_dir="/mnt/SDCARD/null"

        entry=$(sed -n "$((FAV_INDEX + 1))p" "$FAV_FILE" | tr -d '\r')
        if [ -n "$entry" ]; then
            fld=$(echo "$entry" | cut -d'|' -f1)
            local fn=$(echo "$entry" | cut -d'|' -f2)
            base_name="${fn%.*}"
            target_dir="/mnt/SDCARD/Roms/$fld"
        fi

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Favorite Games\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page  A/ Install  Start/ Remove  B/ Back  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$3, 1, 28) }" "$FAV_FILE")
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

        local rel=$((FAV_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            FAV_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$FAV_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local entry=$(sed -n "$((FAV_INDEX + 1))p" "$FAV_FILE" | tr -d '\r')
            if [ -n "$entry" ]; then
                local fld=$(echo "$entry" | cut -d'|' -f1)
                local rom_file=$(echo "$entry" | cut -d'|' -f2)
                local base_name="${rom_file%.*}"
                
                if [ -f "/mnt/SDCARD/Roms/$fld/$rom_file" ]; then
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:You already have this ROM!\nART:BLANK\n"
                    render_ui
                    sleep 1.5
                else
                    DL_CHOSEN_FOLDER="$fld"
                    DL_ARCHIVE_ID=$(awk -F'|' -v f="$fld" '$2==f {print $3}' "$ARCHIVES_FILE" | tr -d '\r')
                    DL_CHOSEN_DISPLAY=$(awk -F'|' -v f="$fld" '$2==f {print $1}' "$ARCHIVES_FILE")
                    DL_EXT=$(awk -F'|' -v f="$fld" '$2==f {print $4}' "$ARCHIVES_FILE")
                    
                    if [ -z "$DL_ARCHIVE_ID" ]; then
                        build_theme
                        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Error: No Repo setup for $fld!\nART:BLANK\n"
                        render_ui
                        sleep 1.5
                    else
                        echo "${base_name}|${rom_file}|Unknown MB|0" > "$CACHE_DIR/current_games.cache"
                        DL_INDEX=0
                        DOWNLOAD_RETURN_STATE="FAVORITES"
                        STATE="CONFIRM_DOWNLOAD"
                    fi
                fi
                UI_RENDER_NEEDED=1
            fi
            ;;
        start)
            play_sound "back"
            local entry=$(sed -n "$((FAV_INDEX + 1))p" "$FAV_FILE" | tr -d '\r')
            toggle_favorite "$entry"
            FAV_INDEX=0
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_confirm_single_scrape() {
    local game_file=$(sed -n "$((INST_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
    local base_name="${game_file%.*}"
    local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
    local art_path="BLANK"
    [ -s "${target_dir}/Imgs/${base_name}.png" ] && art_path="${target_dir}/Imgs/${base_name}.png"

    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scrape Box Art for this game?\nITEM:$game_file\nHIGHLIGHT:0\nFOOTER:A/ Yes, Scrape   B/ Cancel\nART:$art_path\n"
    render_ui

    while true; do
        get_key || continue

        case "$KEY" in
            A)
                play_sound "change"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Searching Libretro Database...\nPROGRESS:50\nART:$art_path\n"
                render_ui

                local libretro_sys=$(get_libretro_system "$INST_CHOSEN_FOLDER")
                mkdir -p "$target_dir/Imgs"
                
                if fetch_libretro_art "$libretro_sys" "$base_name" "$target_dir/Imgs/${base_name}.png"; then
                    play_sound "confirm"
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scrape Successful!\nPROGRESS:100\nART:$target_dir/Imgs/${base_name}.png\n"
                    render_ui
                    sleep 1.2
                else
                    play_sound "back"
                    build_theme
                    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Art Not Found in Database!\n"
                    render_ui
                    sleep 2
                fi
                STATE="INST_GAMES"
                UI_RENDER_NEEDED=1
                return
                ;;
            B)
                play_sound "back"
                STATE="INST_GAMES"
                UI_RENDER_NEEDED=1
                return
                ;;
        esac
    done
}

state_confirm_delete() {
    local game_file=$(sed -n "$((INST_INDEX + 1))p" "$CACHE_DIR/current_games.cache")
    local base_name="${game_file%.*}"
    local target_dir="/mnt/SDCARD/Roms/$INST_CHOSEN_FOLDER"
    local art_path="BLANK"
    [ -s "${target_dir}/Imgs/${base_name}.png" ] && art_path="${target_dir}/Imgs/${base_name}.png"

    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Delete this game permanently?\nITEM:$game_file\nHIGHLIGHT:0\nFOOTER:A/ Yes, Delete   B/ Cancel\nART:$art_path\n"
    render_ui

    while true; do
        get_key || continue

        case "$KEY" in
            A)
                play_sound "change"
                rm -f "${target_dir}/${game_file}"
                rm -f "${target_dir}/Imgs/${base_name}.png"
                rm -f "${target_dir}/miyoocache.bin"
                
                local match_str="${INST_CHOSEN_FOLDER}|${game_file}|${base_name}"
                grep -vF "$match_str" "$FAV_FILE" > "$FAV_FILE.tmp" && mv "$FAV_FILE.tmp" "$FAV_FILE"
                sed -i '/^$/d' "$FAV_FILE"
                
                invalidate_game_cache
                force_update_local_consoles
                
                STATE="INST_GAMES"
                UI_RENDER_NEEDED=1
                return
                ;;
            B)
                play_sound "back"
                STATE="INST_GAMES"
                UI_RENDER_NEEDED=1
                return
                ;;
        esac
    done
}

state_search_games() {
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local match_count=$(wc -l < "$CACHE_DIR/current_games.cache")
        local caps_txt="OFF"
        [ "$OSK_UPPER" -eq 1 ] && caps_txt="ON"
        
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Search Active ($match_count matches)\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Type  B/ Del  Sel/ Cancel  Start/ Done  R/ Caps [$caps_txt]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}OSK:$OSK_X:$OSK_Y:$OSK_BUF\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        up|down|left|right|R|R1)
            play_sound "change"
            handle_osk_navigation
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            OSK_BUF="${OSK_BUF%?}" 
            if [ ${#OSK_BUF} -ge 2 ]; then grep -iF "$OSK_BUF" "$CACHE_DIR/current_games_full.cache" > "$CACHE_DIR/current_games.cache"
            else cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"; fi
            [ "$SEARCH_RETURN_STATE" = "DL_GAMES" ] && DL_INDEX=0
            [ "$SEARCH_RETURN_STATE" = "INST_GAMES" ] && INST_INDEX=0
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
            play_sound "confirm"
            STATE="$SEARCH_RETURN_STATE"
            UI_RENDER_NEEDED=1
            ;;
        A)
            local char=""
            if [ $OSK_Y -eq 0 ]; then case $OSK_X in 0) char="a";; 1) char="b";; 2) char="c";; 3) char="d";; 4) char="e";; 5) char="f";; 6) char="g";; esac
            elif [ $OSK_Y -eq 1 ]; then case $OSK_X in 0) char="h";; 1) char="i";; 2) char="j";; 3) char="k";; 4) char="l";; 5) char="m";; 6) char="n";; esac
            elif [ $OSK_Y -eq 2 ]; then case $OSK_X in 0) char="o";; 1) char="p";; 2) char="q";; 3) char="r";; 4) char="s";; 5) char="t";; 6) char="u";; esac
            elif [ $OSK_Y -eq 3 ]; then case $OSK_X in 0) char="v";; 1) char="w";; 2) char="x";; 3) char="y";; 4) char="z";; 5) char="-";; 6) char="_";; esac
            elif [ $OSK_Y -eq 4 ]; then case $OSK_X in 0) char="0";; 1) char="1";; 2) char="2";; 3) char="3";; 4) char="4";; 5) char="5";; 6) char="6";; esac
            elif [ $OSK_Y -eq 5 ]; then
                if [ $OSK_X -eq 3 ]; then play_sound "change"; OSK_UPPER=$((1 - OSK_UPPER))
                elif [ $OSK_X -eq 4 ]; then play_sound "back"; OSK_BUF="${OSK_BUF%?}"
                elif [ $OSK_X -eq 5 ]; then
                    play_sound "back"
                    STATE="$SEARCH_RETURN_STATE"
                elif [ $OSK_X -eq 6 ]; then
                    play_sound "confirm"
                    STATE="$SEARCH_RETURN_STATE"
                    [ "$STATE" = "DL_GAMES" ] && DL_INDEX=0
                    [ "$STATE" = "INST_GAMES" ] && INST_INDEX=0
                else case $OSK_X in 0) char="7";; 1) char="8";; 2) char="9";; esac
                fi
            fi
            
            if [ -n "$char" ] && [ $OSK_X -lt 4 -o $OSK_Y -lt 5 ]; then
                play_sound "change"
                [ "$OSK_UPPER" -eq 1 ] && char=$(echo "$char" | tr 'a-z' 'A-Z')
                OSK_BUF="${OSK_BUF}${char}"
            fi
            
            if [ ${#OSK_BUF} -ge 2 ]; then grep -iF "$OSK_BUF" "$CACHE_DIR/current_games_full.cache" > "$CACHE_DIR/current_games.cache"
            else cp "$CACHE_DIR/current_games_full.cache" "$CACHE_DIR/current_games.cache"; fi
            
            [ "$SEARCH_RETURN_STATE" = "DL_GAMES" ] && DL_INDEX=0
            [ "$SEARCH_RETURN_STATE" = "INST_GAMES" ] && INST_INDEX=0
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_recent_downloads() {
    if [ ! -s "$RECENT_DL_FILE" ]; then
        if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No Recent Downloads\nFOOTER:B/ Back\nART:NULL\nITEM: \nHIGHLIGHT:-1\n"
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

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Recent Downloads\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page   B/ Back  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$1, 1, 28) }" "$RECENT_DL_FILE")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((RECENT_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            RECENT_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$RECENT_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_manage_repos() {
    local total_items=$(wc -l < "$ARCHIVES_FILE")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((REPO_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then 
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((REPO_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (REPO_INDEX * 100) / (total_items - 1) ))

        local cur_entry=$(sed -n "$((REPO_INDEX + 1))p" "$ARCHIVES_FILE")
        local cur_fld=$(echo "$cur_entry" | cut -d'|' -f2)
        local cur_ext=$(echo "$cur_entry" | cut -d'|' -f4 | tr -d '\r')
        [ -z "$cur_ext" ] && cur_ext="none"

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Manage Repositories [Fld: $cur_fld | Fmt: $cur_ext]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Edit  X/ Format  Sel/ Folder  Y/ Clear  B/ Back\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { repo=\$3; if(repo==\"\") repo=\"ADD REPO\"; print substr(\$1, 1, 12) \" -> \" substr(repo, 1, 14) }" "$ARCHIVES_FILE")
        while read -r disp; do
            [ -n "$disp" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${disp}\n"
        done <<EOF
$items
EOF

        local rel=$((REPO_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            REPO_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$REPO_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        Y)
            play_sound "change"
            local entry=$(sed -n "$((REPO_INDEX + 1))p" "$ARCHIVES_FILE")
            local archive_id=$(echo "$entry" | cut -d'|' -f3 | tr -d '\r')
            if [ -n "$archive_id" ]; then
                rm -f "$CACHE_DIR/${archive_id}.list"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Cache Cleared for repo.\n"
                render_ui
                sleep 1.2
            fi
            UI_RENDER_NEEDED=1
            ;;
        X)
            play_sound "change"
            local line_num=$((REPO_INDEX + 1))
            local entry=$(sed -n "${line_num}p" "$ARCHIVES_FILE")
            local sys_name=$(echo "$entry" | cut -d'|' -f1)
            local sys_fld=$(echo "$entry" | cut -d'|' -f2)
            local sys_id=$(echo "$entry" | cut -d'|' -f3 | tr -d '\r')
            local cur_ext=$(echo "$entry" | cut -d'|' -f4 | tr -d '\r')
            local new_ext=""
            case "$cur_ext" in
                zip) new_ext="chd" ;;
                chd) new_ext="bin" ;;
                bin) new_ext="7z" ;;
                7z) new_ext="rar" ;;
                rar) new_ext="pce" ;;
                pce) new_ext="gbc" ;;
                gbc) new_ext="zip" ;;
                *) new_ext="zip" ;;
            esac
            sed -i "${line_num}c\\${sys_name}|${sys_fld}|${sys_id}|${new_ext}" "$ARCHIVES_FILE"
            # The cached listing was scraped with the old format filter - invalidate it so
            # the next visit re-fetches with the new one instead of silently reusing stale
            # results (this is exactly what made a manually-added extension look ignored).
            [ -n "$sys_id" ] && rm -f "$CACHE_DIR/${sys_id}.list"
            UI_RENDER_NEEDED=1
            ;;
        select)
            play_sound "change"
            REPO_EDIT_LINE_NUM=$((REPO_INDEX + 1))
            local entry=$(sed -n "${REPO_EDIT_LINE_NUM}p" "$ARCHIVES_FILE")
            REPO_NEW_SYS_NAME=$(echo "$entry" | cut -d'|' -f1)
            REPO_NEW_SYS_ID=$(echo "$entry" | cut -d'|' -f3 | tr -d '\r')
            REPO_NEW_SYS_EXT=$(echo "$entry" | cut -d'|' -f4 | tr -d '\r')

            > "$CACHE_DIR/roms_folders.list"
            for dir in /mnt/SDCARD/Roms/*; do
                [ -d "$dir" ] || continue
                echo "${dir##*/}" >> "$CACHE_DIR/roms_folders.list"
            done
            sort -u "$CACHE_DIR/roms_folders.list" -o "$CACHE_DIR/roms_folders.list"

            if [ ! -s "$CACHE_DIR/roms_folders.list" ]; then
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:No folders found in /Roms!\n"
                render_ui
                sleep 1.5
            else
                FOLDER_SELECT_INDEX=0
                STATE="SELECT_REPO_FOLDER"
            fi
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            REPO_EDIT_LINE_NUM=$((REPO_INDEX + 1))
            local entry=$(sed -n "${REPO_EDIT_LINE_NUM}p" "$ARCHIVES_FILE")
            REPO_NEW_SYS_NAME=$(echo "$entry" | cut -d'|' -f1)
            REPO_NEW_SYS_FLD=$(echo "$entry" | cut -d'|' -f2)
            OSK_BUF=$(echo "$entry" | cut -d'|' -f3 | tr -d '\r')
            REPO_NEW_SYS_EXT=$(echo "$entry" | cut -d'|' -f4)
            
            STATE="OSK_INPUT"
            OSK_X=0; OSK_Y=0; OSK_UPPER=0
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_select_repo_folder() {
    local total_items=$(wc -l < "$CACHE_DIR/roms_folders.list")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local start_item=$((FOLDER_SELECT_INDEX - 4))
        [ "$start_item" -lt 0 ] && start_item=0
        local end_item=$((start_item + UI_MAX_ITEMS - 1))
        [ "$end_item" -ge "$total_items" ] && end_item=$((total_items - 1))
        if [ $((end_item - start_item + 1)) -lt $UI_MAX_ITEMS ] && [ "$total_items" -ge $UI_MAX_ITEMS ]; then
            start_item=$((end_item - UI_MAX_ITEMS + 1))
            [ "$start_item" -lt 0 ] && start_item=0
        fi

        local human_pos=$((FOLDER_SELECT_INDEX + 1))
        local scroll_pct=0
        [ "$total_items" -gt 1 ] && scroll_pct=$(( (FOLDER_SELECT_INDEX * 100) / (total_items - 1) ))

        local truncated_name=$(echo "$REPO_NEW_SYS_NAME" | cut -c 1-18)
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Target Folder for ${truncated_name}\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page   A/ Set   B/ Cancel  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$0, 1, 28) }" "$CACHE_DIR/roms_folders.list")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((FOLDER_SELECT_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            FOLDER_SELECT_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$FOLDER_SELECT_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            local new_folder=$(sed -n "$((FOLDER_SELECT_INDEX + 1))p" "$CACHE_DIR/roms_folders.list")
            sed -i "${REPO_EDIT_LINE_NUM}c\\${REPO_NEW_SYS_NAME}|${new_folder}|${REPO_NEW_SYS_ID}|${REPO_NEW_SYS_EXT}" "$ARCHIVES_FILE"
            [ -n "$REPO_NEW_SYS_ID" ] && rm -f "$CACHE_DIR/${REPO_NEW_SYS_ID}.list"
            STATE="MANAGE_REPOS"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MANAGE_REPOS"
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_osk_input() {
    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        local caps_txt="OFF"
        [ "$OSK_UPPER" -eq 1 ] && caps_txt="ON"
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Enter ID (Case-Sensitive!)\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Type  B/ Del  Sel/ Cancel  Start/ Save  R/ Caps [$caps_txt]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}OSK:$OSK_X:$OSK_Y:$OSK_BUF\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        up|down|left|right|R|R1)
            play_sound "change"
            handle_osk_navigation
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
        start|X)
            play_sound "confirm"
            STATE="VALIDATE_REPO"
            UI_RENDER_NEEDED=1
            ;;
        A)
            local char=""
            if [ $OSK_Y -eq 0 ]; then case $OSK_X in 0) char="a";; 1) char="b";; 2) char="c";; 3) char="d";; 4) char="e";; 5) char="f";; 6) char="g";; esac
            elif [ $OSK_Y -eq 1 ]; then case $OSK_X in 0) char="h";; 1) char="i";; 2) char="j";; 3) char="k";; 4) char="l";; 5) char="m";; 6) char="n";; esac
            elif [ $OSK_Y -eq 2 ]; then case $OSK_X in 0) char="o";; 1) char="p";; 2) char="q";; 3) char="r";; 4) char="s";; 5) char="t";; 6) char="u";; esac
            elif [ $OSK_Y -eq 3 ]; then case $OSK_X in 0) char="v";; 1) char="w";; 2) char="x";; 3) char="y";; 4) char="z";; 5) char="-";; 6) char="_";; esac
            elif [ $OSK_Y -eq 4 ]; then case $OSK_X in 0) char="0";; 1) char="1";; 2) char="2";; 3) char="3";; 4) char="4";; 5) char="5";; 6) char="6";; esac
            elif [ $OSK_Y -eq 5 ]; then
                if [ $OSK_X -eq 3 ]; then play_sound "change"; OSK_UPPER=$((1 - OSK_UPPER))
                elif [ $OSK_X -eq 4 ]; then play_sound "back"; OSK_BUF="${OSK_BUF%?}"
                elif [ $OSK_X -eq 5 ]; then play_sound "back"; STATE="MANAGE_REPOS"
                elif [ $OSK_X -eq 6 ]; then play_sound "confirm"; STATE="VALIDATE_REPO"
                else case $OSK_X in 0) char="7";; 1) char="8";; 2) char="9";; esac
                fi
            fi
            
            if [ -n "$char" ] && [ $OSK_X -lt 4 -o $OSK_Y -lt 5 ]; then
                play_sound "change"
                [ "$OSK_UPPER" -eq 1 ] && char=$(echo "$char" | tr 'a-z' 'A-Z')
                OSK_BUF="${OSK_BUF}${char}"
            fi
            UI_RENDER_NEEDED=1
            ;;
    esac
}

state_validate_repo() {
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Validating Repository...\nPROGRESS:50\n"
    render_ui

    if [ -z "$OSK_BUF" ]; then
        sed -i "${REPO_EDIT_LINE_NUM}c\\${REPO_NEW_SYS_NAME}|${REPO_NEW_SYS_FLD}||${REPO_NEW_SYS_EXT}" "$ARCHIVES_FILE"
        STATE="MANAGE_REPOS"
    else
        local resolved_id="$OSK_BUF"
        local meta_json=$(curl -s -L -k -m 10 "https://archive.org/metadata/${resolved_id}")

        if ! echo "$meta_json" | grep -q '"files"'; then
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Trying case-insensitive match...\nPROGRESS:75\n"
            render_ui

            local search_json=$(curl -s -L -k -m 10 -G \
                --data-urlencode "q=identifier:${OSK_BUF}" \
                --data-urlencode "fl[]=identifier" \
                --data-urlencode "rows=1" \
                --data-urlencode "output=json" \
                "https://archive.org/advancedsearch.php")
            resolved_id=$(echo "$search_json" | grep -o '"identifier":"[^"]*"' | head -n1 | cut -d'"' -f4)

            if [ -n "$resolved_id" ]; then
                meta_json=$(curl -s -L -k -m 10 "https://archive.org/metadata/${resolved_id}")
            fi
        fi

        if [ -n "$resolved_id" ] && echo "$meta_json" | grep -q '"files"'; then
            if echo "$meta_json" | grep -q '"access-restricted-item":"true"'; then
                # Some archive.org items require a logged-in/borrowed session to download
                # their files (their file listing shows filenames but no download links,
                # and direct downloads return 401). RomManager has no login support, so
                # these repos can never actually download - reject them here instead of
                # letting the user hit a confusing "Connection Failed" later.
                play_sound "back"
                build_theme
                UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Repo is Restricted (needs archive.org login)!\n"
                render_ui
                sleep 2.5
                STATE="OSK_INPUT"
                UI_RENDER_NEEDED=1
                return
            fi
            sed -i "${REPO_EDIT_LINE_NUM}c\\${REPO_NEW_SYS_NAME}|${REPO_NEW_SYS_FLD}|${resolved_id}|${REPO_NEW_SYS_EXT}" "$ARCHIVES_FILE"
            STATE="MANAGE_REPOS"
        else
            play_sound "back"
            build_theme
            UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Invalid Repo! No ROMs found.\n"
            render_ui
            sleep 2
            STATE="OSK_INPUT"
        fi
    fi
    UI_RENDER_NEEDED=1
}

state_scrape_art() {
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scanning SD Card for missing art...\nART:NULL\n"
    render_ui

    > "$CACHE_DIR/missing_art.txt"
    update_local_consoles

    for folder in $(cat "$CACHE_DIR/local_consoles.cache" | cut -d'|' -f1); do
        local libretro_sys=$(get_libretro_system "$folder")
        [ -z "$libretro_sys" ] && continue
        
        local target_dir="/mnt/SDCARD/Roms/$folder"
        local ignore="^\.|miyoogames\.xml|\.db$|\.png$|\.jpg$|\.txt$|\.json$|^Imgs$"
        
        ls -1 "$target_dir" 2>/dev/null | grep -ivE "$ignore" | while read -r rom_path; do
            local file_name="${rom_path##*/}"
            local base_name="${file_name%.*}"
            
            if [ ! -s "$target_dir/Imgs/${base_name}.png" ]; then
                echo "$folder|${base_name}|${libretro_sys}" >> "$CACHE_DIR/missing_art.txt"
            fi
        done
    done

    local total_missing=$(wc -l < "$CACHE_DIR/missing_art.txt")
    
    if [ "$total_missing" -eq 0 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:All box art is already up to date!\n"
        render_ui
        sleep 2
        STATE="MAIN_MENU"
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
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Found $total_items Missing Covers\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:<-/-> Page   A/ Start Scrape   B/ Cancel  [$human_pos/$total_items]\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}SCROLLBAR:$scroll_pct\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"

        local items=$(awk -F'|' "NR>=$((start_item + 1)) && NR<=$((end_item + 1)) { print substr(\$2, 1, 28) }" "$CACHE_DIR/missing_art.txt")
        while read -r name; do
            [ -n "$name" ] && UI_FRAME_BUF="${UI_FRAME_BUF}ITEM:${name}\n"
        done <<EOF
$items
EOF

        local rel=$((MISSING_INDEX - start_item))
        UI_FRAME_BUF="${UI_FRAME_BUF}HIGHLIGHT:$rel\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        down|up|right|left)
            play_sound "change"
            MISSING_INDEX=$(update_selection "$KEY" "$total_items" "$UI_MAX_ITEMS" "$MISSING_INDEX")
            UI_RENDER_NEEDED=1
            ;;
        A)
            play_sound "change"
            STATE="DO_SCRAPE"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
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
        
        sed -i "1i$base_name" "$CACHE_DIR/scraped_history.txt"
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
    build_theme
    UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Art Scrape Complete!\nPROGRESS:100\n"
    render_ui
    sleep 2
    STATE="MAIN_MENU"
    UI_RENDER_NEEDED=1
}

state_prefetch_covers_scan() {
    local total_repos=$(awk -F'|' '$3!=""' "$ARCHIVES_FILE" | wc -l)
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
        while IFS='|' read -r sys_name sys_fld sys_id sys_ext; do
            [ -f /tmp/scan_cancel ] && break
            sys_id=$(echo "$sys_id" | tr -d '\r')
            [ -z "$sys_id" ] && continue

            local libretro_sys=$(get_libretro_system "$sys_fld")
            [ -z "$libretro_sys" ] && continue

            repo_num=$((repo_num + 1))
            echo "${repo_num}|${sys_name}" > "$CACHE_DIR/scan_progress.txt"

            local list_file="$CACHE_DIR/${sys_id}.list"
            if [ ! -s "$list_file" ]; then
                fetch_repo_list "$sys_id" "$sys_ext" "$list_file" "$sys_fld"
            fi
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
        done < "$ARCHIVES_FILE"

        rm -f /tmp/scan_active
    ) &
    local worker_pid=$!

    (
        while [ -f /tmp/scan_active ]; do
            k=$(./bin/getkey)
            if [ "$k" = "B" ]; then
                touch /tmp/scan_cancel
                break
            fi
        done
    ) &
    local key_pid=$!

    while [ -f /tmp/scan_active ]; do
        local progress=$(cat "$CACHE_DIR/scan_progress.txt" 2>/dev/null)
        local repo_num=$(echo "$progress" | cut -d'|' -f1)
        local repo_name=$(echo "$progress" | cut -d'|' -f2 | cut -c 1-24)
        [ -z "$repo_num" ] && repo_num=0

        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scanning [$repo_num/$total_repos]: ${repo_name}\nART:NULL\nFOOTER:B/ Cancel\n"
        render_ui
        sleep 0.2
    done

    kill -9 $key_pid 2>/dev/null
    local was_cancelled=0
    [ -f /tmp/scan_cancel ] && was_cancelled=1
    rm -f /tmp/scan_active /tmp/scan_cancel

    if [ "$was_cancelled" -eq 1 ]; then
        play_sound "back"
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Scan Cancelled!\n"
        render_ui
        sleep 1.5
        STATE="MAIN_MENU"
    elif [ -s "$CACHE_DIR/prefetch_covers.txt" ]; then
        sort -u "$CACHE_DIR/prefetch_covers.txt" -o "$CACHE_DIR/prefetch_covers.txt"
        STATE="CONFIRM_PREFETCH_COVERS"
    else
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:All previews already cached!\n"
        render_ui
        sleep 2
        STATE="MAIN_MENU"
    fi
    UI_RENDER_NEEDED=1
}

state_confirm_prefetch_covers() {
    local total_items=$(wc -l < "$CACHE_DIR/prefetch_covers.txt")
    [ "$total_items" -le 0 ] && total_items=1

    if [ "$UI_RENDER_NEEDED" -eq 1 ]; then
        build_theme
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Found $total_items Previews to Fetch\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}FOOTER:A/ Start Download   B/ Cancel\n"
        UI_FRAME_BUF="${UI_FRAME_BUF}ART:NULL\n"
        render_ui
    fi

    get_key || return

    case "$KEY" in
        A)
            play_sound "change"
            STATE="DO_PREFETCH_COVERS"
            UI_RENDER_NEEDED=1
            ;;
        B)
            play_sound "back"
            STATE="MAIN_MENU"
            UI_RENDER_NEEDED=1
            ;;
    esac
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

            sed -i "1i$base_name" "$CACHE_DIR/prefetch_history.txt"
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

    (
        while [ -f /tmp/prefetch_active ]; do
            k=$(./bin/getkey)
            if [ "$k" = "B" ]; then
                touch /tmp/prefetch_cancel
                break
            fi
        done
    ) &
    local key_pid=$!
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
            kill -9 $worker_pid 2>/dev/null
            was_cancelled=1
            break
        fi

        sleep 0.2
    done

    kill -9 $key_pid 2>/dev/null
    rm -f /tmp/prefetch_active /tmp/prefetch_cancel

    build_theme
    if [ "$was_cancelled" -eq 1 ]; then
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Preview Prefetch Cancelled!\n"
    else
        play_sound "confirm"
        UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Preview Prefetch Finished!\nPROGRESS:100\n"
    fi
    render_ui
    sleep 1.5

    STATE="MAIN_MENU"
    UI_RENDER_NEEDED=1
}

# ==========================================
# 7. BOOT SEQUENCE
# ==========================================

initialize_database
init_audio
start_bgm

if [ -f "./background.png" ]; then
    ./bin/show -i ./background.png -q
    sleep 0.5
fi

build_theme
UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:Booting System...\nART:NULL\n"
render_ui

rm -f "$CACHE_DIR/local_consoles.cache" 
update_local_consoles

total_sys=$(wc -l < "$CACHE_DIR/local_consoles.cache" 2>/dev/null || echo 0)
total_roms=0
while read -r fld; do
    c=$(echo "$fld" | cut -d'|' -f2)
    total_roms=$((total_roms + c))
done < "$CACHE_DIR/local_consoles.cache"

build_theme
UI_FRAME_BUF="${UI_FRAME_BUF}STATUS:System Ready\nITEM:Installed ROMs: $total_roms\nITEM:Systems Found: $total_sys\nITEM:Cache Status: Healthy\nITEM:\nITEM:Made by pluscloud (and updated by brenonsc :p)\nART:NULL\nHIGHLIGHT:-1\n"
render_ui
sleep 1.5

UI_RENDER_NEEDED=1 

# ==========================================
# 8. MAIN DISPATCH LOOP
# ==========================================
while true
do
    case "$STATE" in
        MAIN_MENU) state_main_menu ;;
        DL_CONSOLES) state_dl_consoles ;;
        FETCH_XML) state_fetch_xml ;;
        DL_GAMES) state_dl_games ;;
        CONFIRM_DOWNLOAD) state_confirm_download ;;
        INST_CONSOLES) state_inst_consoles ;;
        INST_GAMES) state_inst_games ;;
        FAVORITES) state_favorites ;;
        SETTINGS) state_settings ;;
        SELECT_PREVIEW_REPO) state_select_preview_repo ;;
        CONFIRM_DELETE_PREVIEWS) state_confirm_delete_previews ;;
        CONFIRM_SINGLE_SCRAPE) state_confirm_single_scrape ;;
        CONFIRM_DELETE) state_confirm_delete ;;
        SEARCH_GAMES) state_search_games ;;
        RECENT_DOWNLOADS) state_recent_downloads ;;
        MANAGE_REPOS) state_manage_repos ;;
        SELECT_REPO_FOLDER) state_select_repo_folder ;;
        OSK_INPUT) state_osk_input ;;
        VALIDATE_REPO) state_validate_repo ;;
        SCRAPE_ART) state_scrape_art ;;
        CONFIRM_SCRAPE) state_confirm_scrape ;;
        DO_SCRAPE) state_do_scrape ;;
        PREFETCH_COVERS_SCAN) state_prefetch_covers_scan ;;
        CONFIRM_PREFETCH_COVERS) state_confirm_prefetch_covers ;;
        DO_PREFETCH_COVERS) state_do_prefetch_covers ;;
        *) STATE="MAIN_MENU"; UI_RENDER_NEEDED=1 ;;
    esac
done