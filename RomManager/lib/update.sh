# RomManager updates from GitHub (sourced by launch.sh).
#
# The newest release of UPDATE_REPO is looked up with GitHub's API. Its first .zip
# download (RomManager/... inside, like the release zips) is fetched to caches/update,
# checked against the sha256 GitHub lists for it, unpacked and copied over the app.
# settings.ini, repos.txt and caches/ are never touched. Each file is copied to a new
# name and then renamed over the old one, so the running script and programs keep
# their old copies until the app restarts (exit code 75: the supervisor at the top of
# launch.sh starts it again straight away).
#
# Settings > Auto Update (on by default) looks at most once a day, in the background,
# when Wi-Fi is on, downloads a new version and installs it at the next start - no
# questions asked. Settings > Check for Updates does it all at once, after asking.

UPDATE_REPO="Plus-Cloud/RomManager"
APP_DIR="/mnt/SDCARD/App/RomManager"
UPDATE_INFO="$CACHE_DIR/update_available.txt"   # version|zip url|size|sha256:...
UPDATE_DIR="$CACHE_DIR/update"
UPDATE_RESTART_CODE=75

# Is version $1 newer than $2? ("v2.1.0" > "2.0", "2.10" > "2.9")
version_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        sub(/^[vV]/, "", a); sub(/^[vV]/, "", b)
        na = split(a, x, "."); nb = split(b, y, ".")
        m = (na > nb) ? na : nb
        for (i = 1; i <= m; i++) {
            p = x[i] + 0; q = y[i] + 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

# Asks GitHub for the newest release. Returns 0 (and writes UPDATE_INFO) when it's
# newer than this version, 1 when this is the newest, 2 when GitHub couldn't be read.
update_check() {
    local json="$CACHE_DIR/.update.json" info
    rm -f "$json"
    curl -s -k -L --fail --connect-timeout 10 -m 30 -A "RomManager/$RM_VERSION" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$UPDATE_REPO/releases/latest" -o "$json" </dev/null
    if [ ! -s "$json" ]; then
        rm -f "$json"
        return 2
    fi
    : > "$CACHE_DIR/.update_checked"
    # The fields wanted, one per line (works whether the reply is spread over lines
    # or not). In each asset "name" comes first and "browser_download_url" last.
    info=$(grep -oE '"(tag_name|name|size|digest|browser_download_url)": *("[^"]*"|[0-9]+)' "$json" | awk '
        {
            key = $0; sub(/^"/, "", key); sub(/".*$/, "", key)
            val = $0; sub(/^"[^"]*": */, "", val); gsub(/"/, "", val)
        }
        key == "tag_name" && tag == "" { tag = val }
        key == "name" { size = ""; digest = "" }
        key == "size" { size = val }
        key == "digest" { digest = val }
        key == "browser_download_url" && url == "" && tolower(val) ~ /\.zip$/ { url = val; s = size; d = digest }
        END { if (tag != "" && url != "") print tag "|" url "|" s "|" d }')
    rm -f "$json"
    [ -n "$info" ] || return 2
    if version_newer "${info%%|*}" "$RM_VERSION"; then
        printf '%s\n' "$info" > "$UPDATE_INFO"
        return 0
    fi
    rm -f "$UPDATE_INFO"
    return 1
}

# Is a newer version known about? Sets UPD_VERSION (without the "v"), UPD_URL,
# UPD_SIZE and UPD_DIGEST.
update_pending() {
    [ -s "$UPDATE_INFO" ] || return 1
    IFS='|' read -r UPD_VERSION UPD_URL UPD_SIZE UPD_DIGEST < "$UPDATE_INFO"
    UPD_VERSION=${UPD_VERSION#[vV]}
    [ -n "$UPD_URL" ] && version_newer "$UPD_VERSION" "$RM_VERSION" && return 0
    # (left over from before this version was installed)
    rm -f "$UPDATE_INFO"
    return 1
}

# At start-up (Auto Update on): look for an update in the background, at most once a
# day, and download it straight away. It's installed the next time RomManager starts
# (update_apply_staged), so nothing restarts while it's being used.
update_auto_check() {
    [ "$AUTO_UPDATE" = "1" ] || return
    wifi_on || return
    [ -s "$UPDATE_DIR/ready" ] && return
    if ! update_pending; then
        local last=$(stat -c %Y "$CACHE_DIR/.update_checked" 2>/dev/null || echo 0)
        [ $(( $(date +%s) - last )) -lt 72000 ] && return
    fi
    # (a download cut short last time is simply tried again)
    (
        update_pending || update_check || exit 0
        update_pending || exit 0
        # (a version skipped from Check for Updates stays skipped)
        [ "$UPD_VERSION" = "$UPDATE_SKIP" ] && exit 0
        update_download && echo "$UPD_VERSION" > "$UPDATE_DIR/ready"
    ) </dev/null >/dev/null 2>&1 &
}

# At start-up: installs an update downloaded last time. Returns 0 when it did (the
# app must then restart), 1 when there was nothing to install or it failed.
update_apply_staged() {
    [ -s "$UPDATE_DIR/ready" ] && [ -s "$UPDATE_DIR/root" ] || return 1
    UPD_VERSION=$(cat "$UPDATE_DIR/ready")
    if ! version_newer "$UPD_VERSION" "$RM_VERSION"; then
        rm -rf "$UPDATE_DIR"
        return 1
    fi
    if update_install; then
        echo "=== $(date) installed update $UPD_VERSION" >&2
        return 0
    fi
    echo "=== $(date) update $UPD_VERSION could not be installed" >&2
    rm -rf "$UPDATE_DIR"
    return 1
}

# Unpacks zip $1 into folder $2, with whichever unzipper the system has
update_unzip() {
    local z
    for z in unzip "busybox unzip"; do
        rm -rf "$2"; mkdir -p "$2"
        $z -o -q "$1" -d "$2" </dev/null >/dev/null 2>&1 && return 0
    done
    for z in /mnt/SDCARD/.tmp_update/bin/7z 7z 7za; do
        rm -rf "$2"; mkdir -p "$2"
        "$z" x -y -o"$2" "$1" </dev/null >/dev/null 2>&1 && return 0
    done
    return 1
}

# Downloads, checks and unpacks UPD_URL (run under run_with_spinner). On failure the
# reason (download|corrupt|unzip|badzip) is left in $UPDATE_DIR.status.
update_download() {
    local zip="$UPDATE_DIR/update.zip" x="$UPDATE_DIR/files" root="" d
    rm -rf "$UPDATE_DIR" "$UPDATE_DIR.status"
    mkdir -p "$UPDATE_DIR"
    if ! curl -s -k -L --fail --retry 2 --connect-timeout 15 -m 900 -A "RomManager/$RM_VERSION" \
        "$UPD_URL" -o "$zip" </dev/null || [ ! -s "$zip" ]; then
        echo download > "$UPDATE_DIR.status"
        return 1
    fi
    case "$UPD_DIGEST" in
        sha256:*)
            if command -v sha256sum >/dev/null 2>&1; then
                d=$(sha256sum "$zip" | cut -d' ' -f1)
                [ "$d" = "${UPD_DIGEST#sha256:}" ] || { echo corrupt > "$UPDATE_DIR.status"; return 1; }
            fi
            ;;
    esac
    update_unzip "$zip" "$x" || { echo unzip > "$UPDATE_DIR.status"; return 1; }
    rm -f "$zip"
    # The app's files: in RomManager/ (as in the release zips), or at the top
    if [ -f "$x/RomManager/launch.sh" ]; then
        root="$x/RomManager"
    elif [ -f "$x/launch.sh" ]; then
        root="$x"
    else
        for d in "$x"/*/; do
            [ -f "${d}launch.sh" ] && { root="${d%/}"; break; }
        done
    fi
    if [ -z "$root" ] || [ ! -f "$root/config.json" ] || ! sh -n "$root/launch.sh" 2>/dev/null; then
        echo badzip > "$UPDATE_DIR.status"
        return 1
    fi
    echo "$root" > "$UPDATE_DIR/root"
    return 0
}

# Copies the unpacked update over the app. launch.sh goes last, so an update cut short
# (SD card full) still starts the old, working script.
update_install() {
    local root rel failed=0
    root=$(cat "$UPDATE_DIR/root" 2>/dev/null)
    [ -n "$root" ] && [ -f "$root/launch.sh" ] || return 1
    # Room for the new files first, so it doesn't stop halfway
    local need=$(du -sk "$root" 2>/dev/null | cut -f1) free=$(free_space_kb /mnt/SDCARD)
    case "$need$free" in ''|*[!0-9]*) ;; *) [ "$free" -gt $((need + 1024)) ] || return 1 ;; esac
    (cd "$root" && find . -type f) > "$UPDATE_DIR/list"
    while IFS= read -r rel; do
        rel=${rel#./}
        case "$rel" in launch.sh|settings.ini|repos.txt|archives.txt|caches/*) continue ;; esac
        mkdir -p "$APP_DIR/$(dirname "$rel")"
        if cp "$root/$rel" "$APP_DIR/$rel.new" 2>/dev/null; then
            mv -f "$APP_DIR/$rel.new" "$APP_DIR/$rel"
        else
            rm -f "$APP_DIR/$rel.new"
            failed=1
        fi
    done < "$UPDATE_DIR/list"
    [ "$failed" = "0" ] || return 1
    cp "$root/launch.sh" "$APP_DIR/launch.sh.new" && mv -f "$APP_DIR/launch.sh.new" "$APP_DIR/launch.sh" || return 1
    chmod +x "$APP_DIR"/bin/* 2>/dev/null
    echo "$UPD_VERSION" > "$CACHE_DIR/.just_updated"
    rm -rf "$UPDATE_DIR" "$UPDATE_INFO"
    return 0
}

update_error_message() {
    case "$(cat "$UPDATE_DIR.status" 2>/dev/null)" in
        corrupt) echo "The update didn't download properly - try again" ;;
        unzip) echo "Couldn't unpack the update" ;;
        badzip) echo "That release doesn't look like RomManager" ;;
        *) echo "Couldn't download the update - check Wi-Fi" ;;
    esac
}

# The whole thing, from Settings or the home screen. $1 = check: ask GitHub first
# (otherwise the update found in the background is offered).
update_flow() {
    if [ "$1" = "check" ]; then
        need_wifi || return
        run_with_spinner "Checking for updates..." update_check
        case $? in
            130) play_sound "back"; return ;;
            1) play_sound "confirm"; toast ok "You have the newest version ($RM_VERSION)"; return ;;
            2) play_sound "back"; toast err "Couldn't reach GitHub - try again later"; return ;;
        esac
    fi
    update_pending || return
    local size=""
    case "$UPD_SIZE" in ''|*[!0-9]*) ;; *) size=" ($(format_size "$UPD_SIZE"))" ;; esac
    ask_dialog "Update available" "RomManager $UPD_VERSION$size is ready." "You have $RM_VERSION. Your settings, repos" "and games are kept." -- "Update now" "Later" "Skip this version"
    case "$DIALOG_RESULT" in
        0) ;;
        2) UPDATE_SKIP="$UPD_VERSION"; save_settings; return ;;
        *) return ;;
    esac
    # (already downloaded in the background: just install it)
    if [ "$(cat "$UPDATE_DIR/ready" 2>/dev/null)" != "$UPD_VERSION" ] || [ ! -s "$UPDATE_DIR/root" ]; then
        need_wifi || return
        if dl_worker_alive; then
            play_sound "back"
            toast info "Wait for your downloads to finish first"
            return
        fi
        run_with_spinner "Downloading RomManager $UPD_VERSION..." update_download
        case $? in
            0) ;;
            130) rm -rf "$UPDATE_DIR"; play_sound "back"; return ;;
            *) play_sound "back"; toast err "$(update_error_message)"; rm -rf "$UPDATE_DIR"; return ;;
        esac
    fi
    busy_frame "Installing RomManager $UPD_VERSION..."
    if ! update_install; then
        rm -rf "$UPDATE_DIR"
        play_sound "back"
        ask_dialog "Update failed" "Not every file could be copied (is the SD" "card full?). RomManager will keep working;" "try the update again later." -- "OK"
        return
    fi
    play_sound "confirm"
    busy_frame "Updated - restarting..."
    sleep 1
    save_spot
    dl_worker_stop
    stop_renderer
    stop_audio
    stop_input
    exit "$UPDATE_RESTART_CODE"
}
