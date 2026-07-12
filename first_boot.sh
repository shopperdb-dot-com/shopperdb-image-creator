#!/usr/bin/env bash
# ---------------------------------------------------------------------
# first_boot.sh - First-Boot Setup for ShopperDB Stations
#
# Runs exactly once on a freshly flashed Pi via shopperdb-setup.service.
# Reads secrets from /boot/firmware/station.conf, configures GitHub
# credentials, clones the repo, runs full provisioning, and registers
# with the server. On success, zeroes sensitive fields and removes the
# first-boot flag so the service never runs again.
#
# Baked into the OS image at: /opt/shopperdb/first_boot.sh
# Managed by: shopperdb-setup.service (also baked into image)
# Flag file: /etc/shopperdb/first-boot-pending
#
# If any step fails, the flag file is left in place so the service
# retries on the next boot. Secrets are only zeroed on full success.
#
# This file is bundled with shopperdb-image-creator. A copy is also
# maintained in the private shopperdb repo.
# The image build process copies it to /opt/shopperdb/ on the Pi.
# ---------------------------------------------------------------------

set -uo pipefail

# =====================================================================
# CONSTANTS
# =====================================================================

FLAG_FILE="/etc/shopperdb/first-boot-pending"
STATION_CONF="/boot/firmware/station.conf"
# When run via `sudo bash`, $SUDO_USER is the invoking user (admin).
# When run by systemd with User=admin, $USER is admin. Fall back to admin.
# PI_USER is injected by shopperdb-setup.service via Environment=PI_USER=.
# The SUDO_USER fallback covers manual `sudo bash` invocations.
# $USER is intentionally NOT used as a fallback: when systemd runs this as
# root it sets USER=root, which would cause all paths to resolve under /root.
PI_USER="${PI_USER:-${SUDO_USER:-admin}}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
PI_HOME="${PI_HOME:-/home/${PI_USER}}"
# Export so child processes (provision.sh, register_client.sh) inherit the
# correct values rather than re-deriving from the root environment.
export PI_USER PI_HOME
# Redirect HOME so user-scoped tools (uv, pip) install under PI_HOME
# rather than /root when this script runs as root.
if [ "$(id -u)" = "0" ] && [ "$PI_USER" != "root" ]; then
    export HOME="$PI_HOME"
fi
LOG_FILE="${PI_HOME}/first-boot.log"
REPO_DIR="${PI_HOME}/shopperdb"
CLIENT_DIR="${REPO_DIR}/client"
GITHUB_REPO="https://github.com/shopperdb-dot-com/shopperdb.git"
SERVICE_NAME="shopperdb-setup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# =====================================================================
# LOGGING
# =====================================================================

log()  { echo "$@" | tee -a "$LOG_FILE"; }
ok()   { log -e "  ${GREEN}✓ $*${NC}"; }
warn() { log -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { log -e "  ${RED}✗ $*${NC}"; }
info() { log -e "  ${GRAY}→ $*${NC}"; }

abort() {
    fail "$1"
    log ""
    log -e "${RED}First-boot setup failed. Will retry on next boot.${NC}"
    log -e "${GRAY}Review: ${LOG_FILE}${NC}"
    exit 1
}

fix_owner() {
    [ "$(id -u)" = "0" ] && [ "$PI_USER" != "root" ] || return 0
    chown -R "${PI_USER}:${PI_USER}" "$@" 2>/dev/null || true
}

# Configure a 7-inch 1024x600 HDMI LCD, tailored to the detected board.
# Detection uses the same /proc/device-tree/model string reported to the
# server at registration (e.g. "Raspberry Pi 5 Model B Rev 1.0").
# Settings are written to the boot partition and take effect on next reboot.
configure_lcd_display() {
    local cmdline_file="/boot/firmware/cmdline.txt"
    local config_file="/boot/firmware/config.txt"
    # KMS video= line: force 1024x600 on the primary HDMI connector. HDMI-A-1
    # is the primary HDMI port on Pi 3/4/5 and Zero. The trailing D forces the
    # digital output on even when the panel provides no/garbage EDID (the KMS
    # equivalent of the legacy hdmi_force_hotplug/hdmi_cvt config.txt block,
    # which is ignored under the KMS driver used on Bookworm and Trixie).
    local video_arg="video=HDMI-A-1:1024x600M@60D"
    local model

    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")

    case "$model" in
        *"Raspberry Pi"*) ;;
        *)
            warn "LCD_DISPLAY set but hardware is not a Raspberry Pi (${model:-unknown}) - skipping LCD config"
            return 0
            ;;
    esac

    info "Detected board: ${model}"

    # HDMI mode: append the forced mode only if no video= entry exists yet.
    if [ -f "$cmdline_file" ]; then
        local cmdline
        cmdline=$(tr -d '\r\n' < "$cmdline_file")
        if printf '%s' "$cmdline" | grep -q "video=HDMI"; then
            info "cmdline.txt already has a video= entry - leaving HDMI mode unchanged"
        else
            printf '%s %s\n' "$cmdline" "$video_arg" | sudo tee "$cmdline_file" >/dev/null
            ok "HDMI mode set: ${video_arg}"
        fi
    else
        warn "cmdline.txt not found at ${cmdline_file} - cannot set HDMI mode"
    fi

    # USB power depends on the board's power delivery:
    #  - Pi 4/5: USB-C power negotiation; the legacy max_usb_current knob is
    #    ignored and the ports already supply enough for a bus-powered panel.
    #  - Pi 3/2/Zero: micro-USB; max_usb_current=1 raises the USB budget to
    #    1.2A (needs a 2.5A+ supply) so a bus-powered panel does not brown out.
    case "$model" in
        *"Raspberry Pi 5"*|*"Raspberry Pi 4"*)
            info "USB-C power board - max_usb_current not required"
            ;;
        *)
            if [ -f "$config_file" ]; then
                if grep -q "^max_usb_current=1" "$config_file"; then
                    info "config.txt already sets max_usb_current=1"
                else
                    printf '\n# 7-inch LCD: raise USB budget to 1.2A for a bus-powered panel\nmax_usb_current=1\n' \
                        | sudo tee -a "$config_file" >/dev/null
                    ok "max_usb_current=1 added to config.txt"
                fi
            else
                warn "config.txt not found at ${config_file} - cannot set USB power"
            fi
            ;;
    esac

    warn "LCD settings take effect on the next reboot"
}

# =====================================================================
# FLAG FILE CHECK - exit immediately if not a first boot
# =====================================================================

if [ ! -f "$FLAG_FILE" ]; then
    exit 0
fi

# =====================================================================
# BEGIN FIRST-BOOT SETUP
# =====================================================================

echo "=== First-boot setup: $(date -Iseconds) ===" > "$LOG_FILE"
fix_owner "$LOG_FILE"

log ""
log -e "${CYAN}==================================================${NC}"
log -e "${CYAN}  ShopperDB - First Boot Setup${NC}"
log -e "${CYAN}==================================================${NC}"

# Show hardware info
if [ -f /proc/device-tree/model ]; then
    pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
    log -e "  ${GRAY}Hardware: ${pi_model}${NC}"
fi
log -e "  ${GRAY}User: ${PI_USER} | Host: $(hostname)${NC}"
log -e "  ${GRAY}Log: ${LOG_FILE}${NC}"

# =====================================================================
# STEP 1: Read station.conf
# =====================================================================

log ""
log -e "${CYAN}[1/7] Reading station.conf${NC}"

if [ ! -f "$STATION_CONF" ]; then
    abort "station.conf not found at ${STATION_CONF}. Place station.conf on the boot partition before first boot."
fi

# Source the config (simple KEY=VALUE format)
set -a
# shellcheck source=/dev/null
source "$STATION_CONF"
set +a

REGISTRATION_SECRET="${REGISTRATION_SECRET:-}"
SERVER_URL="${SERVER_URL:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
LCD_DISPLAY="${LCD_DISPLAY:-false}"

missing=()
[ -z "$REGISTRATION_SECRET" ] && missing+=("REGISTRATION_SECRET")
[ -z "$SERVER_URL" ]          && missing+=("SERVER_URL")
[ -z "$GITHUB_PAT" ]          && missing+=("GITHUB_PAT")

if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing required fields in station.conf:"
    for field in "${missing[@]}"; do
        fail "  ${field}"
    done
    abort "Fill in all required fields and reboot."
fi

ok "Required fields present: REGISTRATION_SECRET, SERVER_URL, GITHUB_PAT"
info "Server: ${SERVER_URL}"
if [ -n "$ADMIN_SSH_KEY" ]; then
    info "Admin SSH key provided - will configure authorized_keys"
else
    warn "No ADMIN_SSH_KEY in station.conf - password auth will remain active"
fi

# Optional: configure a 7-inch HDMI LCD, tailored to the detected board.
if [ "$LCD_DISPLAY" = "true" ]; then
    log ""
    log -e "${CYAN}Configuring 7-inch LCD display${NC}"
    configure_lcd_display
fi

# =====================================================================
# STEP 2: WiFi setup (optional - only if WIFI_SSID is provided)
# =====================================================================

log ""
log -e "${CYAN}[2/7] Network connectivity${NC}"

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
STATIC_IP="${STATIC_IP:-}"
STATIC_GATEWAY="${STATIC_GATEWAY:-}"
STATIC_PREFIX="${STATIC_PREFIX:-24}"
STATIC_DNS="${STATIC_DNS:-8.8.8.8,1.1.1.1}"

# Helper: apply static IP to a NetworkManager connection
apply_static_ip() {
    local conn_name="$1"
    if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
        info "Applying static IP: ${STATIC_IP}/${STATIC_PREFIX} via ${STATIC_GATEWAY}"
        sudo nmcli connection modify "$conn_name" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}" \
            ipv4.gateway "$STATIC_GATEWAY" \
            ipv4.dns "$STATIC_DNS" 2>/dev/null
        ok "Static IP configured on ${conn_name}"
        return 0
    fi
    return 1
}

if [ -n "$WIFI_SSID" ]; then
    info "WiFi SSID provided: ${WIFI_SSID}"

    # Set regulatory country - raspi-config writes it persistently so the
    # radio becomes available after unblock. iw reg set alone is session-only
    # and does not unblock an adapter that is in the "unavailable" NM state.
    if [ -n "$WIFI_COUNTRY" ]; then
        sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2>/dev/null || true
        sudo iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
        ok "WiFi country set to ${WIFI_COUNTRY}"
    fi

    # Unblock WiFi radio
    sudo rfkill unblock wifi 2>/dev/null || true
    sudo rfkill unblock all 2>/dev/null || true

    # Bring the interface up so NM transitions it out of "unavailable"
    sudo ip link set wlan0 up 2>/dev/null || true

    # Wait up to 20 seconds for wlan0 to leave the "unavailable" state
    info "Waiting for wlan0 to become available..."
    wlan_ready=false
    for _i in $(seq 1 20); do
        nm_state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: '/^wlan0:/ {print $2}')
        if [ "$nm_state" != "unavailable" ] && [ -n "$nm_state" ]; then
            wlan_ready=true
            ok "wlan0 is ${nm_state}"
            break
        fi
        sleep 1
    done

    if [ "$wlan_ready" = false ]; then
        warn "wlan0 still unavailable after 20s - WiFi connection will likely fail"
    fi

    # Check if already connected via WiFi
    if nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q "wifi:connected"; then
        ok "WiFi already connected"
    else
        info "Connecting to WiFi..."
        wifi_conn_name="shopperdb-wifi"

        # Remove any stale connection with this name
        sudo nmcli connection delete "$wifi_conn_name" 2>/dev/null || true

        # Write the connection profile directly so the PSK is stored in the
        # config file (psk-flags=0, system-owned). nmcli connection add stores
        # secrets via the agent which doesn't exist in a systemd service context,
        # causing "Secrets were required but not provided" on connection up.
        nm_conn_dir="/etc/NetworkManager/system-connections"
        nm_conn_file="${nm_conn_dir}/${wifi_conn_name}.nmconnection"
        sudo mkdir -p "$nm_conn_dir"

        if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
            printf '[connection]\nid=%s\ntype=wifi\nautoconnect=true\n\n[wifi]\nssid=%s\nmode=infrastructure\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=manual\naddresses=%s/%s\ngateway=%s\ndns=%s\n' \
                "$wifi_conn_name" "$WIFI_SSID" "$WIFI_PASSWORD" \
                "$STATIC_IP" "$STATIC_PREFIX" "$STATIC_GATEWAY" "$STATIC_DNS" \
                | sudo tee "$nm_conn_file" > /dev/null
            ok "WiFi connection profile written with static IP"
        else
            printf '[connection]\nid=%s\ntype=wifi\nautoconnect=true\n\n[wifi]\nssid=%s\nmode=infrastructure\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n' \
                "$wifi_conn_name" "$WIFI_SSID" "$WIFI_PASSWORD" \
                | sudo tee "$nm_conn_file" > /dev/null
            ok "WiFi connection profile written (DHCP)"
        fi

        sudo chmod 600 "$nm_conn_file"
        sudo nmcli connection reload 2>&1 | tee -a "$LOG_FILE" || true
        sudo nmcli connection up "$wifi_conn_name" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    # Wait for network connectivity (up to 60 seconds)
    info "Waiting for network connectivity..."
    net_ok=false
    for _i in $(seq 1 30); do
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            net_ok=true
            break
        fi
        sleep 2
    done

    if [ "$net_ok" = true ]; then
        ok "Network connectivity confirmed"
    else
        warn "No connectivity after 60s - continuing anyway"
    fi
else
    info "No WIFI_SSID in station.conf - assuming Ethernet"

    # Apply static IP to Ethernet if requested
    if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
        # Find the active Ethernet connection name
        eth_conn=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null \
            | grep "ethernet" | head -1 | cut -d: -f1)
        if [ -n "$eth_conn" ]; then
            apply_static_ip "$eth_conn"
            sudo nmcli connection up "$eth_conn" 2>/dev/null || true
        else
            warn "No active Ethernet connection found for static IP"
        fi
    fi

    # Verify connectivity
    if ping -c1 -W5 8.8.8.8 &>/dev/null; then
        ok "Network connectivity confirmed"
    else
        warn "No network connectivity detected - will retry operations anyway"
    fi
fi

# =====================================================================
# STEP 3: Configure GitHub credentials
# =====================================================================

log ""
log -e "${CYAN}[3/7] Configuring GitHub credentials${NC}"

mkdir -p "${PI_HOME}/.ssh"
chmod 700 "${PI_HOME}/.ssh"

# Write ~/.git-credentials so git HTTPS auth works without prompting.
# Format must be https://username:password@host - GitHub accepts any username
# and uses the PAT as the password. Writing just https://TOKEN@github.com puts
# the token in the username field (no password), causing git to fall back to
# interactive prompting, which fails with no TTY in a systemd service.
CRED_FILE="${PI_HOME}/.git-credentials"
printf 'https://x-access-token:%s@github.com\n' "$GITHUB_PAT" > "$CRED_FILE"
chmod 600 "$CRED_FILE"
# fix_owner handles root->PI_USER chown; explicit fallback ensures ownership
# is correct even if fix_owner silently fails (e.g. on filesystem edge cases).
fix_owner "$CRED_FILE"
if [ "$(id -u)" = "0" ] && [ -n "$PI_USER" ] && [ "$PI_USER" != "root" ]; then
    chown "${PI_USER}:${PI_USER}" "$CRED_FILE" 2>/dev/null || true
fi

# Prevent git from ever attempting interactive credential prompts.
# Without this, a credential lookup failure hangs or errors with
# "no such device or address" because there is no TTY.
export GIT_TERMINAL_PROMPT=0

# git is not installed by default on Pi OS Lite - install it now so
# git config and the clone in Step 4 both have it available.
if ! command -v git &>/dev/null; then
    info "git not found - installing via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq git >/dev/null 2>&1
    if command -v git &>/dev/null; then
        ok "git installed"
    else
        abort "git installation failed. Check network connectivity."
    fi
else
    ok "git available"
fi

git config --global credential.helper store
ok "GitHub credentials configured"

# Install admin SSH key for passwordless login
if [ -n "$ADMIN_SSH_KEY" ]; then
    touch "${PI_HOME}/.ssh/authorized_keys"
    chmod 600 "${PI_HOME}/.ssh/authorized_keys"
    if ! grep -qF "$ADMIN_SSH_KEY" "${PI_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        echo "$ADMIN_SSH_KEY" >> "${PI_HOME}/.ssh/authorized_keys"
        ok "Admin SSH key added to authorized_keys"
    else
        ok "Admin SSH key already in authorized_keys"
    fi
fi

fix_owner "${PI_HOME}/.ssh"

# =====================================================================
# STEP 4: Clone the repo
# =====================================================================

log ""
log -e "${CYAN}[4/7] Repository setup${NC}"

# git 2.35.2+ refuses to operate on repos owned by a different user.
# Running as root on a PI_USER-owned repo triggers this on retry runs
# (fix_owner ran on the previous attempt and changed ownership to PI_USER).
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

if [ -d "${REPO_DIR}/.git" ]; then
    ok "Repo already cloned at ${REPO_DIR}"
    fix_owner "$REPO_DIR"
    cd "$REPO_DIR" || exit 1
    git pull --ff-only 2>&1 | tail -3 | tee -a "$LOG_FILE" || true
    cd "$PI_HOME" || exit 1
else
    info "Cloning repository..."
    if git clone "$GITHUB_REPO" "$REPO_DIR" 2>&1 | tail -5 | tee -a "$LOG_FILE"; then
        ok "Repository cloned"
    else
        abort "Repository clone failed. Is the GitHub PAT valid and does it have Contents read access?"
    fi

    # Set up sparse checkout (client-only files)
    cd "$REPO_DIR" || exit 1
    git sparse-checkout init 2>/dev/null
    git sparse-checkout set --skip-checks client README.md .gitignore 2>/dev/null
    ok "Sparse checkout configured (client/, README.md, .gitignore)"
    cd "$PI_HOME" || exit 1
fi

fix_owner "$REPO_DIR"

# Validate the client directory exists
if [ ! -d "$CLIENT_DIR/scripts" ]; then
    abort "Client scripts directory not found at ${CLIENT_DIR}/scripts"
fi

# =====================================================================
# STEP 5: Run provision.sh (full provisioning)
# =====================================================================

log ""
log -e "${CYAN}[5/7] Running provisioner${NC}"
info "This may take several minutes on first run..."

PROVISION_SCRIPT="${CLIENT_DIR}/scripts/provision.sh"

if [ ! -f "$PROVISION_SCRIPT" ]; then
    abort "provision.sh not found at ${PROVISION_SCRIPT}"
fi

chmod +x "$PROVISION_SCRIPT"

# Run provision.sh directly (no pipe) so its stdout is never block-buffered.
# Piping through tee delays all output until the process exits, which pushes
# time-sensitive actions (test label print, buzzer) to the very end.
# provision.sh already writes its own ~/provision.log; append that afterward.
provision_exit=0
bash "$PROVISION_SCRIPT" || provision_exit=$?
cat "${PI_HOME}/provision.log" >> "$LOG_FILE" 2>/dev/null || true

if [ "$provision_exit" -ne 0 ]; then
    abort "provision.sh exited with code ${provision_exit}. Review ${PI_HOME}/provision.log for details."
fi

ok "Provisioning complete"
fix_owner "${PI_HOME}/.local" "${PI_HOME}/.cache" "${PI_HOME}/.cargo" "$REPO_DIR"

# =====================================================================
# STEP 6: Register with the server
# =====================================================================

log ""
log -e "${CYAN}[6/7] Registering with server${NC}"
info "Server: ${SERVER_URL}"

REGISTER_SCRIPT="${CLIENT_DIR}/scripts/register_client.sh"

if [ ! -f "$REGISTER_SCRIPT" ]; then
    abort "register_client.sh not found at ${REGISTER_SCRIPT}"
fi

chmod +x "$REGISTER_SCRIPT"

register_exit=0
bash "$REGISTER_SCRIPT" \
    --secret "$REGISTRATION_SECRET" \
    --server "$SERVER_URL" \
    --env-file "${CLIENT_DIR}/.env" \
    --service "shopperdb-client" \
    2>&1 | tee -a "$LOG_FILE" || register_exit=$?

if [ "$register_exit" -ne 0 ]; then
    abort "register_client.sh exited with code ${register_exit}. Registration will retry on next boot."
fi

ok "Registration complete"
fix_owner "${CLIENT_DIR}/.env" "${PI_HOME}/.ssh"

# =====================================================================
# STEP 7: Clean up - zero secrets, remove flag, disable service
# =====================================================================

log ""
log -e "${CYAN}[7/7] Cleanup${NC}"

# Zero sensitive fields in station.conf (leave SERVER_URL as a record)
info "Zeroing sensitive fields in station.conf..."
sudo sed -i 's/^REGISTRATION_SECRET=.*/REGISTRATION_SECRET=/' "$STATION_CONF"
sudo sed -i 's/^GITHUB_PAT=.*/GITHUB_PAT=/' "$STATION_CONF"
sudo sed -i 's/^WIFI_PASSWORD=.*/WIFI_PASSWORD=/' "$STATION_CONF"
sudo sed -i 's/^STATIC_DNS=.*/STATIC_DNS=/' "$STATION_CONF"
ok "Sensitive fields zeroed in station.conf"

# Remove the first-boot flag file
sudo rm -f "$FLAG_FILE"
ok "Flag file removed: ${FLAG_FILE}"

# Disable and remove the setup service (its job is done).
# Do NOT call systemctl daemon-reload here: this script runs as the service's
# own ExecStart process, so daemon-reload while still running causes systemd
# to mark the unit failed mid-execution. systemd's normal boot-time reload on
# the next boot will see the file is gone and stop tracking the unit cleanly.
info "Removing shopperdb-setup service..."
sudo systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
ok "shopperdb-setup.service removed"

# =====================================================================
# DONE
# =====================================================================

log ""
log -e "${GREEN}==================================================${NC}"
log -e "${GREEN}  First-boot setup complete${NC}"
log -e "${GREEN}==================================================${NC}"
log ""
log -e "${GRAY}The Pi is now registered and pending admin approval.${NC}"
log -e "${GRAY}Accept the station in the server admin UI, then the${NC}"
log -e "${GRAY}VPN tunnel will activate and scanning can begin.${NC}"
log ""
log -e "${GRAY}On all future boots, shopperdb-provision.service${NC}"
log -e "${GRAY}will maintain the configuration automatically.${NC}"
log ""
log -e "${GRAY}Log: ${LOG_FILE}${NC}"

exit 0
