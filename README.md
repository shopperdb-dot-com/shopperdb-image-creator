# shopperdb-image-creator

[![CI](https://github.com/shopperdb-dot-com/shopperdb-image-creator/actions/workflows/ci.yml/badge.svg)](https://github.com/shopperdb-dot-com/shopperdb-image-creator/actions/workflows/ci.yml)

SD card preparation tool for deploying shopperdb stations on Raspberry Pi.

Handles the full workflow - flash a base OS image, customise it, and write `station.conf` to the boot partition - without opening Raspberry Pi Imager manually. Works with the private `shopperdb` repository.

## Boot sequence

| Boot | What happens | Duration |
|------|-------------|----------|
| Boot 1 | `firstrun.sh` sets hostname, admin account, SSH, WiFi; Pi reboots | ~1 min |
| Boot 2 | `first_boot.sh` installs software, registers with server, starts VPN | ~5-10 min |

After Boot 2, a ShopperDB administrator accepts the station and its store page goes live. See `client/docs/README.md` in the shopperdb repo for full details on what happens during each boot.

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

Gather these before running the script. The script prompts for any value not passed as a parameter and saves encrypted copies locally, so you only enter each one once.

| Value | Where to get it |
|-------|----------------|
| **Registration secret** | Supplied by ShopperDB |
| **GitHub access token** | Supplied by ShopperDB. Paste the token you were given - you do not create one yourself |
| **WiFi password** | Your network's password (omit for Ethernet-only deployments) |

Both credentials come from ShopperDB as part of onboarding. Keep them somewhere safe: they are entered once per computer, then stored encrypted and reused automatically. If a token stops working, ask ShopperDB for a replacement rather than issuing your own - a self-issued token will not have the right access.

You do **not** need to supply a server URL. Stations register with `https://shopperdb.com` by default.

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
| `-ServerUrl` | `https://shopperdb.com` | Override only to point a test card at a dev server. Never remembered between runs |
| `-GithubPat` | *(prompted)* | GitHub access token supplied by ShopperDB |
| `-AdminSshKeyPath` | `~\.ssh\id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `-StoreName` | *(saved or blank = none)* | Store display name, e.g. `"Steve's Wheels and Deals"` - creates a public store page when the admin accepts the station. Saved between runs; pass `""` to clear. |
| `-StoreCity` | *(saved or blank)* | Store city - part of the store's web address. Validated against the US place list and corrected to its canonical spelling. |
| `-StoreState` | *(saved or blank)* | Store state, 2 letters - part of the store's web address. |
| `-StoreSlug` | *(confirmed once, then saved)* | The store's web address label. Pass to set it outright and skip the confirmation prompt. Max 63 characters. |
| `-ReconfirmAddress` | *(off)* | Ask about the store web address again even when the saved one still applies. |
| `-PrintSlug` | *(off)* | Print the proposed store address and exit, without touching a card. |
| `-CheckPlace` | *(off)* | Print the canonical spelling of `-StoreCity`/`-StoreState` and exit. Fails if the pair is not a known US place. |
| `-SkipStoreCreate` | `$false` | Suppress public store page creation (for internal/test deployments). Skips the address prompts. |
| `-SkipTestPrint` | `$false` | Skip printer test label on first provisioning run (useful before the printer is connected) |
| `-LcdDisplay` | `$false` | Configure a 7-inch 1024x600 HDMI LCD. The Pi detects its own model on first boot and applies the matching HDMI/USB settings. Use only for units with the LCD attached, not TV/headless. |
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

**Saved defaults:** After each successful run the script saves all settings to `.create-image.defaults.json` (gitignored, shared with `create-image.ps1`). On the next run, non-sensitive values are restored automatically; the WiFi password, GitHub PAT, and registration secret are stored AES-256 encrypted (key derived from the machine UUID and local username) and reused silently. Saved credentials from a different machine cannot be decrypted - you will be warned and prompted to re-enter. Pass any option explicitly to override and update the saved value.

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
| `--server-url URL` | `https://shopperdb.com` | Override only to point a test card at a dev server. Never remembered between runs |
| `--github-pat TOKEN` | *(prompted)* | GitHub access token supplied by ShopperDB |
| `--admin-ssh-key PATH` | `~/.ssh/id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `--store-name NAME` | *(saved or blank = none)* | Store display name - creates a public store page when the admin accepts the station. Saved between runs. |
| `--store-city CITY` | *(saved or blank)* | Store city - part of the store's web address. Validated against the US place list |
| `--store-state ST` | *(saved or blank)* | Store state, 2 letters - part of the store's web address |
| `--store-slug SLUG` | *(confirmed once, then saved)* | The store's web address label; skips the confirmation prompt. Max 63 characters |
| `--reconfirm-address` | *(off)* | Ask about the store web address again even when the saved one still applies |
| `--print-slug` | *(off)* | Print the proposed store address and exit |
| `--check-place` | *(off)* | Print the canonical spelling of `--store-city`/`--store-state` and exit |
| `--skip-store-create` | *(off)* | Suppress public store page creation. Skips the address prompts |
| `--skip-test-print` | *(off)* | Skip printer test label on first provisioning run |
| `--lcd-display` | *(off)* | Configure a 7-inch 1024x600 HDMI LCD. The Pi detects its own model on first boot and applies the matching HDMI/USB settings. Use only for units with the LCD attached, not TV/headless. |
| `--static-ip IP` | *(blank = DHCP)* | Optional static IP for the Pi |

---

## station.conf

Written to the SD card's `bootfs` partition by both scripts. See `station.conf.example` for the full template.

**Required fields:**
```ini
REGISTRATION_SECRET=<supplied by ShopperDB>
SERVER_URL=https://shopperdb.com
GITHUB_PAT=<supplied by ShopperDB>
```

`REGISTRATION_SECRET` and `GITHUB_PAT` are both issued by ShopperDB during onboarding. The scripts prompt for them securely, then save encrypted copies locally so later runs reuse them without re-entering. Onboarding a new station never requires creating credentials of your own.

`SERVER_URL` defaults to `https://shopperdb.com` and the scripts fill it in for you. Change it only to point a test station at a development server.

### Store web address

A store with a name, city and state gets its own subdomain, e.g. `https://steves-wheels-and-deals-watertown-ct.shopperdb.com`. The scripts propose an address and ask you to confirm it:

```
  Proposed store address (36/63 characters):
    https://steves-wheels-and-deals-watertown-ct.shopperdb.com

Press Enter to accept, or type a different address:
```

The 63-character cap is the DNS limit for a single label. When a name is too long, only the name is shortened - at a word boundary - so the city and state that distinguish two stores of the same name always survive. Nothing is shortened silently: the proposal is a suggestion until you accept it.

### City and state are checked

The city and state are validated against a list of every US place before the address is proposed. Casing and spacing are corrected automatically - `watertown` becomes `Watertown`, `NEW BRITAIN` becomes `New Britain` - because the city ends up in the web address and a misspelling there is stuck in the subdomain permanently.

A city that is not on the list is flagged with near matches, and you decide:

```
  ** 'Watertwon, CT' is not in the US place list - check the spelling.
     Nearby matches: Waterbury, Waterford, Watertown
Enter the correct city, or press Enter to keep 'Watertwon':
```

It is a spell-check, not a gate. The list is thorough but not exhaustive, so a real address it happens to miss can still be used. A state that is not a real US state code *is* rejected, since there is no ambiguity there.

Check a place without touching a card:

```bash
./create-image.sh --check-place --store-city watertown --store-state ct   # -> Watertown, CT
```

```powershell
.\create-image.ps1 -CheckPlace -StoreCity watertown -StoreState ct
```

The list is `data/us-places.tsv`, built from the [US Census Gazetteer](https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html) (public domain). It ships with the repo, so none of this needs a network connection, an API key or an account. Regenerate it when a new year's file is published:

```bash
uv run tools/build_us_places.py
```

**You confirm an address once.** It is saved with the store name, city and state, and every later card for that same store reuses it without asking. Changing any of those three, or passing `--reconfirm-address` / `-ReconfirmAddress`, brings the prompt back.

Use `--print-slug` / `-PrintSlug` to see what address a store would get without touching a card:

```bash
./create-image.sh --print-slug --store-name "Steve's Wheels and Deals" --store-city Watertown --store-state CT
```

**Optional fields:**

| Field | Default | Description |
|-------|---------|-------------|
| `ADMIN_SSH_KEY` | *(blank)* | Full contents of an SSH public key. Added to `authorized_keys` for the admin account; disables password-based SSH if set. |
| `STORE_NAME` | *(blank)* | Display name for this station's public inventory page (e.g. `"Steve's Wheels and Deals"`). Use double quotes if the name contains spaces or an apostrophe. A store page is auto-created when the admin accepts the station. Leave blank to skip. |
| `STORE_CITY` | *(blank)* | Store city, used to build the store's web address. Written in its canonical spelling when the scripts recognise it. |
| `STORE_STATE` | *(blank)* | Store state, 2 letters, used to build the store's web address. |
| `STORE_SLUG` | *(blank)* | The confirmed web address label (the part before the domain). The server uses it as given rather than deriving one, so the address is exactly what was approved at imaging time. Capped at 63 characters because it is a subdomain name. Blank means the server derives one from `STORE_NAME`. |
| `SKIP_STORE_CREATE` | `false` | Set to `true` to suppress public store page creation entirely. The address fields are then ignored. |
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
| `data/us-places.tsv` | US place list for offline city/state validation (from the Census Gazetteer) |
| `tools/build_us_places.py` | Regenerates `data/us-places.tsv` from the Census source |
| `setup.ps1` | Windows: check and install prerequisites |
| `setup.sh` | Mac/Linux: check and install prerequisites |
