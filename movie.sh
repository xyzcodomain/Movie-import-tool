#!/usr/bin/env bash

set -u
set -o pipefail

# ==========================================================
# Movie Import Watchdog
# Watches an optical drive, rips inserted discs with
# MakeMKV, imports the largest title into the media library,
# then ejects the disc and waits for the next one.
# ==========================================================

# ---------------- Configuration ----------------

SRC="$HOME/Movies"
DST="/srv/media/Movies"

DEV="/dev/sr0"

MINLENGTH=120
POLL_INTERVAL=10

# ---------------- Colours ----------------

AMBER='\033[38;5;214m'
GREEN='\033[38;5;114m'
RED='\033[38;5;203m'
GRAY='\033[38;5;245m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------- Logging ----------------

info() {
    printf "${AMBER}${BOLD}::${RESET} %s\n" "$1"
}

ok() {
    printf "${GREEN}${BOLD}✓${RESET} %s\n" "$1"
}

err() {
    printf "${RED}${BOLD}✗${RESET} %s\n" "$1"
}

step() {
    printf "${GRAY}  └─${RESET} %s\n" "$1"
}

banner() {
    printf "${AMBER}${BOLD}"
    echo "  ┌────────────────────────────────┐"
    echo "  │      MOVIE IMPORT WATCHDOG      │"
    echo "  └────────────────────────────────┘"
    printf "${RESET}"
}

cleanup() {
    echo
    info "Stopping Movie Import Watchdog."
    exit 0
}

trap cleanup INT TERM

# ------------------------------------------------

disc_present() {
    blkid "$DEV" >/dev/null 2>&1 ||
    dd if="$DEV" bs=2048 count=1 status=none >/dev/null 2>&1
}

sanitize_name() {

    tr ' ' '_' |
    tr -cd '[:alnum:]_.-'

}

choose_name() {

    local file="$1"

    local disc_label

    disc_label=$(
        lsblk -dno LABEL "$DEV" 2>/dev/null |
        sanitize_name
    )

    if [[ -n "$disc_label" ]]; then
        printf "%s" "$disc_label"
    else
        basename "$file" .mkv
    fi
}

show_progress() {

    local vals cur max pct

    vals=${1#PRGV:}

    IFS=, read -r cur _ max <<< "$vals"

    if [[ "$max" -gt 0 ]]; then
        pct=$((cur * 100 / max))
        printf "\r${AMBER}${BOLD}::${RESET} Overall progress: %3d%%" "$pct"
    fi
}

rip_current_disc() {

    info "Disc detected."
    info "Starting MakeMKV..."
    step "Minimum title length: ${MINLENGTH}s"

    makemkvcon \
        -r \
        --progress=-same \
        mkv \
        disc:0 \
        all \
        "$SRC" \
        --minlength="$MINLENGTH" \
        --noscan |

    while IFS= read -r line
    do

        case "$line" in

            MSG:*)

                msg=$(sed -n \
                    's/^MSG:[0-9]*,[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p' \
                    <<< "$line")

                case "$msg" in

                    *"was added"*)
                        step "${msg/Title #/Title }"
                        ;;

                    *"skipped"*)
                        ;;

                    *"Saving"* )
                        info "$msg"
                        ;;

                    *)
                        [[ -n "$msg" ]] && step "$msg"
                        ;;

                esac

                ;;

            PRGV:*)

                show_progress "$line"

                ;;

            PRGT:*)

                name=$(sed -n \
                    's/^PRGT:[0-9]*,[0-9]*,"\([^"]*\)".*/\1/p' \
                    <<< "$line")

                [[ -n "$name" ]] &&
                    printf "\n${GRAY}  └─${RESET} %s\n" "$name"

                ;;

        esac

    done

    echo

    RIP_STATUS=${PIPESTATUS[0]}

    if [[ "$RIP_STATUS" -ne 0 ]]; then

        err "MakeMKV failed."

        eject "$DEV" >/dev/null 2>&1 || true

        return 1

    fi
    ok "Rip complete."

    SAVED_COUNT=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)

    ok "${SAVED_COUNT} title(s) saved."

    while IFS= read -r f
    do
        sz=$(du -h "$f" | cut -f1)
        step "$(basename "$f") (${sz})"
    done < <(
        find "$SRC" \
            -maxdepth 1 \
            -name "*.mkv" \
            -print
    )

    FILE=$(
        find "$SRC" \
            -maxdepth 1 \
            -name "*.mkv" \
            -printf "%s %p\n" |
        sort -nr |
        head -1 |
        cut -d' ' -f2-
    )

    if [[ -z "$FILE" ]]; then

        err "Rip finished but no MKV files were found."

        eject "$DEV" >/dev/null 2>&1 || true

        return 1

    fi

    SIZE_HUMAN=$(du -h "$FILE" | cut -f1)

    NAME=$(choose_name "$FILE")

    info "Selected main feature: ${NAME} (${SIZE_HUMAN})"

    TARGET="$DST/$NAME"

    N=2

    while [[ -e "$TARGET" ]]
    do
        TARGET="$DST/$NAME ($N)"
        ((N++))
    done

    mkdir -p "$TARGET"

    mv "$FILE" "$TARGET/$(basename "$TARGET").mkv"

    ok "Imported to:"
    step "$TARGET/$(basename "$TARGET").mkv"

    LEFTOVER=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)

    if [[ "$LEFTOVER" -gt 0 ]]; then

        info "Removing ${LEFTOVER} leftover title(s)..."

        find "$SRC" \
            -maxdepth 1 \
            -name "*.mkv" \
            -delete

        ok "Cleanup complete."

    fi

    eject "$DEV" >/dev/null 2>&1 || true

    ok "Disc ejected."

    echo
    printf "${GREEN}${BOLD}Done.${RESET} 🎬 %s\n\n" "$NAME"

}

# ==========================================================
# Main
# ==========================================================

banner

mkdir -p "$SRC"

if ! command -v makemkvcon >/dev/null 2>&1
then
    err "makemkvcon not found."
    err "Install makemkv-bin / makemkv-oss."
    exit 1
fi

ok "MakeMKV found."

if [[ ! -b "$DEV" ]]
then
    err "Optical drive not found: $DEV"
    exit 1
fi

ok "Optical drive detected."

info "Watching $DEV..."

echo
echo -e "${GRAY}Insert a disc at any time."
echo -e "Press Ctrl+C to quit.${RESET}"
echo

WAS_PRESENT=false

while true
do

    if disc_present
    then

        if [[ "$WAS_PRESENT" == false ]]
        then

            rip_current_disc

            WAS_PRESENT=true

            sleep 5

        fi

    else

        WAS_PRESENT=false

    fi

    sleep "$POLL_INTERVAL"

done