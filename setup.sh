#!/usr/bin/env bash
# setup.sh - One-time setup for shopperdb-image-creator (Mac/Linux)
#
# Installs Raspberry Pi Imager and downloads the admin SSH key needed to create
# station images. Run this once before using create-image.sh.
#
# Re-run with --refresh at any time to pick up rotated keys.
#
# Usage: ./setup.sh [--refresh]

set -euo pipefail

# ── Key distribution ──────────────────────────────────────────────────────────
# GitHub username and secret gist ID containing the admin SSH key.
# The gist must have one file:
#   id_ed25519.pub      - admin SSH public key
GIST_USER="shopperdb-admin"
GIST_ID="f6fa932f1796ef90e65540c5702fcc16"

# ── Helpers ───────────────────────────────────────────────────────────────────

YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

step() { printf "  ${CYAN}-> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}OK %s${NC}\n" "$*"; }
warn() { printf "  ${YELLOW}** %s${NC}\n" "$*"; }

REFRESH=false
[[ "${1:-}" == "--refresh" ]] && REFRESH=true

OS_TYPE="$(uname -s)"
ALL_OK=true
FETCH_ENABLED=false
[[ -n "$GIST_ID" ]] && FETCH_ENABLED=true

get_gist_file() {
    local filename="$1"
    local url="https://gist.githubusercontent.com/$GIST_USER/$GIST_ID/raw/$filename"
    curl -fsSL --max-time 15 "$url" 2>/dev/null || true
}

find_rpi_imager() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for p in \
            "/Applications/Imager.app/Contents/MacOS/rpi-imager" \
            "/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"; do
            [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
        done
    else
        for p in "/usr/bin/rpi-imager" "/usr/local/bin/rpi-imager"; do
            [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
        done
    fi
    command -v rpi-imager 2>/dev/null || return 1
}

# ── Header ────────────────────────────────────────────────────────────────────

printf '\n'
printf "${CYAN}================================================${NC}\n"
printf "${CYAN}  ShopperDB Image Creator - Setup${NC}\n"
printf "${CYAN}================================================${NC}\n"
printf '\n'

# ── Step 1: Raspberry Pi Imager ───────────────────────────────────────────────

step "Checking for Raspberry Pi Imager..."

imager=$(find_rpi_imager 2>/dev/null || true)
if [[ -n "$imager" ]]; then
    ok "Raspberry Pi Imager found"
else
    warn "Raspberry Pi Imager not found."
    ALL_OK=false

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            printf "  Install via Homebrew? [y/N] "
            read -r answer </dev/tty
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                step "Running: brew install --cask raspberry-pi-imager"
                brew install --cask raspberry-pi-imager
                imager=$(find_rpi_imager 2>/dev/null || true)
                [[ -n "$imager" ]] && ok "Raspberry Pi Imager installed" && ALL_OK=true || \
                    warn "Install finished but imager not found at expected path."
            else
                printf "  ${GRAY}Download from: https://www.raspberrypi.com/software/${NC}\n"
            fi
        else
            printf "  ${GRAY}Install Homebrew first, then run: brew install --cask raspberry-pi-imager${NC}\n"
        fi
    else
        if command -v apt-get &>/dev/null; then
            printf "  Install via apt? [y/N] "
            read -r answer </dev/tty
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                step "Running: sudo apt-get install rpi-imager"
                sudo apt-get update -qq && sudo apt-get install -y rpi-imager
                imager=$(find_rpi_imager 2>/dev/null || true)
                [[ -n "$imager" ]] && ok "Raspberry Pi Imager installed" && ALL_OK=true || \
                    warn "Install finished but rpi-imager not found on PATH."
            else
                printf "  ${GRAY}Run: sudo apt-get install rpi-imager${NC}\n"
            fi
        else
            printf "  ${GRAY}Download from: https://www.raspberrypi.com/software/${NC}\n"
        fi
    fi
fi

# ── Step 2: Admin SSH key ─────────────────────────────────────────────────────

printf '\n'
SSH_DIR="$HOME/.ssh"
ADMIN_KEY="$SSH_DIR/id_ed25519.pub"

step "Checking for admin SSH key..."

if [[ -f "$ADMIN_KEY" ]] && ! $REFRESH; then
    ok "Admin SSH key present"
elif $FETCH_ENABLED; then
    step "Fetching admin SSH key..."
    content=$(get_gist_file "id_ed25519.pub")
    if [[ -n "$content" && "$content" == ssh-* ]]; then
        mkdir -p "$SSH_DIR"
        printf '%s\n' "${content%$'\n'}" > "$ADMIN_KEY"
        ok "Admin SSH key saved to $ADMIN_KEY"
    else
        warn "Could not fetch admin SSH key. Contact your system administrator."
        ALL_OK=false
    fi
else
    warn "Admin SSH key not found at $ADMIN_KEY"
    [[ -z "$GIST_ID" ]] && printf "  ${GRAY}Contact your system administrator for setup assistance.${NC}\n"
    ALL_OK=false
fi

# ── Step 3: Python / uv / pre-commit ─────────────────────────────────────────

printf '\n'
step "Checking for uv..."

if ! command -v uv &>/dev/null; then
    step "Installing uv..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

if command -v uv &>/dev/null; then
    ok "uv available"

    step "Syncing dev dependencies..."
    if uv sync --group dev >/dev/null 2>&1; then
        ok "Dev dependencies ready"

        step "Installing pre-commit hooks..."
        if uv run --group dev pre-commit install >/dev/null 2>&1; then
            ok "Pre-commit hooks installed"
        else
            warn "Pre-commit install failed (run manually: uv run --group dev pre-commit install)"
            ALL_OK=false
        fi
    else
        warn "uv sync failed - pre-commit hooks not installed"
        ALL_OK=false
    fi
else
    warn "uv not found and install failed. Install manually: https://docs.astral.sh/uv/getting-started/installation/"
    warn "Then run: uv sync --group dev && uv run --group dev pre-commit install"
    ALL_OK=false
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'
if $ALL_OK; then
    printf "${GREEN}================================================${NC}\n"
    printf "${GREEN}  Ready. Run ./create-image.sh to create an SD card image.${NC}\n"
    printf "${GREEN}================================================${NC}\n"
else
    printf "${YELLOW}================================================${NC}\n"
    printf "${YELLOW}  Setup incomplete. See warnings above.${NC}\n"
    printf "${GRAY}  You can still run create-image.sh and supply keys manually when prompted.${NC}\n"
    printf "${YELLOW}================================================${NC}\n"
fi
printf '\n'
