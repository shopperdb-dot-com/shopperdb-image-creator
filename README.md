# shopperdb-image-creator

SD card preparation tool for deploying shopperdb stations on Raspberry Pi.

Handles the full workflow - flash a base OS image, customise it, and write `station.conf` to the boot partition - without opening Raspberry Pi Imager manually. Works with the private `shopperdb` repository.

## Boot sequence

| Boot | What happens | Duration |
|------|-------------|----------|
| Boot 1 | `firstrun.sh` sets hostname, admin account, SSH, WiFi; Pi reboots | ~1 min |
| Boot 2 | `first_boot.sh` installs software, registers with server, starts VPN | ~5-10 min |

After Boot 2, accept the station at `<SERVER_URL>/admin/clients`. See `client/docs/README.md` in the shopperdb repo for full details on what happens during each boot.

## Prerequisites

Run `setup.ps1` (Windows) or `setup.sh` (Mac/Linux) once to check and install prerequisites:

**Windows:**
```powershell
.\setup.ps1
```

**Mac/Linux:**
```bash
chmod +x setup.sh
./setup.sh
```

What gets checked:
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) - required for full mode (flash + customise); setup scripts can install it automatically via winget or Homebrew
- Admin SSH public key at `~/.ssh/id_ed25519.pub` (optional - enables passwordless SSH on the Pi)

Use **Raspberry Pi OS Lite (64-bit), Trixie/Debian 13** as the base image, available from [raspberrypi.com/software/operating-systems](https://www.raspberrypi.com/software/operating-systems/).

## What you'll need

Gather these before running the script. The script prompts for any value not passed as a parameter and saves encrypted copies locally for reuse on subsequent runs.

| Value | Where to get it |
|-------|----------------|
| **Registration secret** | From the server administrator - set in `server/.env` as `REGISTRATION_SECRET` |
| **GitHub PAT** | Create at GitHub > Settings > Developer Settings > Personal Access Tokens > Fine-grained tokens. Scope to `shopperdb`, Contents: Read-only |
| **Server URL** | Base URL of the inventory server, e.g. `http://192.168.2.100:8000` |
| **WiFi password** | Your network's password (omit for Ethernet-only deployments) |

## Usage

### Windows - create-image.ps1

Must be run as Administrator (rpi-imager requires elevation to write to a disk).

**Full mode** - flash, customise, and write station.conf:
```powershell
.\create-image.ps1 -ImagePath "C:\images\raspios-trixie-arm64-lite.img.xz" -WifiSsid "WiFiSSID"
```

Pass a directory to `-ImagePath` and the script will find the `.img.xz` inside it automatically. If more than one is found, it prompts you to choose (newest first).

**Skip-flash** - write firstrun.sh and station.conf to an already-flashed card (skips rpi-imager, starts at credential collection):
```powershell
.\create-image.ps1 -SkipFlash -WifiSsid "WiFiSSID"
```

**Provision-only** - write station.conf only to an already-flashed card:
```powershell
.\create-image.ps1 -WifiSsid "WiFiSSID"
```

Run `Get-Help .\create-image.ps1 -Full` for all parameters.

**Saved defaults:** After each successful run the script saves all settings to `.create-image.defaults.json` (gitignored). On the next run, non-sensitive values are restored automatically; the WiFi password, GitHub PAT, and registration secret are stored DPAPI-encrypted and reused silently. Pass any parameter explicitly to override and update the saved value.

**Key parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ImagePath` | *(omit for provision-only)* | `.img`/`.img.xz` file **or directory** containing one |
| `-SkipFlash` | *(off)* | Skip flashing; write firstrun.sh + station.conf to an already-flashed card |
| `-Hostname` | `sbc-shopperdb` | Pi hostname |
| `-Username` | `admin` | Admin OS user account to create on the Pi |
| `-WifiSsid` | *(blank = Ethernet-only)* | WiFi network name |
| `-ServerUrl` | *(saved or prompt)* | Server base URL, e.g. `http://192.168.2.100:8000` |
| `-GithubPat` | *(prompted)* | GitHub PAT with read-only Contents access to shopperdb |
| `-AdminSshKeyPath` | `~\.ssh\id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `-StoreName` | *(saved or blank = none)* | Store display name, e.g. `"Steve's Wheels and Deals"` - creates a public store page when the admin accepts the station. Saved between runs; pass `""` to clear. |
| `-SkipStoreCreate` | `$false` | Suppress public store page creation (for internal/test deployments) |
| `-SkipTestPrint` | `$false` | Skip printer test label on first provisioning run (useful before the printer is connected) |
| `-StaticIp` | *(blank = DHCP)* | Optional static IP for the Pi |
| `-DiskNumber` | *(auto-detected)* | Override SD card disk number from `Get-Disk` |

---

### Mac/Linux - create-image.sh

**Full mode:**
```bash
./create-image.sh --image-path ~/Downloads/raspios-trixie-arm64-lite.img.xz --wifi-ssid "WiFiSSID"
```

The script auto-detects the SD card from removable block devices and asks for confirmation before erasing. After flashing it ejects and prompts you to re-insert.

**Skip-flash** - write firstrun.sh and station.conf to an already-flashed card:
```bash
./create-image.sh --skip-flash --wifi-ssid "WiFiSSID"
```

**Provision-only:**
```bash
./create-image.sh --wifi-ssid "WiFiSSID"
```

The boot partition is auto-detected by looking for a FAT volume containing `cmdline.txt`. Pass `--boot-mount PATH` to override.

Run `./create-image.sh --help` for the full option list.

**Saved defaults:** After each successful run the script saves all settings to `.create-image.defaults.json` (gitignored, shared with `create-image.ps1`). On the next run, non-sensitive values are restored automatically; the WiFi password, GitHub PAT, and registration secret are stored AES-256 encrypted (key derived from the machine UUID and local username) and reused silently. Saved credentials from a different machine cannot be decrypted — you will be warned and prompted to re-enter. Pass any option explicitly to override and update the saved value.

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--image-path PATH` | *(omit for provision-only)* | `.img` or `.img.xz` file to flash |
| `--skip-flash` | *(off)* | Skip flashing; write firstrun.sh + station.conf to an already-flashed card |
| `--disk DEVICE` | *(auto-detected)* | SD card device, e.g. `/dev/disk4` or `/dev/sdb` |
| `--boot-mount PATH` | *(auto-detected)* | Boot partition mount point |
| `--hostname NAME` | `sbc-shopperdb` | Pi hostname |
| `--username NAME` | `admin` | Admin OS user account to create on the Pi |
| `--wifi-ssid SSID` | *(blank = Ethernet-only)* | WiFi network name |
| `--server-url URL` | *(prompted)* | Server base URL |
| `--github-pat TOKEN` | *(prompted)* | GitHub PAT with read-only Contents access to shopperdb |
| `--admin-ssh-key PATH` | `~/.ssh/id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `--store-name NAME` | *(saved or blank = none)* | Store display name - creates a public store page when the admin accepts the station. Saved between runs. |
| `--skip-store-create` | *(off)* | Suppress public store page creation |
| `--skip-test-print` | *(off)* | Skip printer test label on first provisioning run |
| `--static-ip IP` | *(blank = DHCP)* | Optional static IP for the Pi |

---

## station.conf

Written to the SD card's `bootfs` partition by both scripts. See `station.conf.example` for the full template.

**Required fields:**
```ini
REGISTRATION_SECRET=<provided by the server administrator>
SERVER_URL=http://192.168.2.100:8000
GITHUB_PAT=<fine-grained PAT with read-only Contents access to shopperdb>
```

`REGISTRATION_SECRET` is set by the server administrator in the server's environment and must be entered securely when creating an image. The scripts prompt for it and save an encrypted copy locally so subsequent runs can reuse it without re-entering.

The `GITHUB_PAT` is a GitHub fine-grained token scoped to `shopperdb` with Contents: Read-only. It is prompted securely during image creation. See the shopperdb server README for token creation and rotation instructions.

**Optional fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `ADMIN_SSH_KEY` | *(blank)* | Full contents of an SSH public key. Added to `authorized_keys` for the admin account; disables password-based SSH if set. |
| `STORE_NAME` | *(blank)* | Display name for this station's public inventory page (e.g. `"Steve's Wheels and Deals"`). Use double quotes if the name contains spaces or an apostrophe. A store page is auto-created when the admin accepts the station. Leave blank to skip. |
| `SKIP_STORE_CREATE` | `false` | Set to `true` to suppress public store page creation entirely. |
| `SKIP_TEST_PRINT` | `false` | Set to `true` to skip the printer test label during first provisioning. Useful if the label printer is not yet connected, or to verify the rest of setup before printing. Can also be set in `client/.env` for subsequent re-provision runs. |
| `WIFI_SSID` / `WIFI_PASSWORD` | *(blank)* | WiFi credentials. Leave blank for Ethernet-only deployments. |
| `STATIC_IP` / `STATIC_GATEWAY` | *(blank)* | Static IP. Leave blank to use DHCP. |

## Testing

Tests run on Linux or macOS. They are skipped automatically on Windows.

```bash
# Install uv if not already: https://astral.sh/uv
uv run --group test pytest
uv run --group test pytest -v
```

## Files

| File | Purpose |
|------|---------|
| `create-image.ps1` | Windows: flash SD card and write station.conf |
| `create-image.sh` | Mac/Linux: flash SD card and write station.conf |
| `first_boot.sh` | First-boot script written to the boot partition during image prep |
| `station.conf.example` | Template for the boot-partition config file |
| `setup.ps1` | Windows: check and install prerequisites |
| `setup.sh` | Mac/Linux: check and install prerequisites |
