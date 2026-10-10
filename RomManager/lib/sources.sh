# RomManager repository sources.
# Sourced by launch.sh - uses its CACHE_DIR, ROMS_DIR and get_console_name/get_auto_extensions.
#
# Repos live in repos.txt (editable on a PC), one per line:
#     CONSOLE | SOURCE | FORMAT
# CONSOLE is an Onion ROM folder (GBA, PS, ...) or * for a multi-console pack.
# SOURCE is an archive.org item ID, an http(s):// folder, or an ftp:// folder.
# FORMAT (optional) adds file extensions to look for, e.g. "chd" or "iso|cso".
#
# Each source is read into an index of every file it holds - "path|size|url" lines,
# path relative to the source and readable (not %-encoded). A console's game list is
# then built from the indexes of every repo assigned to it.

REPOS_FILE="repos.txt"
SOURCES_DIR="$CACHE_DIR/sources"
PACKS_DIR="$CACHE_DIR/packs"
mkdir -p "$SOURCES_DIR" "$PACKS_DIR"

# archive.org login (Settings): the session cookies live in a curl cookie file marked
# for archive.org only, so they're never sent to other servers. IA_AUTH goes in every
# curl call that can reach archive.org (the path has no spaces, so it's safe unquoted).
IA_COOKIE_FILE="$CACHE_DIR/ia_cookies.txt"
ia_refresh_auth() {
    IA_AUTH=""
    IA_USER=""
    if [ -s "$IA_COOKIE_FILE" ]; then
        IA_AUTH="-b $IA_COOKIE_FILE"
        IA_USER=$(cat "$CACHE_DIR/ia_user.txt" 2>/dev/null)
    fi
}
ia_refresh_auth

# Logs in with an email and password ($1 $2). On success saves the cookies and the
# screen name and returns 0; otherwise prints archive.org's reason and returns 1.
ia_login() {
    local reply
    reply=$(curl -s -k --connect-timeout 10 -m 30 -X POST "https://archive.org/services/xauthn/?op=login" \
        --data-urlencode "email=$1" --data-urlencode "password=$2")
    if [ -z "$reply" ]; then
        echo "no_connect"
        return 1
    fi
    if ! echo "$reply" | grep -q '"success":true'; then
        echo "$reply" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4
        return 1
    fi
    local user=$(echo "$reply" | grep -o '"logged-in-user":"[^"]*"' | cut -d'"' -f4 | sed 's#\\/#/#g')
    local sig=$(echo "$reply" | grep -o '"logged-in-sig":"[^"]*"' | cut -d'"' -f4 | sed 's#\\/#/#g')
    local name=$(echo "$reply" | grep -o '"screenname":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$user" ] || [ -z "$sig" ]; then
        echo "unexpected"
        return 1
    fi
    {
        echo "# Netscape HTTP Cookie File"
        printf '.archive.org\tTRUE\t/\tFALSE\t0\tlogged-in-user\t%s\n' "$user"
        printf '.archive.org\tTRUE\t/\tFALSE\t0\tlogged-in-sig\t%s\n' "$sig"
    } > "$IA_COOKIE_FILE"
    echo "${name:-$1}" > "$CACHE_DIR/ia_user.txt"
    ia_refresh_auth
    return 0
}

ia_logout() {
    rm -f "$IA_COOKIE_FILE" "$CACHE_DIR/ia_user.txt"
    ia_refresh_auth
}

# Ask servers for compressed responses when this curl can decode them (file lists
# shrink 4-13x). Older curls without zlib would fail on --compressed, so check first.
CURL_COMPRESS=""
curl -V 2>/dev/null | grep -qi 'libz' && CURL_COMPRESS="--compressed"

# awk helpers shared by the parsers. Run with LC_ALL=C so text is handled as bytes.
AWK_URL_FUNCS='
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function urldecode(s,    r, i, c) {
    r = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "%" && i + 2 <= length(s) && hexval(substr(s, i + 1, 1)) >= 0 && hexval(substr(s, i + 2, 1)) >= 0) {
            r = r sprintf("%c", hexval(substr(s, i + 1, 1)) * 16 + hexval(substr(s, i + 2, 1)))
            i += 2
        } else r = r c
    }
    return r
}
function urlencode(s,    r, i, c) {
    if (!ord_ready) { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i; ord_ready = 1 }
    r = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c ~ /[A-Za-z0-9._~\/-]/) r = r c
        else r = r sprintf("%%%02X", ord[c])
    }
    return r
}'

# ------------------------------------------------------------------
# Repo list
# ------------------------------------------------------------------

# Prints repos as "CONSOLE|SOURCE|FORMAT", skipping comments and blank lines.
repos_list() {
    [ -f "$REPOS_FILE" ] || return
    tr -d '\r' < "$REPOS_FILE" | awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^[ \t]*#/ || NF < 2 { next }
        {
            c = trim($1); s = trim($2); f = trim($3)
            if (c == "" || s == "") next
            if (c != "*") c = toupper(c)
            print c "|" s "|" f
        }'
}

repos_write_header() {
    cat > "$REPOS_FILE" <<'EOF'
# RomManager repositories - one per line:   CONSOLE | SOURCE | FORMAT
#
#   CONSOLE  Onion ROM folder name (GBA, PS, FC, SFC, MD, ...) or * for a pack that
#            holds several consoles in subfolders (they're detected automatically).
#   SOURCE   an archive.org item ID (the part after archive.org/details/), or a folder:
#              https://example.com/roms/gba/
#              ftp://user:password@192.168.1.20/roms/
#   FORMAT   optional: extra file extensions to include, e.g.  chd  or  iso|cso
#
# A console can have several repos - their games are merged into one list.
# Lines starting with # are ignored. You can edit this file on a PC.

EOF
}

# Creates repos.txt from the old archives.txt (one archive.org ID per console).
migrate_archives() {
    [ -f "$REPOS_FILE" ] && return
    repos_write_header
    [ -f "archives.txt" ] || return
    tr -d '\r' < archives.txt | awk -F'|' '$3 != "" { print $2 " | " $3 (($4 != "") ? " | " $4 : "") }' >> "$REPOS_FILE"
}

# Earlier versions used some ROM folder names Onion doesn't (SMS instead of MS, ...),
# so games went to folders Onion never shows. Renames them in repos.txt and saved packs.
CONSOLE_RENAMES='SMS=MS ATARI2600=ATARI ATARI7800=SEVENTYEIGHTHUNDRED FIFTYTWO00=FIFTYTWOHUNDRED ATARILYNX=LYNX 32X=THIRTYTWOX POKEFAMI=POKE C64=COMMODORE TIC80=TIC NGPC=NGP WSC=WS MSX2=MSX'
migrate_console_codes() {
    local f
    for f in "$REPOS_FILE" "$PACKS_DIR"/*.map; do
        [ -f "$f" ] || continue
        awk -F'|' -v r="$CONSOLE_RENAMES" '
            BEGIN { n = split(r, p, " "); for (i = 1; i <= n; i++) { split(p[i], kv, "="); ren[kv[1]] = kv[2] } }
            function fix(s,    t, lead, trail) {
                t = s; lead = t; sub(/[^ \t].*$/, "", lead); trail = t; sub(/^.*[^ \t]/, "", trail)
                gsub(/^[ \t]+|[ \t]+$/, "", t)
                return (t in ren) ? lead ren[t] trail : s
            }
            /^[ \t]*#/ || NF < 2 { print; next }
            {
                if (FILENAME ~ /\.map$/) {
                    $2 = fix($2)
                    # Consoles Onion has no emulator for on the Mini: skip them in packs
                    if ($2 == "N64" || $2 == "DC" || $2 == "PSP") $2 = "-"
                }
                else $1 = fix($1)
                out = $1; for (i = 2; i <= NF; i++) out = out "|" $i; print out
            }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    done
}

repos_add() {
    printf '%s | %s%s\n' "$1" "$2" "${3:+ | $3}" >> "$REPOS_FILE"
}

# Replaces repo number $1 (1-based, counting only real repo lines) with new values,
# or deletes it when $2 is empty. Comments are kept.
repos_set() {
    local n="$1" console="$2" source="$3" format="$4"
    awk -v n="$n" -v line="$console | $source${format:+ | $format}" -v del="$([ -z "$console" ] && echo 1)" '
        /^[ \t]*#/ || NF == 0 || $0 !~ /\|/ { print; next }
        { k++ }
        k == n { if (!del) print line; next }
        { print }' "$REPOS_FILE" > "$REPOS_FILE.tmp" && mv "$REPOS_FILE.tmp" "$REPOS_FILE"
}

# ------------------------------------------------------------------
# Source helpers
# ------------------------------------------------------------------

source_type() {
    case "$1" in
        http://*|https://*) echo http ;;
        ftp://*) echo ftp ;;
        *) echo archive ;;
    esac
}

source_key() {
    printf '%s' "$1" | cksum | cut -d' ' -f1
}

# (.idx2: indexes now also mark zips that hold a whole console - older .idx files
# without that are simply rebuilt.)
source_index_file() {
    echo "$SOURCES_DIR/$(source_key "$1").idx2"
}

# Short name for menus: the archive ID, or host/last-folder for web and FTP.
source_label() {
    case "$1" in
        http://*|https://*|ftp://*)
            # Drop the scheme and any user:password@, keep host and last folder
            echo "$1" | sed -e 's#^[a-z]*://##' -e 's#^[^@/]*@##' -e 's#/*$##' \
                | awk -F/ '{ print (NF > 1) ? $1 "/" $NF : $1 }'
            ;;
        *) echo "$1" ;;
    esac
}

# Turns curl's exit code / HTTP status for a source into a status word for
# source_status_message.
curl_status() {
    local rc="$1" http="$2" type="$3"
    case "$rc" in
        0) ;;
        6) echo "no_host"; return ;;
        7) echo "no_connect"; return ;;
        28) echo "timeout"; return ;;
        67) echo "login"; return ;;
        9|78) echo "not_found"; return ;;
        *) echo "error|curl $rc"; return ;;
    esac
    [ "$type" = "ftp" ] && return
    case "$http" in
        2*) ;;
        404) echo "not_found" ;;
        401|403) echo "login" ;;
        *) echo "error|HTTP $http" ;;
    esac
}

source_status_message() {
    local status=$(cut -d'|' -f1 "$1" 2>/dev/null)
    local detail=$(cut -d'|' -f2- "$1" 2>/dev/null)
    case "$status" in
        no_host) echo "Server not found! Check the address / Wi-Fi." ;;
        no_connect) echo "Can't reach the server (is it running?)" ;;
        timeout) echo "Server took too long. Try again." ;;
        login) echo "Server wants a login (archive.org: log in under Settings)." ;;
        not_found) echo "Folder or repo not found on the server!" ;;
        restricted) echo "Repo needs an archive.org login (Settings)." ;;
        dark) echo "Repo was taken down by archive.org!" ;;
        collection) echo "That's a collection - use one of its items." ;;
        no_listing) echo "No file list at that address." ;;
        empty) echo "No files found in that repo!" ;;
        no_matches) echo "No games for this system. Repo has: $detail" ;;
        error) echo "Server error ($detail). Try later." ;;
        *) echo "Couldn't read that repo." ;;
    esac
}

# ------------------------------------------------------------------
# Index builders: write "path|size|url" lines to $2, a status word to $3 on failure
# ------------------------------------------------------------------

# archive.org: one request to the metadata API's file list - much faster than the
# HTML download page, and it includes sizes and files inside subfolders.
# A .zip holding several files gets their count as a 4th field: some items pack a
# whole console into one zip ("Nintendo - Game Boy.zip" with 150 games), and
# archive.org can list and serve the files inside it one by one (see index_zip).
index_archive() {
    local id="$1" out="$2" status="$3" tmp="$2.json"
    curl $IA_AUTH -s -L -k $CURL_COMPRESS --connect-timeout 15 -m 90 "https://archive.org/metadata/$id/files" -o "$tmp"
    local rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
        curl_status "${rc:-7}" 000 archive > "$status"
        [ -s "$status" ] || echo "no_connect" > "$status"
        rm -f "$tmp"
        return 1
    fi
    if grep -q "Couldn't locate item" "$tmp"; then
        echo "not_found" > "$status"; rm -f "$tmp"; return 1
    fi
    if grep -q '"error"' "$tmp"; then
        echo "dark" > "$status"; rm -f "$tmp"; return 1
    fi

    # Split the one-line JSON into one object per line, then pick out the fields.
    # Only "original" files - archive.org adds derived copies and metadata files.
    tr '{' '\n' < "$tmp" | LC_ALL=C awk -v base="https://archive.org/download/$id/" "$AWK_URL_FUNCS"'
        {
            line = $0
            gsub(/\\\\/, "\002", line)
            gsub(/\\"/, "\001", line)
            n = split(line, f, "\"")
            name = ""; size = 0; src = ""; count = 0
            for (i = 2; i + 2 <= n; i++) {
                if (f[i + 1] != ":") continue
                if (f[i] == "name") name = f[i + 2]
                else if (f[i] == "size") size = f[i + 2]
                else if (f[i] == "source") src = f[i + 2]
                else if (f[i] == "filecount") count = f[i + 2] + 0
            }
            if (name == "" || src != "original") next
            if (name ~ /^history\/files\//) next   # old versions of changed files, kept by archive.org
            gsub(/\001/, "\"", name); gsub(/\002/, "\\", name); gsub(/\\\//, "/", name)
            gsub(/\|/, "_", name)
            if (count > 1 && tolower(name) ~ /\.zip$/)
                print name "|" (size + 0) "|" base urlencode(name) "|" count
            else
                print name "|" (size + 0) "|" base urlencode(name)
        }' > "$out"
    rm -f "$tmp"
    [ -s "$out" ] || { echo "empty" > "$status"; return 1; }
    return 0
}

# Files inside an archive.org zip, from its contents page (<zip url>/). $1: the zip's
# URL, $2: its path in the repo (prefixed to the inner names), $3: output, cached for
# as long as repo indexes are.
index_zip() {
    local url="$1" path="$2" out="$3"
    if [ -s "$out" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$out" 2>/dev/null || echo 0) ))
        [ "$age" -lt $((REPO_CACHE_DAYS * 86400)) ] && return 0
    fi
    local page="$out.page"
    curl $IA_AUTH -s -L -k $CURL_COMPRESS --connect-timeout 15 -m 90 "$url/" -o "$page" || { rm -f "$page"; return 1; }
    # Rows look like: <a href="//archive.org/download/ID/Pack.zip/Game%20(USA).zip">...</a>
    #                 <td>...<td>date<td id="size">67287</tr>
    tr -d '\r' < "$page" | LC_ALL=C awk -v path="$path/" "$AWK_URL_FUNCS"'
        { s = s $0 }
        END {
            n = split(s, rows, "<tr>")
            for (r = 2; r <= n; r++) {
                row = rows[r]
                if (!match(row, /<a href="[^"]*"/)) continue
                href = substr(row, RSTART + 9, RLENGTH - 10)
                gsub(/&amp;/, "\\&", href)
                if (href ~ /^\/\//) href = "https:" href
                # The part after "<something>.zip/" is the file inside the zip
                k = index(tolower(href), ".zip/")
                if (k == 0) continue
                inner = substr(href, k + 5)
                if (inner == "" || inner ~ /\/$/) continue
                size = 0
                if (match(row, /id="size">[0-9]+/)) size = substr(row, RSTART + 10, RLENGTH - 10) + 0
                name = path urldecode(inner)
                gsub(/\|/, "_", name)
                print name "|" size "|" href
            }
        }' > "$out.tmp"
    rm -f "$page"
    [ -s "$out.tmp" ] || { rm -f "$out.tmp"; return 1; }
    mv -f "$out.tmp" "$out"
}

# Web folders (Apache/nginx/lighttpd style listings): follows subfolder links up to
# 4 levels deep, staying inside the starting folder. Sizes aren't listed reliably,
# so they're 0 (the download screen asks the server instead).
index_http() {
    local root="$1" out="$2" status="$3"
    case "$root" in */) ;; *) root="$root/" ;; esac
    local queue="$out.queue" page="$out.page" visited=0
    printf '%s\n' "$root" > "$queue"
    : > "$out"

    while [ -s "$queue" ] && [ "$visited" -lt 300 ]; do
        local url=$(head -n 1 "$queue")
        sed -i '1d' "$queue"
        visited=$((visited + 1))

        local code
        code=$(curl -s -L -k $CURL_COMPRESS --connect-timeout 10 -m 30 -w '%{http_code}' "$url" -o "$page")
        local rc=$?
        if [ "$visited" -eq 1 ]; then
            local st=$(curl_status "$rc" "$code" http)
            if [ -n "$st" ]; then
                echo "$st" > "$status"
                rm -f "$queue" "$page"
                return 1
            fi
        fi
        [ "$rc" -eq 0 ] || continue

        # Links in the page: keep ones inside this folder; "/" at the end = subfolder
        local rel="${url#$root}"
        local path_only=$(echo "$url" | sed 's#^[a-z]*://[^/]*##')
        grep -oiE "href=(\"[^\"]*\"|'[^']*')" "$page" | sed "s/^[Hh][Rr][Ee][Ff]=.//; s/.\$//" \
            | LC_ALL=C awk -v url="$url" -v path="$path_only" -v rel="$rel" -v depth="$(echo "$rel" | tr -cd / | wc -c)" "$AWK_URL_FUNCS"'
            {
                h = $0
                sub(/[?#].*$/, "", h)
                if (h == "" || h ~ /^(\.\.?\/?|mailto:|javascript:)/) next
                if (h ~ /^[a-z]+:\/\//) {
                    if (index(h, url) != 1) next
                    h = substr(h, length(url) + 1)
                } else if (h ~ /^\//) {
                    if (index(h, path) != 1) next
                    h = substr(h, length(path) + 1)
                }
                if (h == "" || h ~ /^\// || seen[h]++) next
                if (h ~ /\/$/) {
                    if (depth < 4 && h !~ /\/.+\//) print "D|" url h
                } else if (h !~ /\//) {
                    name = urldecode(rel h)
                    gsub(/\|/, "_", name)
                    print "F|" name "|0|" url h
                }
            }' > "$page.links"
        grep '^F|' "$page.links" | cut -d'|' -f2- >> "$out"
        grep '^D|' "$page.links" | cut -d'|' -f2- >> "$queue"
        rm -f "$page.links"
    done
    rm -f "$queue" "$page"

    if [ ! -s "$out" ]; then
        echo "no_listing" > "$status"
        return 1
    fi
    return 0
}

# FTP folders: reads directory listings (Unix "ls -l" or Windows/IIS style) and
# follows subfolders up to 4 levels deep.
index_ftp() {
    local root="$1" out="$2" status="$3"
    case "$root" in */) ;; *) root="$root/" ;; esac
    local queue="$out.queue" page="$out.page" visited=0
    printf '%s\n' "$root" > "$queue"
    : > "$out"

    while [ -s "$queue" ] && [ "$visited" -lt 300 ]; do
        local url=$(head -n 1 "$queue")
        sed -i '1d' "$queue"
        visited=$((visited + 1))

        curl -s --connect-timeout 10 -m 60 "$url" -o "$page"
        local rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$visited" -eq 1 ]; then
                curl_status "$rc" 000 ftp > "$status"
                rm -f "$queue" "$page"
                return 1
            fi
            continue
        fi

        local rel="${url#$root}"
        tr -d '\r' < "$page" | LC_ALL=C awk -v url="$url" -v rel="$rel" -v depth="$(echo "$rel" | tr -cd / | wc -c)" "$AWK_URL_FUNCS"'
            {
                type = ""; size = 0; name = ""
                if ($1 ~ /^[-dl][-rwxsStT]+$/ && NF >= 9) {          # Unix ls -l style
                    type = substr($1, 1, 1); size = $5
                    name = $0; sub(/^([^ ]+ +){8}/, "", name)
                    if (type == "l") next
                } else if ($1 ~ /^[0-9][0-9]-[0-9][0-9]-[0-9]+$/ && NF >= 4) {   # Windows style
                    type = ($3 == "<DIR>") ? "d" : "-"; size = ($3 == "<DIR>") ? 0 : $3
                    name = $0; sub(/^([^ ]+ +){3}/, "", name)
                } else next
                if (name == "." || name == "..") next
                if (type == "d") {
                    if (depth < 4) print "D|" url urlencode(name) "/"
                } else {
                    p = urldecode(rel) name
                    gsub(/\|/, "_", p)
                    print "F|" p "|" (size + 0) "|" url urlencode(name)
                }
            }' > "$page.links"
        grep '^F|' "$page.links" | cut -d'|' -f2- >> "$out"
        grep '^D|' "$page.links" | cut -d'|' -f2- >> "$queue"
        rm -f "$page.links"
    done
    rm -f "$queue" "$page"

    if [ ! -s "$out" ]; then
        echo "empty" > "$status"
        return 1
    fi
    return 0
}

# Builds (or reuses, if fresh) a source's index. $2: status file for errors.
# $3 = 1 forces a fresh download.
ensure_source_index() {
    local source="$1" status="$2" force="$3"
    local idx=$(source_index_file "$source")
    if [ "$force" != "1" ] && [ -s "$idx" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$idx" 2>/dev/null || echo 0) ))
        [ "$age" -lt $((REPO_CACHE_DAYS * 86400)) ] && return 0
    fi
    local tmp="$idx.new"
    rm -f "$tmp" "$status"
    case "$(source_type "$source")" in
        http) index_http "$source" "$tmp" "$status" ;;
        ftp) index_ftp "$source" "$tmp" "$status" ;;
        *) index_archive "$source" "$tmp" "$status" ;;
    esac
    if [ $? -eq 0 ]; then
        mv "$tmp" "$idx"
        return 0
    fi
    rm -f "$tmp"
    # A stale index still beats nothing when the server is unreachable
    [ "$force" != "1" ] && [ -s "$idx" ] && return 0
    return 1
}

# ------------------------------------------------------------------
# Consoles
# ------------------------------------------------------------------

# File extensions (regex alternation) that count as games for a console.
console_ext_regex() {
    local regex="zip|7z|rar|chd"
    local auto=$(get_auto_extensions "$1")
    [ -n "$auto" ] && regex="$auto|$regex"
    [ -n "$2" ] && regex="$2|$regex"
    echo "$regex"
}

# Onion folder for a pack's subfolder name, from its name ("GBA", "Game Boy Advance",
# "Nintendo - Game Boy Advance", ...). Prints nothing if it's not recognised.
# Also copes with "(Update 1)"-style notes, a ".zip" ending, and a maker's name in
# front ("Sony - PS1", "Sega - Sega CD", "Arcade - Mame 2003 Plus").
# Prints the Onion folder, or "!Name" for a console the Miyoo Mini can't run.
folder_lookup() {
    awk -F'|' -v name="$1" '
        function key(s) { s = tolower(s); gsub(/[^a-z0-9]/, "", s); return s }
        BEGIN {
            n = name; sub(/\.[Zz][Ii][Pp]$/, "", n)
            k[1] = key(n)
            m = n; gsub(/\([^)]*\)|\[[^]]*\]/, "", m)
            k[2] = key(m)
            k[3] = k[2]
            if (match(k[2], /^(nintendo|sega|sony|nec|snk|atari|bandai|microsoft|commodore|arcade|gce|coleco|mattel|philips|panasonic)/) && RLENGTH < length(k[2]))
                k[3] = substr(k[2], RLENGTH + 1)
        }
        { for (i = 2; i <= NF; i++) { alias[$i] = $1 } }
        END { for (j = 1; j <= 3; j++) if (k[j] != "" && (k[j] in alias)) { print alias[k[j]]; exit } }' <<'EOF'
FC|fc|nes|famicom|nintendo|nintendoentertainmentsystem|nintendonintendoentertainmentsystem|nintendonesfamicom
SFC|sfc|snes|superfamicom|supernintendo|supernintendoentertainmentsystem|nintendosupernintendoentertainmentsystem|nintendosnessuperfamicom
GB|gb|gameboy|nintendogameboy
GBC|gbc|gameboycolor|gameboycolour|nintendogameboycolor
GBA|gba|gameboyadvance|nintendogameboyadvance
!N64|n64|nintendo64|nintendonintendo64
NDS|nds|ds|nintendods|nintendonintendods
VB|vb|virtualboy|nintendovirtualboy
FDS|fds|famicomdisksystem|nintendofamicomdisksystem
POKE|pokefami|pokemini|pokemonmini|nintendopokemonmini
MD|md|genesis|megadrive|segagenesis|segamegadrive|segamegadrivegenesis|megadrivegenesis
MS|ms|sms|mastersystem|segamastersystem|segamastersystemmarkiii
GG|gg|gamegear|segagamegear
SEGACD|segacd|megacd|segamegacd|segamegacdsegacd
THIRTYTWOX|32x|sega32x|thirtytwox
!Dreamcast|dc|dreamcast|segadreamcast
PS|ps|ps1|psx|playstation|playstation1|sonyplaystation
!PSP|psp|playstationportable|sonyplaystationportable
PCE|pce|pcengine|turbografx|turbografx16|tg16|necpcengine|necpcenginetg16|necpcengineturbografx16
PCECD|pcecd|pcenginecd|turbografxcd|necpcenginecdturbografxcd
PCFX|pcfx|necpcfx
NEOGEO|neogeo|snkneogeo
NEOCD|neocd|neogeocd|snkneogeocd
NGP|ngp|neogeopocket|snkneogeopocket
NGP|ngpc|neogeopocketcolor|snkneogeopocketcolor
WS|ws|wonderswan|bandaiwonderswan
WS|wsc|wonderswancolor|bandaiwonderswancolor
ATARI|atari2600|a2600|2600
SEVENTYEIGHTHUNDRED|atari7800|a7800|7800|seventyeighthundred
FIFTYTWOHUNDRED|atari5200|a5200|5200|fiftytwo00|fiftytwohundred
LYNX|atarilynx|lynx
ARCADE|arcade|mame|fbneo|finalburnneo|fba|mame2003|mame2003plus|arcademame
CPS1|cps1|capcomplaysystem
CPS2|cps2|capcomplaysystem2
CPS3|cps3|capcomplaysystem3
MSX|msx|microsoftmsx
MSX|msx2|microsoftmsx2
COMMODORE|c64|commodore64|commodore
AMIGA|amiga|commodoreamiga
DOS|dos|msdos
PICO|pico|pico8
TIC|tic80|tic
VECTREX|vectrex|gcevectrex
SATELLAVIEW|satellaview|nintendosatellaview
SGB|sgb|supergameboy
GW|gw|gameandwatch|gamewatch
SCUMMVM|scummvm
PORTS|ports
COLECO|coleco|colecovision|colecocolecovision
INTELLIVISION|intellivision|mattelintellivision
SEGASGONE|sg1000|segasg1000|segasgone
SGFX|sgfx|supergrafx|necsupergrafx|pcenginesupergrafx
SUFAMI|sufami|sufamiturbo|bandaisufamiturbo
SUPERVISION|supervision|watarasupervision
VIC20|vic20|commodorevic20
VIDEOPAC|videopac|philipsvideopac|videopacplus
ODYSSEY|odyssey|odyssey2|magnavoxodyssey2
ZXS|zxs|zxspectrum|sinclairzxspectrum
CPC|cpc|amstradcpc
MEGADUCK|megaduck
FAIRCHILD|fairchild|channelf|fairchildchannelf
ATARIST|atarist
!GameCube|gamecube|gc|ngc|nintendogamecube
!Wii|wii|nintendowii
!Wii U|wiiu|nintendowiiu
!3DS|3ds|n3ds|new3ds|nintendo3ds|nintendonew3ds
!Switch|switch|nintendoswitch
!PS2|ps2|playstation2|sonyplaystation2
!PS3|ps3|playstation3|sonyplaystation3
!PS4|ps4|playstation4|sonyplaystation4
!PS Vita|psvita|vita|playstationvita|sonyplaystationvita
!Xbox|xbox|microsoftxbox
!Xbox 360|xbox360|microsoftxbox360
!Saturn|saturn|segasaturn
EOF
}

console_for_folder() {
    local r=$(folder_lookup "$1")
    case "$r" in "!"*) ;; *) echo "$r" ;; esac
}

# Name of a console the Miyoo Mini can't run ("GameCube"), or nothing.
console_incompatible() {
    local r=$(folder_lookup "$1")
    case "$r" in "!"*) echo "${r#!}" ;; esac
}

# Onion folder for an unambiguous game file extension ("!Name": a console the Miyoo
# Mini can't run).
console_for_ext() {
    case "$(echo "$1" | tr 'A-Z' 'a-z')" in
        nes) echo FC ;; smc|sfc) echo SFC ;; gb) echo GB ;; gbc) echo GBC ;; gba) echo GBA ;;
        nds) echo NDS ;; vb) echo VB ;; fds) echo FDS ;; min) echo POKE ;;
        md|gen|smd) echo MD ;; sms) echo MS ;; gg) echo GG ;; 32x) echo THIRTYTWOX ;;
        pce) echo PCE ;; ngp|ngc) echo NGP ;; ws|wsc) echo WS ;; sg) echo SEGASGONE ;;
        a26) echo ATARI ;; a78) echo SEVENTYEIGHTHUNDRED ;; a52) echo FIFTYTWOHUNDRED ;; lnx) echo LYNX ;;
        p8) echo PICO ;; tic) echo TIC ;; vec) echo VECTREX ;; d64|t64|crt) echo COMMODORE ;; adf|lha) echo AMIGA ;;
        col) echo COLECO ;; int) echo INTELLIVISION ;; z80|tzx) echo ZXS ;;
        n64|z64|v64) echo "!N64" ;; cdi|gdi) echo "!Dreamcast" ;; cso) echo "!PSP" ;;
        rvz|gcm) echo "!GameCube" ;; 3ds|cia) echo "!3DS" ;; wbfs) echo "!Wii" ;;
    esac
}

# Works out which subfolders of a pack hold which console. Prints
# "folder|CONSOLE|files" lines ("-" when unknown) for every top-level folder; if the
# whole pack sits in one wrapper folder (e.g. "MyPack/GBA/..."), looks one level in.
detect_pack_consoles() {
    local idx="$1"
    local prefix=""
    local tops=$(cut -d'|' -f1 "$idx" | grep '/' | cut -d/ -f1 | sort -u)
    if [ "$(echo "$tops" | grep -c .)" -eq 1 ] && [ -z "$(console_for_folder "$tops")" ]; then
        prefix="$tops/"
    fi

    cut -d'|' -f1 "$idx" | grep "^$(echo "$prefix" | sed 's/[][\.*^$]/\\&/g')[^/]*/" | awk -v p="$prefix" '
        { rest = substr($0, length(p) + 1); na = split(rest, a, "/"); folder = p a[1]
          ext = $0; sub(/^.*\./, "", ext); ext = tolower(ext)
          count[folder]++; exts[folder, ext]++ ; if (!((folder, ext) in seen)) { seen[folder, ext] = 1; list[folder] = list[folder] " " ext }
          # Folder names further down ("Pack/nds/roms/..."), in case the top one says nothing
          for (i = 2; i < na; i++) if (a[i] != "" && !((folder, a[i]) in sub_seen) && nsub[folder] < 6) {
              sub_seen[folder, a[i]] = 1; nsub[folder]++; subs[folder] = subs[folder] "/" a[i] } }
        END { for (f in count) {
                  best = ""; bestn = 0; n = split(list[f], e, " ")
                  for (i = 1; i <= n; i++) if (exts[f, e[i]] > bestn) { bestn = exts[f, e[i]]; best = e[i] }
                  print f "|" count[f] "|" best "|" subs[f] } }' | sort | while IFS='|' read -r folder count ext subs; do
        name="${folder##*/}"
        console=$(folder_lookup "$name")
        note=""
        case "$console" in "!"*) note="${console#!}"; console="-" ;; esac
        if [ -z "$console" ] && [ -n "$subs" ]; then
            for sub in $(echo "$subs" | tr '/ ' '\n_'); do
                console=$(console_for_folder "$(echo "$sub" | tr '_' ' ')")
                [ -n "$console" ] && break
            done
        fi
        [ -z "$console" ] && console=$(console_for_ext "$ext")
        case "$console" in "!"*) note="${console#!}"; console="-" ;; esac
        echo "$folder|${console:--}|$count|$note"
    done

    # Zips holding a whole console ("Nintendo - Game Boy.zip") count as folders too,
    # when their name says which console they are
    awk -F'|' -v p="$prefix" 'NF >= 4 && $4 > 1 && (p == "" || index($1, p) == 1) && substr($1, length(p) + 1) !~ /\// { print $1 "|" $4 }' "$idx" \
        | while IFS='|' read -r zip count; do
        console=$(folder_lookup "${zip##*/}")
        case "$console" in
            "") ;;
            "!"*) echo "$zip|-|$count|${console#!}" ;;
            *) echo "$zip|$console|$count|" ;;
        esac
    done
}

# Which console each top-level folder (or console zip) of a repo is, worked out once
# per index and kept next to it. A repo added for one console uses this to leave out
# folders that clearly belong to other consoles.
repo_folder_map() {
    local idx="$1" map="$1.folders"
    if [ ! -s "$map" ] || [ "$idx" -nt "$map" ]; then
        detect_pack_consoles "$idx" > "$map.tmp"
        mv -f "$map.tmp" "$map"
    fi
    echo "$map"
}

# Adds the files inside console zips to an index: $1 index, $2 "zip path" lines to
# open (paths as they appear in the index). Prints the combined index's file name.
expand_console_zips() {
    local idx="$1" wanted="$2" out="$1.expanded"
    cp "$idx" "$out"
    [ -s "$wanted" ] || { echo "$out"; return; }
    while IFS= read -r zip; do
        local url=$(awk -F'|' -v z="$zip" '$1 == z { print $3; exit }' "$idx")
        [ -z "$url" ] && continue
        local zidx="$SOURCES_DIR/$(source_key "$url").zip.idx"
        index_zip "$url" "$zip" "$zidx" && cat "$zidx" >> "$out"
    done < "$wanted"
    echo "$out"
}

pack_map_file() {
    echo "$PACKS_DIR/$(source_key "$1").map"
}

# Consoles that have games available, as "CONSOLE|repos" (repos = how many sources).
consoles_with_repos() {
    {
        repos_list | awk -F'|' '$1 != "*" { print $1 }'
        repos_list | awk -F'|' '$1 == "*" { print $2 }' | while IFS= read -r src; do
            map=$(pack_map_file "$src")
            [ -f "$map" ] && awk -F'|' '$2 != "-" { print $2 }' "$map" | sort -u
        done
    } | sort | uniq -c | awk '{ print $2 "|" $1 }'
}

# Prints one source's games for a console as "title|url|source|size" lines (unsorted).
# The source's index must exist. $4: for a pack, the pack folders mapped to this
# console (one per line); empty for a repo added for the console itself.
source_games() {
    local console="$1" src="$2" fmt="$3" folder_prefix="$4"
    local idx=$(source_index_file "$src")
    local regex=$(console_ext_regex "$console" "$fmt")
    local label=$(source_label "$src")

    # Folders / console zips to skip: in a repo added for one console, the ones that
    # are clearly other consoles (a multi-console item added as "GB" should show only
    # its Game Boy games). Console zips for this console get opened.
    local fmap=$(repo_folder_map "$idx")
    local key=$(source_key "$src")
    local skip="$CACHE_DIR/.skip_folders.$key" zips="$CACHE_DIR/.open_zips.$key" multi=0
    : > "$skip"
    # Besides zips named after the console, a zip holding many files is a bundle of
    # games too ("All GBA games.zip") - except for arcade systems, where every game
    # is itself a zip of many chip files.
    local bundles=8
    case "$console" in ARCADE|CPS1|CPS2|CPS3|NEOGEO|FBNEO|MAME*) bundles=999999 ;; esac
    if [ -n "$folder_prefix" ]; then
        echo "$folder_prefix" | awk -F'|' -v b="$bundles" '
            NR == FNR { if ($0 != "") want[$0] = 1; next }
            NF >= 4 && $4 > 1 {
                if ($1 in want) { print $1; next }
                if ($4 + 0 >= b + 0) for (p in want) if (index($1, p "/") == 1) { print $1; next }
            }' - "$idx" > "$zips"
    else
        # Only when the repo really holds several consoles (a Game Boy folder added on
        # purpose as GBC must keep working): then everything not recognised as this
        # console is left out, and so are loose zips at the top, which in such repos
        # are other consoles' packs rather than games.
        multi=$(awk -F'|' '$2 != "-" { n[$2] = 1 } END { for (x in n) d++; print (d >= 2) ? 1 : 0 }' "$fmap")
        [ "$multi" = "1" ] && awk -F'|' -v c="$console" '$2 != c { print $1 }' "$fmap" > "$skip"
        awk -F'|' -v c="$console" -v b="$bundles" -v multi="$multi" '
            NR == FNR { known[$1] = $2; next }
            NF >= 4 && $4 > 1 {
                top = $1; sub(/\/.*$/, "", top)
                if (multi == 1 && top != $1 && (top in known) && known[top] != c) next   # inside another console folder
                if (known[$1] == c || (multi != 1 && !($1 in known) && $4 + 0 >= b + 0)) print $1
            }' "$fmap" "$idx" > "$zips"
    fi
    local full=$(expand_console_zips "$idx" "$zips")

    { echo "$folder_prefix" | sed 's/^/P|/'; sed 's/^/S|/' "$skip"; sed 's/^/Z|/' "$zips"; } \
        | LC_ALL=C awk -F'|' -v re="\\\\.($regex)\$" -v label="$label" -v multi="$multi" '
        NR == FNR {
            k = substr($0, 3)
            if (k == "") next
            if ($1 == "P") { prefixes[k "/"] = 1; np++ }
            else if ($1 == "S") skip[k "/"] = 1
            else zipfile[k] = 1
            next
        }
        {
            path = $1
            if (path in zipfile) next          # the console zip itself: its games are listed
            if (tolower(path) !~ re) next
            if (np) { ok = 0; for (p in prefixes) if (index(path, p) == 1) ok = 1; if (!ok) next }
            if ((path "/") in skip) next        # a zip of another console
            for (p in skip) if (index(path, p) == 1) next
            if (multi == 1 && path !~ /\// && tolower(path) ~ /\.(zip|7z|rar)$/) next
            title = path; sub(/^.*\//, "", title); sub(/\.[^.]+$/, "", title)
            print title "|" $3 "|" label "|" $2
        }' - "$full"
    rm -f "$full" "$skip" "$zips"
}

# Builds a console's game list from every repo that has it, as
# "title|url|source|size" lines sorted by title. $3: status file for errors.
# Sources that fail are skipped as long as at least one works.
build_console_games() {
    local console="$1" out="$2" status="$3" force="$4"
    local tmp="$out.tmp" any_ok=0 src_status="$CACHE_DIR/.src_status" c src fmt
    : > "$tmp"
    rm -f "$status"

    repos_list > "$CACHE_DIR/.repos_now"
    while IFS='|' read -r c src fmt; do
        local folder_prefix=""
        if [ "$c" = "*" ]; then
            map=$(pack_map_file "$src")
            [ -f "$map" ] || continue
            # A pack can map several folders to the same console
            folder_prefix=$(awk -F'|' -v c="$console" '$2 == c { print $1 }' "$map")
            [ -z "$folder_prefix" ] && continue
        elif [ "$c" != "$console" ]; then
            continue
        fi

        if ! ensure_source_index "$src" "$src_status" "$force"; then
            cp "$src_status" "$status" 2>/dev/null
            continue
        fi
        any_ok=1
        source_games "$console" "$src" "$fmt" "$folder_prefix" >> "$tmp"
    done < "$CACHE_DIR/.repos_now"
    rm -f "$CACHE_DIR/.repos_now" "$src_status"

    # Same game (title + file type) in several repos: keep the first
    awk -F'|' '{ ext = $2; sub(/^.*\./, "", ext); key = tolower($1 "." ext) } !seen[key]++' "$tmp" \
        | sort -f -t'|' -k1,1 > "$out"
    rm -f "$tmp"

    if [ ! -s "$out" ]; then
        [ "$any_ok" -eq 1 ] && echo "empty" > "$status"
        [ -s "$status" ] || echo "empty" > "$status"
        return 1
    fi
    return 0
}
