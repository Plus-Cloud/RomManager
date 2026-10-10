#!/bin/sh
# RomManager (Settings > Default Launcher): keeps an eye on Onion's game switcher when
# it was opened from RomManager, or from a game started there.
#  - B in the switcher (back to Onion's menu) deletes cmd_to_run.sh: put RomManager's
#    command back straight away, so Onion opens RomManager instead of its menu
#  - a game picked in the switcher gets the same ending as games started in
#    RomManager: back to RomManager when it ends (see write_after_game_hook)
# Ends by itself once the switcher has closed.

c=/mnt/SDCARD/.tmp_update/cmd_to_run.sh
relaunch='cd /mnt/SDCARD/App/RomManager; sh ./launch.sh'

running() { pidof gameSwitcher >/dev/null 2>&1; }

# The switcher starts once RomManager (or the game) has closed: wait up to 10s for it
i=0
while ! running; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && exit 0
    sleep 0.1
done

while running; do
    if [ ! -f "$c" ]; then
        # B: the switcher removed the command on its way back to Onion's menu
        echo "$relaunch" > "$c"
        touch /tmp/quick_switch /tmp/rm_return
        sync
    elif ! grep -q "rm_after\|App/RomManager" "$c" 2>/dev/null && \
        grep -q "/mnt/SDCARD/Roms/\|/\.\./\.\./Roms/" "$c" 2>/dev/null; then
        # A game picked: come back here when it ends
        sed -i "1s|^|trap 'sh /tmp/rm_after.sh' EXIT; |" "$c"
        sync
    fi
    sleep 0.05
done

# In case the switcher removed the command right as it closed
if [ ! -f "$c" ]; then
    echo "$relaunch" > "$c"
    touch /tmp/quick_switch /tmp/rm_return
    sync
    # Onion may have started its menu already: closing it hands over to RomManager
    # (Onion moves /tmp/cmd_to_run.sh into place when its menu closes)
    sleep 0.3
    if pidof MainUI >/dev/null 2>&1; then
        cp -f "$c" /tmp/cmd_to_run.sh
        killall MainUI 2>/dev/null
    fi
fi
exit 0
