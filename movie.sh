
#!/bin/bash
set -uo pipefail
# Note: no -e here — a failed rip shouldn't kill the whole watchdog loop.
# ─── Config ───────────────────────────────────────────────
SRC="$HOME/Movies"
DST="/srv/media/Movies"
DEV="/dev/sr0"
MINLENGTH=120       # seconds — filters out menus/junk titles
POLL_INTERVAL=10    # seconds between disc checks
# ─── Colors ───────────────────────────────────────────────
AMBER='\033[38;5;214m'
GREEN='\033[38;5;114m'
RED='\033[38;5;203m'
GRAY='\033[38;5;245m'
BOLD='\033[1m'
RESET='\033[0m'
info()  { echo -e "${AMBER}${BOLD}::${RESET} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✓${RESET} $1"; }
err()   { echo -e "${RED}${BOLD}✗${RESET} $1"; }
step()  { echo -e "${GRAY}  └─${RESET} $1"; }
banner() {
    echo -e "${AMBER}${BOLD}"
    echo "  ┌────────────────────────────────┐"
    echo "  │      MOVIE IMPORT WATCHDOG      │"
    echo "  └────────────────────────────────┘"
    echo -e "${RESET}"
}
disc_present() {
    blkid "$DEV" >/dev/null 2>&1 || dd if="$DEV" bs=2048 count=1 status=none >/dev/null 2>&1
}
rip_current_disc() {
    info "Disc detected — starting rip"
    info "Ripping with MakeMKV (min length ${MINLENGTH}s)..."
    step "This can take a while depending on disc size"
    # Use MakeMKV's robot/machine-readable output (-r) so we can parse    # progress and title events live instead of dumping raw log spam.
    makemkvcon -r --progress=-same mkv disc:0 all "$SRC" --minlength="$MINLENGTH" --noscan \
    | while IFS= read -r line; do
        case "$line" in
            MSG:*)
                # MSG:code,flags,count,"message","format",params...
                msg=$(echo "$line" | sed -n 's/^MSG:[0-9]*,[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p')
                case "$msg" in
                    *"was added"*)
                        step "$(echo "$msg" | sed 's/Title #/Title /')"
                        ;;
                    *"skipped"*)
                        : # too spammy, stay quiet on skips
                        ;;
                    *"Saving"*"titles into"*)
                        info "$msg"
                        ;;
                    *)
                        [ -n "$msg" ] && step "$msg"
                        ;;
                esac
                ;;
            PRGV:*)
                # PRGV:current,total,max — overall progress values
                vals=$(echo "$line" | cut -d: -f2)
                cur=$(echo "$vals" | cut -d, -f1)
                max=$(echo "$vals" | cut -d, -f3)
                if [ "$max" -gt 0 ] 2>/dev/null; then
                    pct=$(( cur * 100 / max ))
                    printf "\r${AMBER}${BOLD}::${RESET} Overall progress: %d%%   " "$pct"
                fi
                ;;
            PRGT:*)
                # PRGT:code,id,"name" — current operation/title being
processed
                name=$(echo "$line" | sed -n 's/^PRGT:[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p')
                [ -n "$name" ] && printf "\n${GRAY}  └─${RESET} %s\n"
"$name"
                ;;
        esac
    done
    echo ""  # clear the progress line
    RIP_STATUS=${PIPESTATUS[0]}
    if [ "$RIP_STATUS" -ne 0 ]; then
        err "MakeMKV rip failed"
        eject "$DEV" 2>/dev/null || true
        return 1
    fi
    ok "Rip complete"
    # Report what actually got saved to disk
    SAVED_COUNT=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)
    ok "${SAVED_COUNT} title(s) saved to $SRC"
    find "$SRC" -maxdepth 1 -name "*.mkv" -printf "%p\n" | while read
-r f; do
        sz=$(du -h "$f" | cut -f1)
        step "$(basename "$f")  (${sz})"
    done
    # Pick the LARGEST mkv — that's the real movie, not a trailer/menu clip
    FILE=$(find "$SRC" -maxdepth 1 -name "*.mkv" -printf "%s %p\n" | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -z "$FILE" ]; then
        err "Rip finished but no MKV files found in $SRC"
        eject "$DEV" 2>/dev/null || true
        return 1
    fi
    SIZE_HUMAN=$(du -h "$FILE" | cut -f1)
    NAME=$(basename "$FILE" .mkv)
    info "Selected main feature: ${BOLD}${NAME}${RESET}${AMBER} (${SIZE_HUMAN}) — largest of ${SAVED_COUNT}"
    mkdir -p "$DST/$NAME"
    mv "$FILE" "$DST/$NAME/$NAME.mkv"
    ok "Imported to $DST/$NAME/$NAME.mkv"
    LEFTOVER=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)
    if [ "$LEFTOVER" -gt 0 ]; then
        info "Removing $LEFTOVER leftover junk title(s)..."
        find "$SRC" -maxdepth 1 -name "*.mkv" -delete
        ok "Cleaned up"
    fi
    eject "$DEV" 2>/dev/null || true
    ok "Disc ejected"
    echo -e "\n${GREEN}${BOLD}Done.${RESET} 🎬  ${NAME}\n"
}
# ─── Main loop ────────────────────────────────────────────
banner
mkdir -p "$SRC"
if ! command -v makemkvcon >/dev/null; then
    err "makemkvcon not found. Install makemkv-oss / makemkv-bin."
    exit 1
fi
ok "makemkvcon found"
if [ ! -b "$DEV" ]; then
    err "No optical drive at $DEV"
    exit 1
fi
ok "Optical drive detected at $DEV"
info "Watching $DEV — insert a disc anytime (checking every ${POLL_INTERVAL}s)"
echo -e "${GRAY}  Press Ctrl+C to stop the watchdog.${RESET}\n"
WAS_PRESENT=false
while true; do
    if disc_present; then
        if [ "$WAS_PRESENT" = false ]; then
            rip_current_disc
            WAS_PRESENT=true
            # after eject, give the drive a moment before we start polling again
            sleep 5
        fi
    else
        WAS_PRESENT=false
    fi
ahola@debian:~$ cat movie.sh
#!/bin/bash
set -uo pipefail
# Note: no -e here — a failed rip shouldn't kill the whole watchdog loop.
# ─── Config ───────────────────────────────────────────────
SRC="$HOME/Movies"
DST="/srv/media/Movies"
DEV="/dev/sr0"
MINLENGTH=120       # seconds — filters out menus/junk titles
POLL_INTERVAL=10    # seconds between disc checks
# ─── Colors ───────────────────────────────────────────────
AMBER='\033[38;5;214m'
GREEN='\033[38;5;114m'
RED='\033[38;5;203m'
GRAY='\033[38;5;245m'
BOLD='\033[1m'
RESET='\033[0m'
info()  { echo -e "${AMBER}${BOLD}::${RESET} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✓${RESET} $1"; }
err()   { echo -e "${RED}${BOLD}✗${RESET} $1"; }
step()  { echo -e "${GRAY}  └─${RESET} $1"; }
banner() {
    echo -e "${AMBER}${BOLD}"
    echo "  ┌────────────────────────────────┐"
    echo "  │      MOVIE IMPORT WATCHDOG      │"
    echo "  └────────────────────────────────┘"
    echo -e "${RESET}"
}
disc_present() {
    blkid "$DEV" >/dev/null 2>&1 || dd if="$DEV" bs=2048 count=1 status=none >/dev/null 2>&1
}
rip_current_disc() {
    info "Disc detected — starting rip"
    info "Ripping with MakeMKV (min length ${MINLENGTH}s)..."
    step "This can take a while depending on disc size"
    # Use MakeMKV's robot/machine-readable output (-r) so we can parse    # progress and title events live instead of dumping raw log spam.
    makemkvcon -r --progress=-same mkv disc:0 all "$SRC" --minlength="$MINLENGTH" --noscan \
    | while IFS= read -r line; do
        case "$line" in
            MSG:*)
                # MSG:code,flags,count,"message","format",params...
                msg=$(echo "$line" | sed -n 's/^MSG:[0-9]*,[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p')
                case "$msg" in
                    *"was added"*)
                        step "$(echo "$msg" | sed 's/Title #/Title /')"
                        ;;
                    *"skipped"*)
                        : # too spammy, stay quiet on skips
                        ;;
                    *"Saving"*"titles into"*)
                        info "$msg"
                        ;;
                    *)
                        [ -n "$msg" ] && step "$msg"
                        ;;
                esac
                ;;
            PRGV:*)
                # PRGV:current,total,max — overall progress values
                vals=$(echo "$line" | cut -d: -f2)
                cur=$(echo "$vals" | cut -d, -f1)
                max=$(echo "$vals" | cut -d, -f3)
                if [ "$max" -gt 0 ] 2>/dev/null; then
                    pct=$(( cur * 100 / max ))
                    printf "\r${AMBER}${BOLD}::${RESET} Overall progress: %d%%   " "$pct"
                fi
                ;;
            PRGT:*)
                # PRGT:code,id,"name" — current operation/title being
processed
                name=$(echo "$line" | sed -n 's/^PRGT:[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p')
                [ -n "$name" ] && printf "\n${GRAY}  └─${RESET} %s\n"
"$name"
                ;;
        esac
    done
    echo ""  # clear the progress line
    RIP_STATUS=${PIPESTATUS[0]}
    if [ "$RIP_STATUS" -ne 0 ]; then
        err "MakeMKV rip failed"
        eject "$DEV" 2>/dev/null || true
        return 1
    fi
    ok "Rip complete"
    # Report what actually got saved to disk
    SAVED_COUNT=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)
    ok "${SAVED_COUNT} title(s) saved to $SRC"
    find "$SRC" -maxdepth 1 -name "*.mkv" -printf "%p\n" | while read
-r f; do
        sz=$(du -h "$f" | cut -f1)
        step "$(basename "$f")  (${sz})"
    done
    # Pick the LARGEST mkv — that's the real movie, not a trailer/menu clip
    FILE=$(find "$SRC" -maxdepth 1 -name "*.mkv" -printf "%s %p\n" | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -z "$FILE" ]; then
        err "Rip finished but no MKV files found in $SRC"
        eject "$DEV" 2>/dev/null || true
        return 1
    fi
    SIZE_HUMAN=$(du -h "$FILE" | cut -f1)
    DISC_LABEL=$(lsblk -dno LABEL "$DEV" | tr " " "_"); NAME="${DISC_LABEL:-$(basename "$FILE" .mkv)}"
    info "Selected main feature: ${BOLD}${NAME}${RESET}${AMBER} (${SIZE_HUMAN}) — largest of ${SAVED_COUNT}"
    mkdir -p "$DST/$NAME"
    mv "$FILE" "$DST/$NAME/$NAME.mkv"
    ok "Imported to $DST/$NAME/$NAME.mkv"
    LEFTOVER=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)
    if [ "$LEFTOVER" -gt 0 ]; then
        info "Removing $LEFTOVER leftover junk title(s)..."
        find "$SRC" -maxdepth 1 -name "*.mkv" -delete
        ok "Cleaned up"
    fi
    eject "$DEV" 2>/dev/null || true
    ok "Disc ejected"
    echo -e "\n${GREEN}${BOLD}Done.${RESET} 🎬  ${NAME}\n"
}
# ─── Main loop ────────────────────────────────────────────
banner
mkdir -p "$SRC"
if ! command -v makemkvcon >/dev/null; then
    err "makemkvcon not found. Install makemkv-oss / makemkv-bin."
    exit 1
fi
ok "makemkvcon found"
if [ ! -b "$DEV" ]; then
    err "No optical drive at $DEV"
    exit 1
fi
ok "Optical drive detected at $DEV"
info "Watching $DEV — insert a disc anytime (checking every ${POLL_INTERVAL}s)"
echo -e "${GRAY}  Press Ctrl+C to stop the watchdog.${RESET}\n"
WAS_PRESENT=false
while true; do
    if disc_present; then
        if [ "$WAS_PRESENT" = false ]; then
            rip_current_disc
            WAS_PRESENT=true
            # after eject, give the drive a moment before we start polling again
            sleep 5
        fi
    else
        WAS_PRESENT=false
    fi
    sleep "$POLL_INTERVAL"
done
