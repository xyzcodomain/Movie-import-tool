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

LOCKFILE="$SRC/.watchdog.lock"

# Config file (holds OMDB_API_URL, with the key embedded). Kept out
# of this script so it's not something you'd accidentally paste into
# a public repo/gist.
CONF_FILE="$(dirname "$(readlink -f "$0")")/watchdog.conf"

OMDB_API_URL=""
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# ---------------- Colours ----------------

AMBER='\033[38;5;214m'
AMBER_DIM='\033[38;5;136m'
GREEN='\033[38;5;114m'
RED='\033[38;5;203m'
GRAY='\033[38;5;245m'
WHITE='\033[38;5;253m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Box drawing
H='─'; V='│'; TL='┌'; TR='┐'; BL='└'; BR='┘'

# ---------------- Terminal helpers ----------------

term_width() {
    tput cols 2>/dev/null || echo 60
}

hr() {
    local w
    w=$(term_width)
    printf "${AMBER_DIM}"
    printf '%*s' "$w" '' | tr ' ' "$H"
    printf "${RESET}\n"
}

box_top() {
    local w
    w=$(( $(term_width) - 2 ))
    printf "${AMBER_DIM}${TL}"
    printf '%*s' "$w" '' | tr ' ' "$H"
    printf "${TR}${RESET}\n"
}

box_bottom() {
    local w
    w=$(( $(term_width) - 2 ))
    printf "${AMBER_DIM}${BL}"
    printf '%*s' "$w" '' | tr ' ' "$H"
    printf "${BR}${RESET}\n"
}

# ---------------- Logging ----------------

timestamp() {
    date '+%H:%M:%S'
}

info() {
    printf "${GRAY}[$(timestamp)]${RESET} ${AMBER}${BOLD}::${RESET} %s\n" "$1"
}

ok() {
    printf "${GRAY}[$(timestamp)]${RESET} ${GREEN}${BOLD}✓${RESET} %s\n" "$1"
}

err() {
    printf "${GRAY}[$(timestamp)]${RESET} ${RED}${BOLD}✗${RESET} %s\n" "$1"
}

warn() {
    printf "${GRAY}[$(timestamp)]${RESET} ${AMBER}${BOLD}!${RESET} %s\n" "$1"
}

step() {
    printf "       ${GRAY}└─${RESET} %s\n" "$1"
}

banner() {
    local w title pad_l pad_r
    w=$(( $(term_width) - 2 ))
    title="MOVIE IMPORT WATCHDOG"
    echo
    box_top
    pad_l=$(( (w - ${#title}) / 2 ))
    pad_r=$(( w - ${#title} - pad_l ))
    printf "${AMBER_DIM}${V}${RESET}${AMBER}${BOLD}%*s%s%*s${RESET}${AMBER_DIM}${V}${RESET}\n" \
        "$pad_l" '' "$title" "$pad_r" ''
    box_bottom
    echo
}

section() {
    echo
    printf "${AMBER}${BOLD}▸ %s${RESET}\n" "$1"
}

cleanup() {
    printf "\r\033[K"
    echo
    info "Stopping Movie Import Watchdog."
    rm -f "$LOCKFILE"
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

# Strips common disc-label junk (quality tags, edition markers,
# disc numbers, dots/underscores) down to a plausible movie title
# to use as an OMDb search query.
clean_label() {

    local raw="$1"
    local cleaned

    cleaned=$(tr '_.' '  ' <<< "$raw")

    # Drop a trailing 4-digit year for now — OMDb searches better
    # on title alone and we re-attach the year from the API result.
    cleaned=$(sed -E 's/\b(19|20)[0-9]{2}\b//g' <<< "$cleaned")

    cleaned=$(sed -E \
        -e 's/\b(1080p|2160p|720p|480p|4k|uhd|hdr|hd)\b//Ig' \
        -e 's/\b(bluray|blu-ray|bdrip|brrip|dvdrip|dvd|webrip|web-dl)\b//Ig' \
        -e 's/\b(x264|x265|h264|h265|hevc|avc)\b//Ig' \
        -e 's/\b(remux|extended|unrated|directors?\s?cut|theatrical)\b//Ig' \
        -e 's/\b(disc|disk|cd|dvd)\s?[0-9]+\b//Ig' \
        -e 's/[[:space:]]+/ /g' \
        <<< "$cleaned"
    )

    # Trim leading/trailing whitespace
    cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"

    printf "%s" "$cleaned"
}

# Looks up a cleaned title on OMDb. Prints "Title (Year)" on a
# match, prints nothing on any failure (no key, no network, no
# match) so the caller can fall back cleanly.
omdb_lookup() {

    local query="$1"

    [[ -z "$OMDB_API_URL" ]] && return 1
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    [[ -z "$query" ]] && return 1

    local encoded response title year response_type

    encoded=$(jq -rn --arg s "$query" '$s|@uri')

    response=$(curl -s -m 8 \
        "${OMDB_API_URL}&t=${encoded}&type=movie")

    [[ -z "$response" ]] && return 1

    response_type=$(jq -r '.Response // "False"' <<< "$response" 2>/dev/null)

    [[ "$response_type" != "True" ]] && return 1

    title=$(jq -r '.Title // empty' <<< "$response" 2>/dev/null)
    year=$(jq -r '.Year // empty' <<< "$response" 2>/dev/null)

    [[ -z "$title" ]] && return 1

    if [[ -n "$year" ]]; then
        printf "%s (%s)" "$title" "$year"
    else
        printf "%s" "$title"
    fi
}

choose_name() {

    local file="$1"

    local disc_label cleaned omdb_result

    disc_label=$(lsblk -dno LABEL "$DEV" 2>/dev/null)

    if [[ -n "$disc_label" ]]; then

        cleaned=$(clean_label "$disc_label")

        omdb_result=$(omdb_lookup "$cleaned")

        if [[ -n "$omdb_result" ]]; then
            OMDB_MATCHED=true
            sanitize_name <<< "$omdb_result"
            return
        fi

        OMDB_MATCHED=false

        if [[ -n "$cleaned" ]]; then
            sanitize_name <<< "$cleaned"
            return
        fi

        sanitize_name <<< "$disc_label"
        return

    fi

    OMDB_MATCHED=false
    basename "$file" .mkv
}

# Renders a real progress bar, not just a percentage number
draw_bar() {
    local pct=$1
    local w=30
    local filled=$(( pct * w / 100 ))
    local empty=$(( w - filled ))

    printf "\r${GRAY}[$(timestamp)]${RESET} ${AMBER}${BOLD}::${RESET} "
    printf "${AMBER}["
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf "${AMBER_DIM}"
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "${AMBER}]${RESET} ${WHITE}${BOLD}%3d%%${RESET}" "$pct"
}

show_progress() {

    local vals cur max pct

    vals=${1#PRGV:}

    IFS=, read -r cur _ max <<< "$vals"

    if [[ "$max" -gt 0 ]]; then
        pct=$((cur * 100 / max))
        draw_bar "$pct"
    fi
}

# Spinner shown while idly polling for a disc
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_I=0

spin_wait() {
    local frame="${SPIN_FRAMES[$SPIN_I]}"
    SPIN_I=$(( (SPIN_I + 1) % ${#SPIN_FRAMES[@]} ))
    printf "\r${GRAY}[$(timestamp)]${RESET} ${AMBER}%s${RESET} Waiting for a disc..." "$frame"
}

# ------------------------------------------------

rip_current_disc() {

    printf "\r\033[K"
    section "Disc Detected"
    step "Minimum title length: ${MINLENGTH}s"
    step "Starting MakeMKV..."
    echo

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
                        printf "\r\033[K"
                        step "${msg/Title #/Title }"
                        ;;

                    *"skipped"*)
                        ;;

                    *"Saving"* )
                        printf "\r\033[K"
                        info "$msg"
                        ;;

                    *)
                        if [[ -n "$msg" ]]; then
                            printf "\r\033[K"
                            step "$msg"
                        fi
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

                if [[ -n "$name" ]]; then
                    printf "\r\033[K"
                    printf "       ${GRAY}└─${RESET} ${DIM}%s${RESET}\n" "$name"
                fi

                ;;

        esac

    done

    printf "\r\033[K"

    RIP_STATUS=${PIPESTATUS[0]}

    if [[ "$RIP_STATUS" -ne 0 ]]; then

        err "MakeMKV failed (exit code ${RIP_STATUS})."

        eject "$DEV" >/dev/null 2>&1 && ok "Disc ejected." \
            || warn "Eject failed — remove disc manually."

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

        eject "$DEV" >/dev/null 2>&1 && ok "Disc ejected." \
            || warn "Eject failed — remove disc manually."

        return 1

    fi

    SIZE_HUMAN=$(du -h "$FILE" | cut -f1)

    OMDB_MATCHED=false
    NAME=$(choose_name "$FILE")

    section "Importing"

    if [[ "$OMDB_MATCHED" == true ]]; then
        ok "Matched on OMDb."
    else
        warn "No OMDb match — using cleaned disc label."
    fi

    info "Selected main feature: ${WHITE}${BOLD}${NAME}${RESET} ${GRAY}(${SIZE_HUMAN})${RESET}"

    TARGET="$DST/$NAME"

    N=2

    while [[ -e "$TARGET" ]]
    do
        TARGET="$DST/$NAME ($N)"
        ((N++))
    done

    mkdir -p "$TARGET"

    DEST_FILE="$TARGET/$(basename "$TARGET").mkv"

    if ! mv "$FILE" "$DEST_FILE"; then

        err "Move failed — file left in place, nothing deleted."
        step "$FILE"

        eject "$DEV" >/dev/null 2>&1 && ok "Disc ejected." \
            || warn "Eject failed — remove disc manually."

        return 1

    fi

    # Verify the file actually landed before touching leftovers.
    # Protects against a `mv` that reports success but didn't
    # actually complete (rare, but possible on flaky mounts).
    if [[ ! -f "$DEST_FILE" ]]; then

        err "Move reported success but destination file is missing."
        warn "Leftover cleanup skipped to avoid data loss."

        eject "$DEV" >/dev/null 2>&1 && ok "Disc ejected." \
            || warn "Eject failed — remove disc manually."

        return 1

    fi

    ok "Imported to:"
    step "$DEST_FILE"

    LEFTOVER=$(find "$SRC" -maxdepth 1 -name "*.mkv" | wc -l)

    if [[ "$LEFTOVER" -gt 0 ]]; then

        info "Removing ${LEFTOVER} leftover title(s)..."

        find "$SRC" \
            -maxdepth 1 \
            -name "*.mkv" \
            -delete

        ok "Cleanup complete."

    fi

    if eject "$DEV" >/dev/null 2>&1; then
        ok "Disc ejected."
    else
        warn "Eject failed — remove disc manually."
    fi

    echo
    hr
    printf "${GREEN}${BOLD}  🎬  Done: %s${RESET}\n" "$NAME"
    hr
    echo

}

# ==========================================================
# Main
# ==========================================================

banner

mkdir -p "$SRC"

# ---- Single-instance lock ----
# Prevents two watchdog instances from racing on the same
# SRC directory (which could cause one instance's cleanup
# to delete another instance's in-flight rip).
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    err "Another instance is already running (lock: $LOCKFILE)."
    exit 1
fi

section "Startup Checks"

if ! command -v makemkvcon >/dev/null 2>&1
then
    err "makemkvcon not found."
    step "Install makemkv-bin / makemkv-oss."
    exit 1
fi

ok "MakeMKV found."

if [[ ! -b "$DEV" ]]
then
    err "Optical drive not found: $DEV"
    exit 1
fi

ok "Optical drive detected. ${GRAY}(${DEV})${RESET}"

if ! command -v flock >/dev/null 2>&1
then
    warn "flock not found — single-instance lock is disabled."
fi

if [[ -z "$OMDB_API_URL" ]]; then
    warn "No OMDB_API_URL set — titles will use raw disc labels."
    step "Add one to: $CONF_FILE"
elif ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "curl/jq missing — OMDb lookup disabled, using disc labels."
    step "Install: apt install curl jq"
else
    ok "OMDb lookup enabled."
fi

echo
hr
echo -e "${GRAY}Insert a disc at any time. Press ${WHITE}Ctrl+C${GRAY} to quit.${RESET}"
hr

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
        spin_wait

    fi

    sleep "$POLL_INTERVAL"

done
