#!/usr/bin/env bash
# provision-image.sh - Raspberry Pi SD card preparation for Mac/Linux
#
# Two modes:
#
#   Full mode (--image-path provided):
#     1. Flashes the OS image via rpi-imager CLI or dd.
#     2. Writes firstrun.sh (hostname, user, SSH, WiFi, locale).
#     3. Writes station.conf (GitHub PAT, registration secret, etc.).
#
#   Provision-only mode (--image-path omitted):
#     Writes station.conf to an already-mounted boot partition.
#
# Secrets are prompted securely unless a saved encrypted value is available.
#
# Usage: ./provision-image.sh [--image-path PATH] [options]
#        ./provision-image.sh --help

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

step() { printf "  ${CYAN}-> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}OK %s${NC}\n" "$*"; }
warn() { printf "  ${YELLOW}** %s${NC}\n" "$*"; }
fail() { printf "  ${RED}XX %s${NC}\n" "$*" >&2; exit 1; }

_tty_read_secret() {
    # Core silent read with bracketed-paste protection (shared by read_secure variants).
    local val old_stty
    printf '\e[?2004l' >/dev/tty
    old_stty=$(stty -g </dev/tty 2>/dev/null || true)
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r val </dev/tty
    val="${val%$'\r'}"  # Strip trailing CR in case terminal sends CR+LF on Enter
    [[ -n "$old_stty" ]] && stty "$old_stty" </dev/tty 2>/dev/null || true
    printf '\e[?2004h' >/dev/tty
    printf '\n' >/dev/tty
    printf '%s' "$val"
}

read_secure() {
    local prompt="$1"
    printf '%s: ' "$prompt" >/dev/tty
    _tty_read_secret
}

# ── Encryption helpers (AES-256-CBC, key derived from machine UUID + username) ─
# Equivalent to DPAPI on Windows: ties saved credentials to this machine/user.

get_machine_key() {
    local machine_id user_id
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        machine_id=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
            | awk -F'"' '/IOPlatformUUID/{print $4}' 2>/dev/null || true)
        [[ -z "$machine_id" ]] && warn "Could not read machine UUID via ioreg - saved credentials may not decrypt correctly"
    else
        machine_id=$(cat /etc/machine-id 2>/dev/null \
            || cat /var/lib/dbus/machine-id 2>/dev/null || true)
    fi
    user_id="${USER:-$(id -un 2>/dev/null || true)}"
    printf '%s:%s' "${machine_id:-no-machine-id}" "$user_id"
}

# NOTE: -A keeps the base64 on a single line for BOTH encode and decode. Without
# it, OpenSSL 3.x writes wrapped base64 and then refuses to decode the flattened
# single-line value on the next run ("error reading input file"), so a saved
# credential never decrypts and always looks like it was "saved on another
# machine". -A must be present on encrypt and decrypt together.
encrypt_value() {
    local plain="$1"
    if [[ -z "$plain" ]]; then printf ''; return; fi
    printf '%s' "$plain" \
        | openssl enc -aes-256-cbc -md sha256 \
            -pass pass:"$(get_machine_key)" -base64 -A 2>/dev/null \
        || true
}

decrypt_value() {
    local enc="$1"
    if [[ -z "$enc" ]]; then printf ''; return; fi
    printf '%s' "$enc" \
        | openssl enc -d -aes-256-cbc -md sha256 \
            -pass pass:"$(get_machine_key)" -base64 -A 2>/dev/null \
        || true
}

# ── Store web address (subdomain label) ───────────────────────────────────────
# A store's address label is the DNS label of its subdomain, so it is capped at the RFC 1035
# limit of 63 characters. These mirror validate_slug()/propose_slug() in the server's
# db_manager.py. The SERVER remains the authority - it re-validates on write and now uses the
# label confirmed here verbatim - so this copy exists only to let the address be chosen and
# checked at imaging time, with no network access.
SLUG_MAX_LENGTH=63
RESERVED_SLUGS=" www admin api mail ftp static media app "

# The public domain stores are reachable under. Deliberately independent of SERVER_URL: a card
# built against a local dev server still shows the production address, because that is where the
# store will actually live once it is accepted.
STORE_DOMAIN="shopperdb.com"

slugify() {
    # Lowercase, drop apostrophes, reduce anything else to single hyphens, trim the ends.
    # Transliterates accents when iconv can (cafe, not caf); falls back to dropping them.
    local raw="$1" out
    out=$(printf '%s' "$raw" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$raw")
    printf '%s' "$out" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e "s/['\`]//g" \
              -e 's/[^a-z0-9]\{1,\}/-/g' \
              -e 's/^-\{1,\}//' \
              -e 's/-\{1,\}$//'
}

slug_invalid_reason() {
    # Echo why $1 cannot be used as a store address, or nothing when it is fine.
    local slug="$1"
    if [[ -z "$slug" ]]; then
        printf 'Address cannot be empty.'
    elif (( ${#slug} > SLUG_MAX_LENGTH )); then
        printf 'Address is %d characters; the maximum is %d because it is a subdomain name.'             "${#slug}" "$SLUG_MAX_LENGTH"
    elif [[ ! "$slug" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        printf 'Use lowercase letters, numbers and hyphens only, not starting or ending with a hyphen.'
    elif [[ "$slug" == *--* ]]; then
        printf 'Address cannot contain two hyphens in a row.'
    elif [[ "$RESERVED_SLUGS" == *" $slug "* ]]; then
        printf "'%s' is reserved and cannot be used as a store address." "$slug"
    fi
}

propose_slug() {
    # Build "<name>-<city>-<state>", shortening only the NAME if the whole thing will not fit.
    # The city/state tail is what distinguishes two stores sharing a name, so it is never cut.
    local name_part city_part state_part tail full budget clipped
    name_part=$(slugify "$1")
    city_part=$(slugify "$2")
    state_part=$(slugify "$3")

    tail=""
    [[ -n "$city_part"  ]] && tail="$city_part"
    [[ -n "$state_part" ]] && tail="${tail:+$tail-}$state_part"

    full="$name_part"
    [[ -n "$tail" ]] && full="${full:+$full-}$tail"
    if (( ${#full} <= SLUG_MAX_LENGTH )); then
        printf '%s' "$full"
        return
    fi

    if [[ -z "$tail" ]]; then
        printf '%s' "$(printf '%s' "${name_part:0:SLUG_MAX_LENGTH}" | sed 's/-\{1,\}$//')"
        return
    fi

    budget=$(( SLUG_MAX_LENGTH - ${#tail} - 1 ))
    if (( budget <= 0 )); then
        # A tail this long leaves no room for a name; keep what fits of the tail.
        printf '%s' "$(printf '%s' "${tail:0:SLUG_MAX_LENGTH}" | sed 's/-\{1,\}$//')"
        return
    fi

    clipped="${name_part:0:budget}"
    # Prefer a whole word over a severed one, as long as something survives.
    if [[ "$clipped" == *-* && ${#name_part} -gt $budget ]]; then
        clipped="${clipped%-*}"
    fi
    clipped=$(printf '%s' "$clipped" | sed 's/-\{1,\}$//')
    if [[ -n "$clipped" ]]; then
        printf '%s-%s' "$clipped" "$tail"
    else
        printf '%s' "$tail"
    fi
}

prompt_line() {
    local prompt="$1" default="${2:-}" val
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    read -r val </dev/tty
    printf '%s' "${val:-$default}"
}

# ── Defaults ──────────────────────────────────────────────────────────────────

IMAGE_PATH=""
DISK_DEVICE=""
BOOT_MOUNT=""

PI_HOSTNAME="sbc-shopperdb"
PI_USERNAME="admin"
TIMEZONE="America/New_York"
KEYBOARD_LAYOUT="us"

WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_COUNTRY="US"
WIFI_SECURITY="wpa2"
WIFI_HIDDEN="false"

LOCALE="en_US.UTF-8"

# Cards are built for the production site. --server-url overrides it for local testing; the
# override is never remembered between runs, so a dev URL cannot silently ship on a real card.
DEFAULT_SERVER_URL="https://shopperdb.com"
SERVER_URL=""
REGISTRATION_SECRET=""
GITHUB_PAT=""
ADMIN_SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

STORE_NAME=""
STORE_CITY=""
STORE_STATE=""
STORE_SLUG=""
PRINT_SLUG="false"
RECONFIRM_ADDRESS="false"
SKIP_STORE_CREATE="false"
SKIP_TEST_PRINT="false"
LCD_DISPLAY="false"
SKIP_FLASH="false"

STATIC_IP=""
STATIC_GATEWAY=""
STATIC_PREFIX="24"
STATIC_DNS="8.8.8.8,1.1.1.1"

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./create-image.sh [options]

  --image-path PATH          .img or .img.xz file (triggers full mode)
  --disk DEVICE              SD card device (e.g. /dev/disk4 or /dev/sdb)
  --boot-mount PATH          Boot partition mount (e.g. /Volumes/bootfs)

  --hostname NAME            Pi hostname (default: sbc-shopperdb)
  --username NAME            Pi OS user to create (default: admin)
  --timezone TZ              Timezone (default: America/New_York)
  --keyboard LAYOUT          Keyboard layout (default: us)
  --locale LOCALE            System locale (default: en_US.UTF-8)

  --wifi-ssid SSID           WiFi SSID (omit for Ethernet-only)
  --wifi-password PASS       WiFi password (prompted if SSID is set)
  --wifi-country CODE        WiFi country code (default: US)
  --wifi-security TYPE       wpa2 (default) or open
  --wifi-hidden              Network has a hidden SSID

  --server-url URL           Override the server the station registers with.
                             Default: https://shopperdb.com. Use only to point a
                             test card at a local dev server, e.g.
                             --server-url http://192.168.2.100:8000
                             Never remembered between runs.
  --registration-secret S    Registration secret supplied by ShopperDB
  --github-pat TOKEN         GitHub access token supplied by ShopperDB
  --admin-ssh-key PATH       Admin SSH public key (default: ~/.ssh/id_ed25519.pub)
                             Pass "" to skip

  --store-name NAME          Store display name (e.g. "Steve's Wheels and Deals")
  --store-city CITY          Store city, used in the store web address
  --store-state ST           Store state, 2 letters, used in the store web address
  --store-slug SLUG          Store web address label (skips the confirmation prompt)
  --reconfirm-address        Re-confirm the store web address even when the saved one
                             still applies (normally it is only asked for once)
  --print-slug               Print the proposed store address and exit (no image work)
                             If set, a public store page is created when the admin accepts the station.
  --skip-store-create        Suppress public store page creation (default: off)
  --skip-test-print          Skip printer test label during first provisioning run (default: off)
  --lcd-display              Configure a 7-inch 1024x600 HDMI LCD (default: off)
                             The Pi detects its own model on first boot and writes
                             the matching HDMI/USB power settings. Build a dedicated
                             image with this flag; do not use it for TV/headless units.

  --skip-flash               Skip flashing; write firstrun.sh and station.conf to an already-flashed SD card

  --static-ip IP             Static IP (omit for DHCP)
  --static-gateway GW        Default gateway
  --static-prefix N          Network prefix length (default: 24)
  --static-dns DNS           DNS servers (default: 8.8.8.8,1.1.1.1)

  --help                     Show this help

Examples:
  Full mode (flash + configure):
    ./create-image.sh --image-path ~/Downloads/raspios-trixie-arm64-lite.img.xz

  Skip flash (already-flashed card, write firstrun.sh + station.conf):
    ./create-image.sh --skip-flash

  Provision-only (already flashed card):
    ./create-image.sh
EOF
    exit 0
}

_explicit=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-path)          IMAGE_PATH="$2";                                    shift 2 ;;
        --disk)                DISK_DEVICE="$2";                                   shift 2 ;;
        --boot-mount)          BOOT_MOUNT="$2";                                    shift 2 ;;
        --hostname)            PI_HOSTNAME="$2";   _explicit+=(Hostname);          shift 2 ;;
        --username)            PI_USERNAME="$2";   _explicit+=(Username);          shift 2 ;;
        --timezone)            TIMEZONE="$2";      _explicit+=(Timezone);          shift 2 ;;
        --keyboard)            KEYBOARD_LAYOUT="$2"; _explicit+=(KeyboardLayout);  shift 2 ;;
        --locale)              LOCALE="$2";        _explicit+=(Locale);            shift 2 ;;
        --wifi-ssid)           WIFI_SSID="$2";     _explicit+=(WifiSsid);          shift 2 ;;
        --wifi-password)       WIFI_PASSWORD="$2";                                 shift 2 ;;
        --wifi-country)        WIFI_COUNTRY="$2";  _explicit+=(WifiCountry);       shift 2 ;;
        --wifi-security)       WIFI_SECURITY="$2"; _explicit+=(WifiSecurity);      shift 2 ;;
        --wifi-hidden)         WIFI_HIDDEN="true"; _explicit+=(WifiHidden);        shift   ;;
        --server-url)          SERVER_URL="$2";    _explicit+=(ServerUrl);         shift 2 ;;
        --registration-secret) REGISTRATION_SECRET="$2"; _explicit+=(RegistrationSecret); shift 2 ;;
        --github-pat)          GITHUB_PAT="$2";          _explicit+=(GithubPat);          shift 2 ;;
        --admin-ssh-key)       ADMIN_SSH_KEY_PATH="$2"; _explicit+=(AdminSshKeyPath); shift 2 ;;
        --store-name)          STORE_NAME="$2";    _explicit+=(StoreName);         shift 2 ;;
        --store-city)          STORE_CITY="$2";    _explicit+=(StoreCity);         shift 2 ;;
        --store-state)         STORE_STATE="$2";   _explicit+=(StoreState);        shift 2 ;;
        --store-slug)          STORE_SLUG="$2";    _explicit+=(StoreSlug);         shift 2 ;;
        --reconfirm-address)   RECONFIRM_ADDRESS="true";                            shift   ;;
        --print-slug)          PRINT_SLUG="true";                                   shift   ;;
        --skip-store-create)   SKIP_STORE_CREATE="true"; _explicit+=(SkipStoreCreate); shift ;;
        --skip-test-print)     SKIP_TEST_PRINT="true"; _explicit+=(SkipTestPrint); shift   ;;
        --lcd-display)         LCD_DISPLAY="true";     _explicit+=(LcdDisplay);     shift   ;;
        --skip-flash)          SKIP_FLASH="true";                                   shift   ;;
        --reset-defaults)      RESET_DEFAULTS="true";                               shift   ;;
        --static-ip)           STATIC_IP="$2";     _explicit+=(StaticIp);          shift 2 ;;
        --static-gateway)      STATIC_GATEWAY="$2"; _explicit+=(StaticGateway);   shift 2 ;;
        --static-prefix)       STATIC_PREFIX="$2"; _explicit+=(StaticPrefix);      shift 2 ;;
        --static-dns)          STATIC_DNS="$2";    _explicit+=(StaticDns);         shift 2 ;;
        --help|-h)             usage ;;
        *) fail "Unknown option: $1. Run with --help for usage." ;;
    esac
done

OS_TYPE="$(uname -s)"  # Darwin or Linux
FULL_MODE=false
[[ -n "$IMAGE_PATH" ]] && FULL_MODE=true
[[ "$SKIP_FLASH" == "true" ]] && FULL_MODE=true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESET_DEFAULTS="${RESET_DEFAULTS:-false}"

# ── --print-slug: report the proposed store address and exit ──────────────────
# A utility mode, not part of imaging: it answers "what would this store's web address be?"
# without touching a card. Also what the tests exercise, so the address rules stay covered.
if [[ "$PRINT_SLUG" == "true" ]]; then
    if [[ -z "$STORE_NAME" ]]; then
        fail "--print-slug needs --store-name"
    fi
    _proposed="${STORE_SLUG:-$(propose_slug "$STORE_NAME" "$STORE_CITY" "$STORE_STATE")}"
    _reason=$(slug_invalid_reason "$_proposed")
    if [[ -n "$_reason" ]]; then
        fail "$_reason"
    fi
    printf '%s\n' "$_proposed"
    exit 0
fi

# ── Saved defaults ────────────────────────────────────────────────────────────

DEFAULTS_FILE="$SCRIPT_DIR/.create-image.defaults.json"

if [[ "$RESET_DEFAULTS" == "true" && -f "$DEFAULTS_FILE" ]]; then
    rm -f "$DEFAULTS_FILE"
    ok "Saved defaults cleared (--reset-defaults)"
fi

_was_explicit() { local k="$1"; [[ " ${_explicit[*]} " == *" $k "* ]]; }

_load_saved() {
    local key="$1" fallback="${2:-}"
    local val
    # utf-8-sig, not utf-8: create-image.ps1 writes the shared defaults file with a BOM, and a
    # plain utf-8 read fails on it - silently, making every saved value look absent.
    val=$(DEFAULTS_FILE_PATH="$DEFAULTS_FILE" LOOKUP_KEY="$key" \
        python3 -c "import json,os; d=json.load(open(os.environ['DEFAULTS_FILE_PATH'], encoding='utf-8-sig')); print(d.get(os.environ['LOOKUP_KEY'],''))" \
        2>/dev/null) || true
    printf '%s' "${val:-$fallback}"
}

# SkipTestPrint and SkipStoreCreate are intentionally not loaded from defaults:
# they are one-time run flags (always false unless explicitly passed), not
# persistent preferences. Omitting them always means false, never the last
# cached value.
if [[ -f "$DEFAULTS_FILE" ]] && command -v python3 &>/dev/null; then
    _was_explicit Hostname       || PI_HOSTNAME=$(_load_saved Hostname "$PI_HOSTNAME")
    _was_explicit Username       || PI_USERNAME=$(_load_saved Username "$PI_USERNAME")
    _was_explicit Timezone       || TIMEZONE=$(_load_saved Timezone "$TIMEZONE")
    _was_explicit KeyboardLayout || KEYBOARD_LAYOUT=$(_load_saved KeyboardLayout "$KEYBOARD_LAYOUT")
    _was_explicit Locale         || LOCALE=$(_load_saved Locale "$LOCALE")
    _was_explicit WifiSsid       || WIFI_SSID=$(_load_saved WifiSsid "$WIFI_SSID")
    _was_explicit WifiCountry    || WIFI_COUNTRY=$(_load_saved WifiCountry "$WIFI_COUNTRY")
    _was_explicit WifiSecurity   || WIFI_SECURITY=$(_load_saved WifiSecurity "$WIFI_SECURITY")
    _was_explicit WifiHidden     || WIFI_HIDDEN=$(_load_saved WifiHidden "$WIFI_HIDDEN")
    # ServerUrl is deliberately NOT restored - see DEFAULT_SERVER_URL.
    _was_explicit AdminSshKeyPath || ADMIN_SSH_KEY_PATH=$(_load_saved AdminSshKeyPath "$ADMIN_SSH_KEY_PATH")
    _was_explicit StoreName      || STORE_NAME=$(_load_saved StoreName "$STORE_NAME")
    _was_explicit StoreCity      || STORE_CITY=$(_load_saved StoreCity "$STORE_CITY")
    _was_explicit StoreState     || STORE_STATE=$(_load_saved StoreState "$STORE_STATE")
    _was_explicit StaticIp       || STATIC_IP=$(_load_saved StaticIp "$STATIC_IP")
    _was_explicit StaticGateway  || STATIC_GATEWAY=$(_load_saved StaticGateway "$STATIC_GATEWAY")
    _was_explicit StaticPrefix   || STATIC_PREFIX=$(_load_saved StaticPrefix "$STATIC_PREFIX")
    _was_explicit StaticDns      || STATIC_DNS=$(_load_saved StaticDns "$STATIC_DNS")
fi

# The store identity from the previous run, kept separate from the working values so the two
# can be compared. If the name/city/state are unchanged, the address confirmed last time still
# applies and is reused rather than asked about again.
_SAVED_STORE_NAME=$(_load_saved "StoreName")
_SAVED_STORE_CITY=$(_load_saved "StoreCity")
_SAVED_STORE_STATE=$(_load_saved "StoreState")
_SAVED_STORE_SLUG=$(_load_saved "StoreSlug")

# Load saved encrypted credentials (machine-bound; empty if not present or different machine)
_SAVED_WIFI_PW_ENC=$(_load_saved "WifiPasswordEnc")
_SAVED_GITHUB_PAT_ENC=$(_load_saved "GithubPatEnc")
_SAVED_REG_SEC_ENC=$(_load_saved "RegistrationSecretEnc")

# ── Header ────────────────────────────────────────────────────────────────────

printf '\n'
printf "${CYAN}================================================${NC}\n"
printf "${CYAN}  ShopperDB Pi - Image Preparation${NC}\n"
printf "${CYAN}================================================${NC}\n"
if [[ "$SKIP_FLASH" == "true" ]]; then
    printf "${GRAY}  Mode: Customise + Provision (flash skipped)${NC}\n"
elif $FULL_MODE; then
    printf "${GRAY}  Mode: Flash + Customise + Provision${NC}\n"
else
    printf "${GRAY}  Mode: Provision only${NC}\n"
fi
printf '\n'

# ── Disk helpers ──────────────────────────────────────────────────────────────

find_rpi_imager() {
    local candidate
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for candidate in \
            "/Applications/Imager.app/Contents/MacOS/rpi-imager" \
            "/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"; do
            [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    else
        for candidate in "/usr/bin/rpi-imager" "/usr/local/bin/rpi-imager"; do
            [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    fi
    command -v rpi-imager 2>/dev/null || return 1
}

find_boot_mount() {
    local mp
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for mp in /Volumes/bootfs /Volumes/*/; do
            mp="${mp%/}"
            [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
        done
    else
        for mp in \
            "/media/$USER/bootfs" \
            "/media/bootfs" \
            "/run/media/$USER/bootfs" \
            "/mnt/bootfs"; do
            [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
        done
        if command -v findmnt &>/dev/null; then
            while IFS= read -r mp; do
                [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
            done < <(findmnt -n -l -o TARGET 2>/dev/null)
        fi
    fi
    return 1
}

# ── Step 1: Collect and validate all inputs (before flashing or writing) ──────
# Everything the image needs is gathered and checked HERE FIRST, so a bad value
# (mis-pasted PAT, wrong secret, missing SSH key) fails now - before minutes are
# spent flashing the card. Steps 2+ only write; they no longer prompt.

printf '\n'
printf "${CYAN}================================================${NC}\n"
printf "${CYAN}  Step 1: Configuration${NC}\n"
printf "${CYAN}================================================${NC}\n"
printf '\n'

# GitHub PAT - used to clone the private repo on the Pi and to fetch the admin hash.
if [[ -z "$GITHUB_PAT" ]]; then
    _was_explicit GithubPat && fail "GITHUB_PAT is required."
    _saved_github_pat_plain=$(decrypt_value "$_SAVED_GITHUB_PAT_ENC")
    if [[ -n "$_saved_github_pat_plain" ]]; then
        GITHUB_PAT="$_saved_github_pat_plain"
        ok "GitHub PAT: using saved value"
    else
        [[ -n "$_SAVED_GITHUB_PAT_ENC" ]] && warn "Saved GitHub PAT cannot be decrypted (saved on a different machine) - please re-enter"
        GITHUB_PAT=$(read_secure "GitHub access token (provided by ShopperDB)")
    fi
fi
[[ -n "$GITHUB_PAT" ]] || fail "GITHUB_PAT is required."
[[ "$GITHUB_PAT" == ghp_* || "$GITHUB_PAT" == github_pat_* ]] || warn "PAT does not look like a GitHub token (expected ghp_ or github_pat_ prefix)"

# Verify the token can actually read the private repo NOW, so a mis-pasted or
# wrong-scope PAT is caught here instead of on the Pi's first-boot clone.
# Only when we are about to flash - the whole point is to fail before the slow,
# destructive write. Provision-only / --skip-flash runs (and offline use) write
# station.conf without the network check.
if $FULL_MODE && [[ "$SKIP_FLASH" != "true" ]]; then
    step "Verifying the GitHub token can read shopperdb..."
    if git ls-remote "https://x-access-token:${GITHUB_PAT}@github.com/shopperdb-dot-com/shopperdb.git" HEAD >/dev/null 2>&1; then
        ok "GitHub PAT: validated (repo is readable)"
    else
        fail "GitHub PAT cannot read shopperdb-dot-com/shopperdb (bad token, wrong scope, or no network). Re-run and re-enter the token."
    fi
fi

# Admin password hash (full mode only - baked into firstrun.sh). Local file, or
# fetched from the private repo with the now-validated PAT.
if $FULL_MODE; then
    ADMIN_PW_HASH=""
    _admin_hash_file="$SCRIPT_DIR/admin_password.hash"
    if [[ ! -f "$_admin_hash_file" ]]; then
        _admin_hash_file="$(cd "$SCRIPT_DIR/.." && pwd)/shopperdb/client/scripts/admin_password.hash"
    fi
    if [[ -f "$_admin_hash_file" ]]; then
        ADMIN_PW_HASH=$(tr -d '[:space:]' < "$_admin_hash_file")
        ok "Admin password: loaded from $(basename "$_admin_hash_file")"
    else
        step "Admin password hash not found locally - fetching from shopperdb repo..."
        ADMIN_PW_HASH=$(curl -fsSL \
            -H "Authorization: Bearer $GITHUB_PAT" \
            -H "Accept: application/vnd.github.raw+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/shopperdb-dot-com/shopperdb/contents/client/scripts/admin_password.hash" \
            2>/dev/null | tr -d '[:space:]') || true
        if [[ -n "$ADMIN_PW_HASH" ]]; then
            ok "Admin password: fetched from shopperdb repo"
        else
            fail "Could not load admin_password.hash - local file not found and GitHub fetch failed. Ensure the GitHub PAT has read access to shopperdb."
        fi
    fi
    if [[ ! "$ADMIN_PW_HASH" =~ ^\$6\$[a-zA-Z0-9./]{1,16}\$[a-zA-Z0-9./]{86}$ ]]; then
        fail "admin_password.hash does not contain a valid SHA-512 crypt hash (expected: \$6\$<1-16 char salt>\$<86 char hash>)."
    fi
fi

# Server URL - the production site unless --server-url points somewhere else. No prompt: for a
# real card there is only one right answer, and asking every time invites a mistyped one.
[[ -n "$SERVER_URL" ]] || SERVER_URL="$DEFAULT_SERVER_URL"
[[ "$SERVER_URL" =~ ^https?:// ]] || fail "Server URL must start with http:// or https:// (got '$SERVER_URL')"
SERVER_URL="${SERVER_URL%/}"
if [[ "$SERVER_URL" == "$DEFAULT_SERVER_URL" ]]; then
    ok "Server URL: $SERVER_URL"
else
    # Loud on purpose: a card pointed at a laptop looks identical to a real one until it boots.
    warn "Server URL: $SERVER_URL (override - the default is $DEFAULT_SERVER_URL)"
fi

# Registration secret
if [[ -z "$REGISTRATION_SECRET" ]]; then
    _was_explicit RegistrationSecret && fail "REGISTRATION_SECRET is required."
    _saved_reg_plain=$(decrypt_value "$_SAVED_REG_SEC_ENC")
    if [[ -n "$_saved_reg_plain" ]]; then
        REGISTRATION_SECRET="$_saved_reg_plain"
        ok "Registration secret: using saved value"
    else
        [[ -n "$_SAVED_REG_SEC_ENC" ]] && warn "Saved registration secret cannot be decrypted (saved on a different machine) - please re-enter"
        REGISTRATION_SECRET=$(read_secure "Registration secret (from server configuration)")
    fi
fi
[[ -n "$REGISTRATION_SECRET" ]] || fail "REGISTRATION_SECRET is required."
ok "Registration secret: provided"

# Admin SSH public key (optional - enables passwordless SSH, disables password auth)
ADMIN_SSH_KEY=""
if [[ -n "$ADMIN_SSH_KEY_PATH" && -f "$ADMIN_SSH_KEY_PATH" ]]; then
    key_content=$(cat "$ADMIN_SSH_KEY_PATH")
    if [[ "$key_content" == ssh-* ]]; then
        ADMIN_SSH_KEY="$key_content"
        ok "Admin SSH key: $ADMIN_SSH_KEY_PATH"
    else
        warn "Not an SSH public key: $ADMIN_SSH_KEY_PATH"
    fi
elif [[ -n "$ADMIN_SSH_KEY_PATH" ]]; then
    warn "Admin SSH key not found: $ADMIN_SSH_KEY_PATH - password auth remains active"
fi

# Store display name (optional)
if [[ -z "$STORE_NAME" ]] && ! _was_explicit StoreName; then
    STORE_NAME=$(prompt_line "Store display name (optional - Enter to skip)" "")
fi
if [[ -z "$STORE_NAME" ]]; then
    ok "Store name: (none - no public store page)"
elif [[ "$SKIP_STORE_CREATE" == "true" ]]; then
    ok "Store name: $STORE_NAME"
    ok "Store address: (none - SKIP_STORE_CREATE is set, so no store page is created)"
    STORE_CITY=""; STORE_STATE=""; STORE_SLUG=""
else
    ok "Store name: $STORE_NAME"

    # City and state are part of the address because they are what distinguishes two stores
    # sharing a name. Collected here so the address can be confirmed before the card is written.
    if [[ -z "$STORE_CITY" ]] && ! _was_explicit StoreCity; then
        STORE_CITY=$(prompt_line "Store city" "")
    fi
    while [[ -z "$STORE_STATE" ]] || [[ ! "$STORE_STATE" =~ ^[A-Za-z]{2}$ ]]; do
        if _was_explicit StoreState && [[ -n "$STORE_STATE" ]]; then
            fail "Store state must be 2 letters (got '$STORE_STATE')"
        fi
        STORE_STATE=$(prompt_line "Store state (2 letters)" "")
        [[ "$STORE_STATE" =~ ^[A-Za-z]{2}$ ]] || warn "State must be exactly 2 letters."
    done
    STORE_STATE=$(printf '%s' "$STORE_STATE" | tr '[:lower:]' '[:upper:]')

    # An address accepted on an earlier run is reused without asking again: it was already
    # confirmed, and a second card for the same store has to land on the same subdomain.
    # Comparing the slugified inputs (not the raw text) means "watertown" and "Watertown" are
    # the same answer, while any change that would actually move the address - a different
    # name, city or state - drops through to a fresh confirmation. So does --reconfirm-address.
    _address_reused="false"
    if [[ -z "$STORE_SLUG" && "$RECONFIRM_ADDRESS" != "true" && -n "$_SAVED_STORE_SLUG" ]] \
       && [[ "$(slugify "$STORE_NAME")"  == "$(slugify "$_SAVED_STORE_NAME")"  ]] \
       && [[ "$(slugify "$STORE_CITY")"  == "$(slugify "$_SAVED_STORE_CITY")"  ]] \
       && [[ "$(slugify "$STORE_STATE")" == "$(slugify "$_SAVED_STORE_STATE")" ]] \
       && [[ -z "$(slug_invalid_reason "$_SAVED_STORE_SLUG")" ]]; then
        STORE_SLUG="$_SAVED_STORE_SLUG"
        _address_reused="true"
    fi

    # Confirm the web address. The proposal shortens only the store name when the whole thing
    # will not fit; nothing is applied without being shown and accepted.
    while true; do
        if [[ -z "$STORE_SLUG" ]]; then
            _proposed=$(propose_slug "$STORE_NAME" "$STORE_CITY" "$STORE_STATE")
            printf '\n  Proposed store address (%d/%d characters):\n    %s\n\n' \
                "${#_proposed}" "$SLUG_MAX_LENGTH" "https://${_proposed}.${STORE_DOMAIN}" >/dev/tty
            STORE_SLUG=$(prompt_line "Press Enter to accept, or type a different address" "$_proposed")
            # Normalize what was typed (case, spaces, punctuation). Length is never adjusted -
            # a too-long address is reported so a person decides what to shorten.
            STORE_SLUG=$(slugify "$STORE_SLUG")
        fi
        _reason=$(slug_invalid_reason "$STORE_SLUG")
        [[ -z "$_reason" ]] && break
        if _was_explicit StoreSlug; then
            fail "$_reason"
        fi
        warn "$_reason"
        STORE_SLUG=""
        _address_reused="false"
    done
    if [[ "$_address_reused" == "true" ]]; then
        ok "Store address: https://${STORE_SLUG}.${STORE_DOMAIN} (confirmed on an earlier run - --reconfirm-address to change it)"
    else
        ok "Store address: https://${STORE_SLUG}.${STORE_DOMAIN} (${#STORE_SLUG}/$SLUG_MAX_LENGTH characters)"
    fi
fi

# WiFi password (only when a secured WiFi SSID is configured)
if [[ -n "$WIFI_SSID" && "$WIFI_SECURITY" != "open" && -z "$WIFI_PASSWORD" ]]; then
    _saved_wifi_pw_plain=$(decrypt_value "$_SAVED_WIFI_PW_ENC")
    if [[ -n "$_saved_wifi_pw_plain" ]]; then
        WIFI_PASSWORD="$_saved_wifi_pw_plain"
        ok "WiFi password: using saved value"
    else
        WIFI_PASSWORD=$(read_secure "WiFi password for '$WIFI_SSID'")
        wifi_pw_confirm=$(read_secure "Confirm WiFi password for '$WIFI_SSID'")
        [[ "$WIFI_PASSWORD" == "$wifi_pw_confirm" ]] || fail "WiFi passwords do not match."
    fi
fi

ok "All inputs collected and validated - nothing is written until now"

# ── Step 2: Flash image (full mode only) ──────────────────────────────────────

if $FULL_MODE && [[ "$SKIP_FLASH" != "true" ]]; then
    [[ -f "$IMAGE_PATH" ]] || fail "Image file not found: $IMAGE_PATH"

    if [[ -z "$DISK_DEVICE" ]]; then
        step "Searching for removable disks..."
        printf '\n'

        removable=()
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            printf '  External disks:\n'
            while IFS= read -r line; do
                dev=$(printf '%s' "$line" | awk '{print $1}')
                [[ "$dev" == /dev/disk* ]] || continue
                removable+=("$dev")
                size=$(diskutil info "$dev" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2; exit}')
                printf '    %s  (%s)\n' "$dev" "$size"
            done < <(diskutil list external physical 2>/dev/null)
        else
            printf '  Removable block devices:\n'
            while IFS= read -r line; do
                name=$(printf '%s' "$line" | awk '{print $1}')
                size=$(printf '%s' "$line" | awk '{print $2}')
                tran=$(printf '%s' "$line" | awk '{print $3}')
                hot=$(printf '%s' "$line" | awk '{print $4}')
                if [[ "$hot" == "1" || "$tran" == "usb" ]]; then
                    removable+=("/dev/$name")
                    printf '    /dev/%s  (%s)\n' "$name" "$size"
                fi
            done < <(lsblk -d -n -o NAME,SIZE,TRAN,HOTPLUG 2>/dev/null)
        fi

        printf '\n'
        if [[ ${#removable[@]} -eq 0 ]]; then
            fail "No removable disk found. Insert the SD card and try again."
        elif [[ ${#removable[@]} -eq 1 ]]; then
            DISK_DEVICE="${removable[0]}"
            ok "SD card: $DISK_DEVICE"
        else
            warn "Multiple removable disks found."
            DISK_DEVICE=$(prompt_line "Enter device path (e.g. /dev/disk4 or /dev/sdb)")
        fi
    fi

    printf '\n'
    printf "  ${YELLOW}About to flash:${NC}\n"
    printf "  ${YELLOW}  Source: %s${NC}\n" "$(basename "$IMAGE_PATH")"
    printf "  ${YELLOW}  Target: %s${NC}\n" "$DISK_DEVICE"
    printf "  ${RED}  WARNING: ALL DATA ON THE DISK WILL BE ERASED${NC}\n"
    printf '\n'
    confirm=$(prompt_line "Type YES to continue")
    [[ "${confirm^^}" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }

    step "Unmounting $DISK_DEVICE..."
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        diskutil unmountDisk "$DISK_DEVICE" 2>/dev/null || warn "Could not unmount - proceeding"
    else
        while IFS= read -r mp; do
            [[ -n "$mp" ]] && sudo umount "$mp" 2>/dev/null || true
        done < <(lsblk -n -o MOUNTPOINT "$DISK_DEVICE" 2>/dev/null)
        for part in "${DISK_DEVICE}"*[0-9]; do
            [[ -b "$part" ]] && sudo umount "$part" 2>/dev/null || true
        done
    fi

    imager=$(find_rpi_imager 2>/dev/null || true)
    if [[ -n "$imager" ]]; then
        ok "Raspberry Pi Imager: $imager"
        step "Flashing image (this takes several minutes)..."
        printf '\n'
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            "$imager" --cli "$IMAGE_PATH" "$DISK_DEVICE" || fail "rpi-imager failed."
        else
            sudo "$imager" --cli "$IMAGE_PATH" "$DISK_DEVICE" || fail "rpi-imager failed."
        fi
    else
        warn "rpi-imager not found - falling back to dd."
        if [[ "$IMAGE_PATH" == *.xz ]]; then
            command -v xzcat &>/dev/null || \
                fail "xzcat required for .xz images. Install: 'brew install xz' or 'apt install xz-utils'."
        fi
        step "Flashing via dd (this takes several minutes)..."
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            raw_dev="${DISK_DEVICE/\/dev\/disk//dev/rdisk}"
            printf '  No progress indicator on macOS; SD card LED activity shows writing.\n'
            if [[ "$IMAGE_PATH" == *.xz ]]; then
                xzcat "$IMAGE_PATH" | sudo dd of="$raw_dev" bs=4m
            else
                sudo dd if="$IMAGE_PATH" of="$raw_dev" bs=4m
            fi
        else
            if [[ "$IMAGE_PATH" == *.xz ]]; then
                xzcat "$IMAGE_PATH" | sudo dd of="$DISK_DEVICE" bs=4M status=progress conv=fsync
            else
                sudo dd if="$IMAGE_PATH" of="$DISK_DEVICE" bs=4M status=progress conv=fsync
            fi
        fi
        sudo sync
    fi
    ok "Image written"

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        diskutil eject "$DISK_DEVICE" 2>/dev/null || true
    fi

    printf '\n'
    printf '  Remove and re-insert the SD card, then press Enter...\n'
    read -r </dev/tty

    step "Waiting for boot partition to mount (up to 60 s)..."
    BOOT_MOUNT=""
    elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        BOOT_MOUNT=$(find_boot_mount 2>/dev/null || true)
        [[ -n "$BOOT_MOUNT" ]] && break
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ -z "$BOOT_MOUNT" ]]; then
        warn "Boot partition not detected automatically."
        BOOT_MOUNT=$(prompt_line "Enter boot partition mount path (e.g. /Volumes/bootfs)")
    fi
    ok "Boot partition: $BOOT_MOUNT"
fi  # end if FULL_MODE && ! SKIP_FLASH

# ── Step 3: Find/mount boot partition ─────────────────────────────────────────

if [[ -z "$BOOT_MOUNT" ]]; then
    step "Looking for boot partition (label 'bootfs')..."
    BOOT_MOUNT=$(find_boot_mount 2>/dev/null || true)

    if [[ -n "$BOOT_MOUNT" ]]; then
        ok "Boot partition: $BOOT_MOUNT"
    else
        warn "No boot partition found automatically."
        BOOT_MOUNT=$(prompt_line "Enter boot partition mount path (e.g. /Volumes/bootfs or /media/user/bootfs)")
    fi
fi

[[ -d "$BOOT_MOUNT" ]] || fail "Boot mount path not found: $BOOT_MOUNT"

# ── Step 4: Write firstrun.sh (full mode only) ───────────────────────────────
# All credentials/inputs were collected and validated in Step 1.

if $FULL_MODE; then
    wifi_hidden_int=0
    [[ "$WIFI_HIDDEN" == "true" ]] && wifi_hidden_int=1

    if [[ -n "$WIFI_SSID" ]]; then
        if [[ "$WIFI_SECURITY" == "open" ]]; then
            WIFI_BLOCK='if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '"'"'__SSID__'"'"' '"'"''"'"' '"'"'__COUNTRY__'"'"'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'"'"'WPAEOF'"'"'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=__COUNTRY__

network={
    ssid="__SSID__"
    key_mgmt=NONE
    scan_ssid=__WIFI_HIDDEN_INT__
}
WPAEOF
   chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi'
        else
            WIFI_BLOCK='if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '"'"'__SSID__'"'"' '"'"'__WIFIPW__'"'"' '"'"'__COUNTRY__'"'"'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'"'"'WPAEOF'"'"'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=__COUNTRY__

network={
    ssid="__SSID__"
    psk="__WIFIPW__"
    scan_ssid=__WIFI_HIDDEN_INT__
}
WPAEOF
   chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi'
        fi
    else
        WIFI_BLOCK='# No WiFi configured - Ethernet-only deployment'
    fi

    # Write all substitution values to temp files so Python can read them
    # safely without any shell escaping concerns.
    tmpdir=$(mktemp -d)
    printf '%s' "$PI_HOSTNAME"       > "$tmpdir/hostname"
    printf '%s' "$PI_USERNAME"       > "$tmpdir/username"
    printf '%s' "$WIFI_SSID"         > "$tmpdir/ssid"
    printf '%s' "$WIFI_PASSWORD"     > "$tmpdir/wifipw"
    printf '%s' "$WIFI_COUNTRY"      > "$tmpdir/country"
    printf '%s' "$KEYBOARD_LAYOUT"   > "$tmpdir/keyboard"
    printf '%s' "$TIMEZONE"          > "$tmpdir/timezone"
    printf '%s' "$LOCALE"            > "$tmpdir/locale"
    printf '%s' "$wifi_hidden_int"   > "$tmpdir/wifi_hidden_int"
    printf '%s' "$WIFI_BLOCK"        > "$tmpdir/wifi_block"
    printf '%s' "$ADMIN_PW_HASH"     > "$tmpdir/admin_pw_hash"

    python3 - "$tmpdir" "$BOOT_MOUNT/firstrun.sh" <<'PYEOF'
import sys

tmpdir = sys.argv[1]
dest   = sys.argv[2]

def rd(name):
    with open(f'{tmpdir}/{name}') as f:
        return f.read()

hostname    = rd('hostname')
username    = rd('username')
ssid        = rd('ssid')
wifipw      = rd('wifipw')
country     = rd('country')
keyboard    = rd('keyboard')
timezone    = rd('timezone')
locale      = rd('locale')
wifi_hidden = rd('wifi_hidden_int')
wifi_block    = rd('wifi_block')
admin_pw_hash = rd('admin_pw_hash')

# r-string so backslashes are literal - matches firstrun.sh bash syntax exactly
template = r"""#!/bin/bash
# firstrun.sh - generated by provision-image.sh
set +e

CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
FIRSTUSER=`getent passwd 1000 | cut -d: -f1`
FIRSTUSERHOME=`getent passwd 1000 | cut -d: -f6`

# Hostname
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_hostname __HOSTNAME__
else
   echo __HOSTNAME__ >/etc/hostname
   sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t__HOSTNAME__/g" /etc/hosts
fi

# User account - rename the default UID-1000 user if needed, or create if absent
if [ -n "$FIRSTUSER" ] && [ "$FIRSTUSER" != "__USERNAME__" ]; then
   usermod -l "__USERNAME__" "$FIRSTUSER"
   usermod -m -d /home/__USERNAME__ "__USERNAME__"
   groupmod -n "__USERNAME__" "$FIRSTUSER"
elif [ -z "$FIRSTUSER" ]; then
   useradd -m -s /bin/bash "__USERNAME__"
   usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,input,netdev,gpio,i2c,spi "__USERNAME__" 2>/dev/null || true
fi
# Pi OS Trixie sets the default UID-1000 user shell to /usr/sbin/nologin to
# force the setup wizard. Explicitly set bash so SSH sessions are not rejected.
usermod -s /bin/bash "__USERNAME__"
# Set admin password from hash baked in at image creation time.
# Single quotes prevent bash from expanding the $ signs in the SHA-512 hash.
# firstrun.sh runs as root so no sudo is needed.
printf '%s:%s\n' "__USERNAME__" '__ADMIN_PW_HASH__' | chpasswd -e

# SSH
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh
else
   systemctl enable ssh
fi

# Allow password authentication over SSH (provision.sh can tighten this later)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true

# WiFi
__WIFI_BLOCK__

# Keyboard and timezone
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_keymap '__KEYBOARD__'
   /usr/lib/raspberrypi-sys-mods/imager_custom set_timezone '__TIMEZONE__'
else
   rm -f /etc/localtime
   echo "__TIMEZONE__" >/etc/timezone
   dpkg-reconfigure -f noninteractive tzdata
   cat >/etc/default/keyboard <<'KBEOF'
XKBMODEL="pc105"
XKBLAYOUT="__KEYBOARD__"
XKBVARIANT=""
XKBOPTIONS=""
KBEOF
   dpkg-reconfigure -f noninteractive keyboard-configuration
fi

# Locale
sed -i 's/^# *\(__LOCALE__\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen 2>/dev/null || true
update-locale LANG=__LOCALE__ 2>/dev/null || true

# Headless server target - graphical.target is for desktop environments.
# multi-user.target is the correct default for a server/headless Pi.
systemctl set-default multi-user.target 2>/dev/null || true

# Prevent NetworkManager from blocking boot when the network is not immediately
# available. Without this, the boot hangs at graphical.target waiting for a
# fully established connection before releasing to the login prompt.
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# Disable cloud-init - it looks for a cloud metadata server that does not exist
# on a local network and will hang Boot 2 indefinitely waiting for a response.
touch /etc/cloud/cloud-init.disabled
for svc in cloud-init cloud-init-local cloud-config cloud-final; do
   systemctl disable "$svc" 2>/dev/null || true
   systemctl mask "$svc" 2>/dev/null || true
done

# Disable Pi OS first-boot wizard and Raspberry Pi Connect (rpi-connect).
# userconfig.service owns tty1 on first boot - masking it removes the tty1
# handler entirely. Disable only so it exits cleanly when the user is already
# configured, then explicitly enable the standard getty to take over tty1.
rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true
for svc in raspi-config userconfig; do
   systemctl disable "$svc" 2>/dev/null || true
done
for svc in rpi-connect rpi-connect-wayland-proxy; do
   systemctl disable "$svc" 2>/dev/null || true
   systemctl mask "$svc" 2>/dev/null || true
done
systemctl enable getty@tty1.service 2>/dev/null || true

# Install first_boot.sh and the shopperdb-setup service.
# first_boot.sh (copied from the boot partition) handles: WiFi via NetworkManager,
# git credential configuration, repo clone, full provisioning, and server registration.
# The flag file prevents re-runs; first_boot.sh removes it on success.
mkdir -p /opt/shopperdb /etc/shopperdb
cp /boot/firmware/first_boot.sh /opt/shopperdb/first_boot.sh
chmod +x /opt/shopperdb/first_boot.sh
rm -f /boot/firmware/first_boot.sh
touch /etc/shopperdb/first-boot-pending

cat >/etc/systemd/system/shopperdb-setup.service <<'SVCEOF'
[Unit]
Description=ShopperDB - First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/shopperdb/first-boot-pending

[Service]
Type=oneshot
User=root
Environment="PI_USER=__USERNAME__"
ExecStart=/bin/bash /opt/shopperdb/first_boot.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable shopperdb-setup.service 2>/dev/null || true

# Clean up - remove this script and the kernel cmdline trigger
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt
exit 0
"""

content = template.lstrip('\n')

# Substitute wifi-specific tokens within the block first - these tokens only
# appear inside wifi_block, not in the main template, so they must be resolved
# before the block is inserted.
wifi_block = wifi_block.replace('__SSID__',            ssid)
wifi_block = wifi_block.replace('__WIFIPW__',          wifipw)
wifi_block = wifi_block.replace('__COUNTRY__',         country)
wifi_block = wifi_block.replace('__WIFI_HIDDEN_INT__', wifi_hidden)

content = content.replace('__WIFI_BLOCK__',      wifi_block)
content = content.replace('__HOSTNAME__',        hostname)
content = content.replace('__USERNAME__',        username)
content = content.replace('__ADMIN_PW_HASH__',   admin_pw_hash)
content = content.replace('__KEYBOARD__',        keyboard)
content = content.replace('__TIMEZONE__',        timezone)
content = content.replace('__LOCALE__',          locale)

with open(dest, 'w', newline='\n') as f:
    f.write(content)
PYEOF
    rm -rf "$tmpdir"
    ok "firstrun.sh written: $BOOT_MOUNT/firstrun.sh"

    first_boot_src="$SCRIPT_DIR/first_boot.sh"
    [[ -f "$first_boot_src" ]] || fail "first_boot.sh not found at $first_boot_src"
    tr -d '\r' < "$first_boot_src" > "$BOOT_MOUNT/first_boot.sh"
    ok "first_boot.sh written to boot partition"

    cmdline_path="$BOOT_MOUNT/cmdline.txt"
    if [[ -f "$cmdline_path" ]]; then
        cmdline=$(tr -d '\r\n' < "$cmdline_path")
        if [[ "$cmdline" != *"systemd.run="* ]]; then
            trigger=" systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.run_failure_action=reboot"
            printf '%s\n' "${cmdline}${trigger}" > "$cmdline_path"
            ok "cmdline.txt updated to trigger firstrun.sh on boot"
        else
            ok "cmdline.txt already has systemd.run entry"
        fi
    else
        warn "cmdline.txt not found - firstrun.sh will not run automatically"
    fi
fi

# ── Step 5: Write station.conf ───────────────────────────────────────────────
# All inputs were collected and validated in Step 1.

out_file="$BOOT_MOUNT/station.conf"
step "Writing station.conf to $out_file..."

[[ -n "$ADMIN_SSH_KEY" ]] && admin_line="ADMIN_SSH_KEY='$ADMIN_SSH_KEY'" || admin_line="ADMIN_SSH_KEY="
[[ -n "$WIFI_PASSWORD" ]] && wifi_pass_line="WIFI_PASSWORD='$WIFI_PASSWORD'" || wifi_pass_line="WIFI_PASSWORD="

{
    printf '# station.conf - First-boot configuration for ShopperDB client station\n'
    printf '# Written %s by create-image.sh\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '#\n'
    printf '# Sensitive fields are zeroed automatically after successful first boot.\n'
    printf '\n'
    printf '# REQUIRED\n'
    printf "REGISTRATION_SECRET='%s'\n" "$REGISTRATION_SECRET"
    printf 'SERVER_URL=%s\n' "$SERVER_URL"
    printf "GITHUB_PAT='%s'\n" "$GITHUB_PAT"
    printf '\n'
    printf '# OPTIONAL - Admin SSH public key (enables passwordless SSH, disables password auth)\n'
    printf '%s\n' "$admin_line"
    printf '\n'
    printf '# OPTIONAL - Store display name for this Pi'"'"'s public inventory page.\n'
    printf '# If set, a store page is auto-created when the admin accepts the station.\n'
    if [[ -n "$STORE_NAME" ]]; then
        printf 'STORE_NAME="%s"\n' "$STORE_NAME"
    else
        printf 'STORE_NAME=\n'
    fi
    printf '# The confirmed store web address, and the city/state it was built from. The server\n'
    printf '# uses STORE_SLUG as given rather than deriving one, so the address is what was\n'
    printf '# approved at imaging time.\n'
    printf 'STORE_CITY="%s"\n'  "$STORE_CITY"
    printf 'STORE_STATE="%s"\n' "$STORE_STATE"
    printf 'STORE_SLUG="%s"\n'  "$STORE_SLUG"
    printf 'SKIP_STORE_CREATE=%s\n' "$SKIP_STORE_CREATE"
    printf 'SKIP_TEST_PRINT=%s\n' "$SKIP_TEST_PRINT"
    printf '\n'
    printf '# OPTIONAL - Configure a 7-inch 1024x600 HDMI LCD on first boot.\n'
    printf '# The Pi detects its own model and applies the matching HDMI/USB settings.\n'
    printf 'LCD_DISPLAY=%s\n' "$LCD_DISPLAY"
    printf '\n'
    printf '# OPTIONAL - WiFi (leave blank for Ethernet-only)\n'
    printf 'WIFI_SSID=%s\n' "$WIFI_SSID"
    printf '%s\n' "$wifi_pass_line"
    printf 'WIFI_COUNTRY=%s\n' "$WIFI_COUNTRY"
    printf '\n'
    printf '# OPTIONAL - Static IP (leave blank for DHCP)\n'
    printf 'STATIC_IP=%s\n' "$STATIC_IP"
    printf 'STATIC_GATEWAY=%s\n' "$STATIC_GATEWAY"
    printf 'STATIC_PREFIX=%s\n' "$STATIC_PREFIX"
    printf 'STATIC_DNS=%s\n' "$STATIC_DNS"
} > "$out_file"
ok "station.conf written"

# ── Save defaults ─────────────────────────────────────────────────────────────

if command -v python3 &>/dev/null; then
    _D_WIFI_PW_ENC=$(encrypt_value "$WIFI_PASSWORD")
    [[ -z "$_D_WIFI_PW_ENC" ]] && _D_WIFI_PW_ENC="$_SAVED_WIFI_PW_ENC"
    _D_GITHUB_PAT_ENC=$(encrypt_value "$GITHUB_PAT")
    [[ -z "$_D_GITHUB_PAT_ENC" && -n "$GITHUB_PAT" ]] && warn "GitHub PAT encryption failed - credential will not be saved"
    _D_REG_SEC_ENC=$(encrypt_value "$REGISTRATION_SECRET")
    [[ -z "$_D_REG_SEC_ENC" && -n "$REGISTRATION_SECRET" ]] && warn "Registration secret encryption failed - credential will not be saved"
    export _D_HOSTNAME="$PI_HOSTNAME" _D_USERNAME="$PI_USERNAME" \
           _D_TIMEZONE="$TIMEZONE" _D_KEYBOARD="$KEYBOARD_LAYOUT" \
           _D_LOCALE="$LOCALE" _D_WIFI_SSID="$WIFI_SSID" \
           _D_WIFI_COUNTRY="$WIFI_COUNTRY" _D_WIFI_SECURITY="$WIFI_SECURITY" \
           _D_WIFI_HIDDEN="$WIFI_HIDDEN" \
           _D_ADMIN_SSH_KEY_PATH="$ADMIN_SSH_KEY_PATH" _D_STORE_NAME="$STORE_NAME" \
           _D_STORE_CITY="$STORE_CITY" _D_STORE_STATE="$STORE_STATE" \
           _D_STORE_SLUG="$STORE_SLUG" \
           _D_STATIC_IP="$STATIC_IP" _D_STATIC_GATEWAY="$STATIC_GATEWAY" \
           _D_STATIC_PREFIX="$STATIC_PREFIX" _D_STATIC_DNS="$STATIC_DNS" \
           _D_WIFI_PW_ENC="$_D_WIFI_PW_ENC" \
           _D_GITHUB_PAT_ENC="$_D_GITHUB_PAT_ENC" _D_REG_SEC_ENC="$_D_REG_SEC_ENC" \
           _D_FILE="$DEFAULTS_FILE"
    python3 - <<'PYEOF'
import json, os
mapping = {
    "Hostname":        "_D_HOSTNAME",
    "Username":        "_D_USERNAME",
    "Timezone":        "_D_TIMEZONE",
    "KeyboardLayout":  "_D_KEYBOARD",
    "Locale":          "_D_LOCALE",
    "WifiSsid":        "_D_WIFI_SSID",
    "WifiCountry":     "_D_WIFI_COUNTRY",
    "WifiSecurity":    "_D_WIFI_SECURITY",
    "WifiHidden":      "_D_WIFI_HIDDEN",
    "AdminSshKeyPath": "_D_ADMIN_SSH_KEY_PATH",
    "StoreName":       "_D_STORE_NAME",
    "StoreCity":       "_D_STORE_CITY",
    "StoreState":      "_D_STORE_STATE",
    "StoreSlug":       "_D_STORE_SLUG",
    "StaticIp":        "_D_STATIC_IP",
    "StaticGateway":   "_D_STATIC_GATEWAY",
    "StaticPrefix":    "_D_STATIC_PREFIX",
    "StaticDns":       "_D_STATIC_DNS",
    "WifiPasswordEnc":       "_D_WIFI_PW_ENC",
    "GithubPatEnc":          "_D_GITHUB_PAT_ENC",
    "RegistrationSecretEnc": "_D_REG_SEC_ENC",
}
dest = os.environ.get("_D_FILE", "")
try:
    # utf-8-sig: create-image.ps1 may have written this file with a BOM.
    with open(dest, encoding="utf-8-sig") as f:
        existing = json.load(f)
except Exception:
    existing = {}
for k, env_k in mapping.items():
    existing[k] = os.environ.get(env_k, "")
# ServerUrl was cached by earlier versions. Dropped so a --server-url override used for one
# test card can never linger and ship on the next real one.
for stale in ["SkipStoreCreate", "SkipTestPrint", "ServerUrl"]:
    existing.pop(stale, None)
with open(dest, "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
    ok "Defaults saved"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'
printf "${GREEN}================================================${NC}\n"
printf "${GREEN}  Done${NC}\n"
printf "${GREEN}================================================${NC}\n"
printf '\n'
if $FULL_MODE; then
    printf "${GRAY}  The SD card is ready. Safely eject it, then:${NC}\n"
    printf "${GRAY}  1. Insert into the Pi and power on${NC}\n"
    printf "${GRAY}  2. Boot 1: firstrun.sh runs, Pi reboots automatically (~1 min)${NC}\n"
    printf "${GRAY}  3. Boot 2: first_boot.sh runs - provisioning + registration (~5 min)${NC}\n"
    printf "${GRAY}  4. Accept the station at: %s/admin/clients${NC}\n" "$SERVER_URL"
    printf "${GRAY}  5. Monitor: ssh %s@<pi-ip>  then: tail -f ~/first-boot.log${NC}\n" "$PI_USERNAME"
else
    printf "${GRAY}  Safely eject the SD card, insert into the Pi, and power on.${NC}\n"
    printf "${GRAY}  first_boot.sh runs on the next boot (~5 min).${NC}\n"
    printf "${GRAY}  Accept the station at: %s/admin/clients${NC}\n" "$SERVER_URL"
fi
printf '\n'
