<#
.SYNOPSIS
    Prepares a Raspberry Pi SD card: optionally flashes the OS image,
    writes firstrun.sh for OS customisation, and writes station.conf -
    without opening Raspberry Pi Imager.

.DESCRIPTION
    Two modes:

    Full mode  (-ImagePath provided):
      1. Flashes the OS image via Raspberry Pi Imager CLI.
      2. Writes firstrun.sh (hostname, user/password, SSH, WiFi, locale).
      3. Writes station.conf (GitHub PAT, registration secret, etc.).

    Provision-only mode  (-ImagePath omitted):
      Writes station.conf to an already-mounted boot partition.
      Use when the card was flashed and customised separately.

    Secrets are prompted securely unless supplied as arguments or available
    from a previous run's encrypted saved defaults.
    Admin password is stored as a SHA-512 crypt hash (hash_password.py, stdlib-only).

.PARAMETER ImagePath
    Path to a .img or .img.xz file. Triggers full mode when supplied.

.PARAMETER DiskNumber
    SD card disk number (from Get-Disk). Auto-detected when one
    removable USB disk is present.

.PARAMETER Drive
    Boot partition drive letter (e.g. D). Auto-detected from removable
    FAT32 volumes labeled "bootfs" when omitted.

.PARAMETER Hostname
    Pi hostname. Default: sbc-shopperdb

.PARAMETER Username
    Pi OS user to create. Default: admin

.PARAMETER Timezone
    Pi timezone. Default: America/New_York

.PARAMETER KeyboardLayout
    Keyboard layout. Default: us

.PARAMETER WifiSsid
    WiFi SSID. Leave blank for Ethernet-only.

.PARAMETER WifiPassword
    WiFi password. Prompted securely when WifiSsid is set.

.PARAMETER WifiCountry
    WiFi regulatory country code. Default: US

.PARAMETER WifiSecurity
    WiFi security type: wpa2 (default) or open (no password).

.PARAMETER WifiHidden
    Pass this switch if the network has a hidden SSID.

.PARAMETER Locale
    System locale written to /etc/locale.gen. Default: en_US.UTF-8

.PARAMETER ServerUrl
    Server URL for initial registration. Example: http://192.168.2.100:8000

.PARAMETER RegistrationSecret
    Shared secret provided by the server administrator. Prompted securely if omitted.

.PARAMETER GithubPat
    GitHub fine-grained PAT with read-only Contents access to the shopperdb
    repo. Used by the Pi to clone and pull updates. Prompted securely if not supplied.

.PARAMETER AdminSshKeyPath
    Admin SSH public key file. Enables passwordless SSH on the Pi.
    Default: $env:USERPROFILE\.ssh\id_ed25519.pub
    Pass "" to skip.

.PARAMETER StoreName
    Display name for this station's public store page (e.g. "Steve's Wheels and Deals").
    A store page is auto-created when the admin accepts the station.
    Saved between runs. Leave blank for no public store page.

.PARAMETER SkipStoreCreate
    Set to $true to suppress public store page creation. Default: $false.

.PARAMETER SkipTestPrint
    Skip the printer test label during first provisioning. Default: $false.
    This flag is never cached - omitting it always means false regardless of previous runs.

.PARAMETER SkipFlash
    Skip flashing; write firstrun.sh and station.conf to an already-flashed SD card.
    The boot partition must already be mounted and visible as a drive letter.

.PARAMETER ResetDefaults
    Wipe the saved defaults file (.create-image.defaults.json) before this run.
    All prompts revert to their built-in defaults as if run for the first time.

.PARAMETER StaticIp, StaticGateway, StaticPrefix, StaticDns
    Optional static IP. Leave blank for DHCP.

.EXAMPLE
    .\create-image.ps1 -ImagePath "C:\images\raspios-trixie-arm64-lite.img.xz"
    Full automation. Prompts for passwords and the registration secret (or reuses saved values).

.EXAMPLE
    .\create-image.ps1 -SkipFlash
    Write firstrun.sh and station.conf to an already-flashed SD card without re-flashing.

.EXAMPLE
    .\create-image.ps1
    Provision-only. Writes station.conf to the already-mounted boot partition.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ImagePath,
    [int]$DiskNumber     = -1,
    [string]$Drive,

    # OS customisation (firstrun.sh, full mode only)
    [string]$Hostname        = "sbc-shopperdb",
    [string]$Username        = "admin",
    [string]$Timezone        = "America/New_York",
    [string]$KeyboardLayout  = "us",

    # WiFi (used in both firstrun.sh and station.conf)
    [string]$WifiSsid,
    [string]$WifiPassword,
    [string]$WifiCountry   = "US",
    [ValidateSet("wpa2","open")][string]$WifiSecurity = "wpa2",
    [switch]$WifiHidden,

    # OS locale
    [string]$Locale = "en_US.UTF-8",

    # station.conf
    [string]$ServerUrl,
    [string]$RegistrationSecret,
    [string]$GithubPat,
    [string]$AdminSshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub",
    [string]$StoreName,
    [switch]$SkipStoreCreate,
    [switch]$SkipTestPrint,
    [string]$StaticIp,
    [string]$StaticGateway,
    [string]$StaticPrefix = "24",
    [string]$StaticDns    = "8.8.8.8,1.1.1.1",

    # Wipe all saved defaults and start fresh (does not affect this run's values)
    [switch]$ResetDefaults,

    # Skip flash; write firstrun.sh + station.conf to an already-flashed card
    [switch]$SkipFlash
)

# Capture which params were explicitly supplied before any defaults are applied
$_explicitParams = [System.Collections.Generic.HashSet[string]]($PSBoundParameters.Keys)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Step { param([string]$m) Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  OK $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  ** $m" -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "  XX $m" -ForegroundColor Red; exit 1 }

function Read-Secure {
    param([string]$Prompt)
    [Console]::Write("${Prompt}: ")

    $prevCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    $chars = [System.Collections.Generic.List[char]]::new()

    try {
        while ($true) {
            $key = [Console]::ReadKey($true)

            if ($key.KeyChar -eq [char]3) {
                [Console]::WriteLine("")
                exit 1
            }
            if ($key.Key -eq [ConsoleKey]::Enter -or $key.KeyChar -eq [char]13) {
                [Console]::WriteLine("")
                break
            }
            if ($key.Key -eq [ConsoleKey]::Backspace -or $key.KeyChar -eq [char]8 -or $key.KeyChar -eq [char]127) {
                if ($chars.Count -gt 0) {
                    $chars.RemoveAt($chars.Count - 1)
                    [Console]::Write([char]8)
                    [Console]::Write(' ')
                    [Console]::Write([char]8)
                }
                continue
            }
            if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                $chars.Add($key.KeyChar)
                [Console]::Write('*')
            }
        }
    } finally {
        [Console]::TreatControlCAsInput = $prevCtrlC
    }

    return -join $chars
}


function Find-RpiImager {
    @(
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Wait-BootPartition {
    param([int]$TimeoutSeconds = 45)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vol = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FileSystemLabel -eq "bootfs" -and
                $_.FileSystem -in @("FAT32","FAT") -and
                $_.DriveType -eq "Removable" -and
                $_.DriveLetter
            } | Select-Object -First 1
        if ($vol) { return $vol }
        Start-Sleep 2
        $elapsed += 2
    }
    return $null
}

# ── USB disk classification ───────────────────────────────────────────────────

# VIDs of chipmakers whose USB mass storage products are almost exclusively card readers.
# Tested against: Genesys Logic GL3310 (VID 05E3, PID 0751) confirmed on this machine.
$script:CardReaderVids = [System.Collections.Generic.HashSet[string]]([string[]]@(
    '05E3',  # Genesys Logic  - most common card reader controller
    '0BDA',  # Realtek        - card readers (also audio/ethernet, but not as mass storage)
    '058F',  # Alcor Micro    - card readers
    '0CF2',  # ENE Technology - card readers
    '14CD',  # Super Top      - card readers
    '0C4B',  # Reachi         - card readers
    '1A40',  # TERMINUS Technology
    '04E6',  # SCM Microsystems - smart card / card readers
    '0D7D',  # Arkmicro       - card readers
    '1908'   # GEMBIRD        - card readers
))

# VIDs of consumer storage brands that produce thumb drives.
# A device with one of these VIDs and a product string that does NOT look like
# a card reader is treated as a thumb drive.
$script:ThumbDriveVids = [System.Collections.Generic.HashSet[string]]([string[]]@(
    '0781',  # SanDisk
    '0951',  # Kingston Technology
    '8564',  # Transcend (JetFlash)
    '18A5',  # Verbatim
    '05DC',  # Lexar Media
    '13FE',  # Phison Electronics (OEM in many branded drives)
    '1F75',  # Innostor Technology
    '048D',  # Integrated Technology Express
    '1307'   # USBest Technology
))

function Get-DiskVidPid {
    # Walks HKLM\...\Enum\USB to find the USB device whose ContainerID matches
    # the disk's ContainerID, then returns its VID and PID.
    param([string]$DiskPnpId)
    $regDisk = "HKLM:\SYSTEM\CurrentControlSet\Enum\$DiskPnpId"
    $containerId = (Get-ItemProperty -Path $regDisk -Name 'ContainerID' -ErrorAction SilentlyContinue).ContainerID
    if (-not $containerId) { return $null }

    $usbRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
    foreach ($vidPidKey in Get-ChildItem $usbRoot -ErrorAction SilentlyContinue) {
        foreach ($instanceKey in Get-ChildItem $vidPidKey.PSPath -ErrorAction SilentlyContinue) {
            $cid = (Get-ItemProperty -Path $instanceKey.PSPath -Name 'ContainerID' -ErrorAction SilentlyContinue).ContainerID
            if ($cid -eq $containerId -and $vidPidKey.PSChildName -match 'VID_([0-9A-Fa-f]+)&PID_([0-9A-Fa-f]+)') {
                return @{ VID = $Matches[1].ToUpper(); PID = $Matches[2].ToUpper() }
            }
        }
    }
    return $null
}

function Get-DiskUsbDetail {
    # Returns classification info for a USB disk. IsCardReader / IsThumbDrive are
    # set based on: (1) USB VID via ContainerID registry walk, and (2) the USBSTOR
    # vendor/product strings. VID takes precedence; product strings are a fallback.
    param([int]$Number)
    $result = [PSCustomObject]@{
        Vendor       = ""
        Product      = ""
        Vid          = ""
        IsCardReader = $false
        IsThumbDrive = $false
        SizeWarning  = ""
    }
    try {
        $wmi = Get-CimInstance Win32_DiskDrive -Filter "Index=$Number" -ErrorAction Stop
        if ($wmi.PNPDeviceID -match 'VEN_([^&\\]+)')  { $result.Vendor  = ($Matches[1] -replace '_',' ').Trim() }
        if ($wmi.PNPDeviceID -match 'PROD_([^&\\]+)') { $result.Product = ($Matches[1] -replace '_',' ').Trim() }
        if ($wmi.Size -gt 0) {
            $sizeGb = $wmi.Size / 1GB
            if ($sizeGb -lt 4)   { $result.SizeWarning = "only $([Math]::Round($sizeGb,1)) GB - may be too small for Pi OS" }
            if ($sizeGb -gt 512) { $result.SizeWarning = "$([Math]::Round($sizeGb,0)) GB - unusually large for an SD card" }
        }

        # Primary signal: USB VID from ContainerID registry walk (~50 ms)
        $vidPid = Get-DiskVidPid -DiskPnpId $wmi.PNPDeviceID
        if ($vidPid) {
            $result.Vid = $vidPid.VID
            if ($script:CardReaderVids.Contains($vidPid.VID)) {
                $result.IsCardReader = $true
                return $result
            }
        }
    } catch {}

    # Fallback: classify by USBSTOR vendor/product string
    $upper = "$($result.Vendor) $($result.Product)".ToUpper()

    if ($upper -match 'CRW|CARD.READER|SD.CARD|SDHC|SDXC|SDUC|MULTI.?CARD|CF.CARD|MASSSTORAGE') {
        $result.IsCardReader = $true
        return $result
    }

    # Thumb drive indicators from product string
    $thumbPatterns = @(
        'DATATRAVELER', 'JETFLASH', 'CRUZER', 'JUMPDRIVE', 'JUMP.DRIVE',
        'FLASH.VOYAGER', 'ULTRA.USB', 'ULTRA.FIT', 'ULTRA.FLAIR', 'ULTRA.DUAL',
        'USB.FLASH', 'FLASH.DRIVE',
        '\d\.\d\s*GEN\d'   # USB spec version as product name - thumb drive signature
    )
    foreach ($p in $thumbPatterns) {
        if ($upper -match $p) { $result.IsThumbDrive = $true; return $result }
    }

    # VID from a known thumb drive brand (and product string gave no counter-signal)
    if ($result.Vid -and $script:ThumbDriveVids.Contains($result.Vid)) {
        $result.IsThumbDrive = $true
    }

    return $result
}

function Format-DiskLine {
    param($DiskObj, $Detail)
    $sizeStr = if ($DiskObj.Size -gt 0) { "$([Math]::Round($DiskObj.Size/1GB,1)) GB" } else { "? GB" }
    $vidStr  = if ($Detail.Vid)     { " VID:$($Detail.Vid)" } else { "" }
    $prodStr = if ($Detail.Product) { " $($Detail.Vendor) $($Detail.Product)" } else { "" }
    $tag = if ($Detail.IsCardReader)  { " [SD adapter]" }
           elseif ($Detail.IsThumbDrive) { " [!] thumb drive" }
           else                          { " [unclassified]" }
    return "Disk $($DiskObj.Number): $($DiskObj.FriendlyName)$prodStr$vidStr - $sizeStr$tag"
}

# ── Saved defaults (persisted across runs via DPAPI-encrypted JSON) ───────────

$script:ConfigPath = Join-Path $PSScriptRoot ".create-image.defaults.json"

function Import-Conf {
    if (-not (Test-Path $script:ConfigPath)) { return @{} }
    try {
        $obj = Get-Content $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    }
    catch { return @{} }
}

function Export-Conf {
    param([hashtable]$Config)
    try { $Config | ConvertTo-Json -Depth 2 | Set-Content $script:ConfigPath -Encoding UTF8 }
    catch { Warn "Could not save defaults: $_" }
}

function Protect-Value {
    param([string]$PlainText)
    if (-not $PlainText) { return "" }
    try { return ConvertFrom-SecureString (ConvertTo-SecureString $PlainText -AsPlainText -Force) }
    catch { return "" }
}

function Unprotect-Value {
    param([string]$Encrypted)
    if (-not $Encrypted) { return "" }
    try {
        $ss  = ConvertTo-SecureString $Encrypted
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return "" }
}

# Like Read-Secure, but if a saved (DPAPI-encrypted) value exists the prompt
# shows "[saved - Enter to keep]" and pressing Enter returns that saved value.
function Read-DefaultSecure {
    param([string]$Prompt, [string]$SavedEnc = "")
    $savedPlain = Unprotect-Value $SavedEnc
    if ($savedPlain) {
        [Console]::Write("${Prompt} [saved - Enter to keep]: ")
    } else {
        [Console]::Write("${Prompt}: ")
    }

    $prevCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    $chars = [System.Collections.Generic.List[char]]::new()
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq [char]3)                                                                        { [Console]::WriteLine(""); exit 1 }
            if ($key.Key -eq [ConsoleKey]::Enter -or $key.KeyChar -eq [char]13)                                  { [Console]::WriteLine(""); break }
            if ($key.Key -eq [ConsoleKey]::Backspace -or $key.KeyChar -eq [char]8 -or $key.KeyChar -eq [char]127) {
                if ($chars.Count -gt 0) {
                    $chars.RemoveAt($chars.Count - 1)
                    [Console]::Write([char]8); [Console]::Write(' '); [Console]::Write([char]8)
                }
                continue
            }
            if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                $chars.Add($key.KeyChar); [Console]::Write('*')
            }
        }
    } finally { [Console]::TreatControlCAsInput = $prevCtrlC }

    $entered = -join $chars
    if ($entered)     { return $entered }
    if ($savedPlain)  { return $savedPlain }
    return ""
}


# ── Load saved defaults ───────────────────────────────────────────────────────

$_cfg = if ($ResetDefaults) { @{} } else { Import-Conf }
if ($ResetDefaults) { Ok "Saved defaults cleared (-ResetDefaults)" }

# Apply saved non-sensitive values for any param that was not explicitly provided.
# SkipTestPrint and SkipStoreCreate are intentionally excluded: they are one-time
# run flags (default false), not persistent preferences. Omitting them on the
# command line always means false, never the last cached value.
foreach ($k in @('ImagePath','Hostname','Username','Timezone','KeyboardLayout',
                  'WifiSsid','WifiCountry','WifiSecurity','WifiHidden','Locale',
                  'ServerUrl','AdminSshKeyPath','StoreName',
                  'StaticIp','StaticGateway','StaticPrefix','StaticDns')) {
    if (-not $_explicitParams.Contains($k)) {
        $saved = if ($_cfg.ContainsKey($k)) { $_cfg[$k] } else { $null }
        if ($saved -ne $null -and $saved -ne '') {
            if ($k -in @('WifiHidden')) { Set-Variable -Name $k -Value ([bool]$saved) -Scope Script }
            else                        { Set-Variable -Name $k -Value ([string]$saved) -Scope Script }
        }
    }
}

# Stash saved encrypted values - used later in prompts
$_savedWifiPwEnc     = if ($_cfg.ContainsKey('WifiPasswordEnc'))       { $_cfg['WifiPasswordEnc'] }       else { '' }
$_savedGithubPatEnc  = if ($_cfg.ContainsKey('GithubPatEnc'))          { $_cfg['GithubPatEnc'] }          else { '' }
$_savedRegSecEnc     = if ($_cfg.ContainsKey('RegistrationSecretEnc')) { $_cfg['RegistrationSecretEnc'] } else { '' }


# Resolve ImagePath directory -> specific .img.xz file
if ($ImagePath -and (Test-Path $ImagePath -PathType Container)) {
    $imgFiles = @(Get-ChildItem -Path $ImagePath -Filter "*.img.xz" -File)
    if ($imgFiles.Count -eq 0) {
        Fail "No .img.xz files found in: $ImagePath"
    } elseif ($imgFiles.Count -eq 1) {
        $ImagePath = $imgFiles[0].FullName
    } else {
        $imgFiles = $imgFiles | Sort-Object LastWriteTime -Descending
        Write-Host ""
        Write-Host "  Multiple images found - select one:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $imgFiles.Count; $i++) {
            Write-Host "  [$($i+1)] $($imgFiles[$i].Name)  ($($imgFiles[$i].LastWriteTime.ToString('yyyy-MM-dd')))" -ForegroundColor Gray
        }
        $choice = [int](Read-Host "  Select image (1-$($imgFiles.Count))")
        if ($choice -lt 1 -or $choice -gt $imgFiles.Count) { Fail "Invalid selection." }
        $ImagePath = $imgFiles[$choice-1].FullName
    }
}

# ── Header ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  ShopperDB Pi - Image Preparation" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
$fullMode = ($ImagePath -ne "") -or $SkipFlash
$modeLabel = if ($SkipFlash) { 'Customise + Provision (flash skipped)' } elseif ($fullMode) { 'Flash + Customise + Provision' } else { 'Provision only' }
Write-Host "  Mode: $modeLabel" -ForegroundColor Gray
if ($fullMode -and -not $SkipFlash) { Write-Host "  Image: $(Split-Path $ImagePath -Leaf)" -ForegroundColor Gray }
Write-Host ""

if ($fullMode -and -not $SkipFlash) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) {
        Fail "Full mode requires administrator privileges (rpi-imager needs elevation to write to a disk).`n  Re-run this script from an elevated PowerShell prompt: Run as Administrator."
    }
}

# ── Step 1: Flash the image (full mode only) ──────────────────────────────────

if ($fullMode -and -not $SkipFlash) {
    if (-not (Test-Path $ImagePath)) { Fail "Image file not found: $ImagePath" }

    # Find target disk
    if ($DiskNumber -eq -1) {
        Step "Searching for removable USB disk..."
        $removable = @(Get-Disk | Where-Object {
            $_.BusType -eq "USB" -and $_.OperationalStatus -eq "Online"
        })
        if ($removable.Count -eq 0) {
            Fail "No removable USB disk found. Insert the SD card and try again."
        }

        Step "Classifying USB devices..."
        $candidates = @($removable | ForEach-Object {
            [PSCustomObject]@{ Disk = $_; Detail = (Get-DiskUsbDetail -Number $_.Number) }
        })

        if ($removable.Count -gt 1) {
            $cardReaders = @($candidates | Where-Object { $_.Detail.IsCardReader })
            $thumbDrives = @($candidates | Where-Object { $_.Detail.IsThumbDrive })

            if ($cardReaders.Count -eq 1) {
                # Unambiguous: one card reader, everything else is a thumb drive or unknown
                $picked = $cardReaders[0]
                $DiskNumber = $picked.Disk.Number
                Ok "Target: $(Format-DiskLine -DiskObj $picked.Disk -Detail $picked.Detail)"
                if ($picked.Detail.SizeWarning) { Warn "Size: $($picked.Detail.SizeWarning)" }
                $thumbDrives | ForEach-Object {
                    Warn "Skipping Disk $($_.Disk.Number) ($($_.Disk.FriendlyName)) - detected as USB thumb drive"
                }
            } else {
                # Ambiguous (0 or 2+ card readers) - list all and ask
                Write-Host "  Removable USB disks found:" -ForegroundColor Yellow
                $candidates | ForEach-Object {
                    $line   = Format-DiskLine -DiskObj $_.Disk -Detail $_.Detail
                    $color  = if ($_.Detail.IsThumbDrive) { 'Yellow' } else { 'Gray' }
                    Write-Host "    $line" -ForegroundColor $color
                    if ($_.Detail.SizeWarning) { Write-Host "      Size: $($_.Detail.SizeWarning)" -ForegroundColor Yellow }
                }
                $DiskNumber = [int](Read-Host "  Enter disk number for the SD card")
            }
        } else {
            # Single removable disk - refuse to auto-select if it looks like a thumb drive
            $only = $candidates[0]
            if ($only.Detail.IsThumbDrive) {
                Write-Host ""
                Warn "$($only.Disk.FriendlyName) ($([Math]::Round($only.Disk.Size/1GB,1)) GB) was detected as a USB thumb drive."
                Warn "Remove thumb drives and insert only the SD card adapter, or pass -DiskNumber $($only.Disk.Number) to override."
                exit 1
            }
            $DiskNumber = $only.Disk.Number
            Ok "Target: $(Format-DiskLine -DiskObj $only.Disk -Detail $only.Detail)"
            if ($only.Detail.SizeWarning) { Warn "Size: $($only.Detail.SizeWarning)" }
        }
    }

    $disk = Get-Disk -Number $DiskNumber
    # Post-selection thumb drive check (covers explicit -DiskNumber overrides)
    $diskDetail = Get-DiskUsbDetail -Number $DiskNumber
    if ($diskDetail.IsThumbDrive) {
        Warn "Disk $DiskNumber ($($disk.FriendlyName)) looks like a USB thumb drive - verify before proceeding."
    }

    Write-Host ""
    Write-Host "  About to flash:" -ForegroundColor Yellow
    Write-Host "    Source: $(Split-Path $ImagePath -Leaf)" -ForegroundColor Yellow
    Write-Host "    Target: $(Format-DiskLine -DiskObj $disk -Detail $diskDetail)" -ForegroundColor Yellow
    Write-Host "    WARNING: ALL DATA ON THE DISK WILL BE ERASED" -ForegroundColor Red
    Write-Host "    Popups for Windows Explorer & Insert Disk are normal & expected during this process" -ForegroundColor Red
    Write-Host ""
    if ((Read-Host "Type YES to continue") -ne "YES") { Write-Host "Aborted."; exit 0 }

    $imager = Find-RpiImager
    if (-not $imager) {
        Fail "Raspberry Pi Imager not found. Install from raspberrypi.com/software."
    }
    Ok "Raspberry Pi Imager: $imager"

    Step "Flashing $([Math]::Round((Get-Item $ImagePath).Length/1MB)) MB image to Disk $DiskNumber..."
    Step "This takes several minutes - output is shown below when complete."
    Write-Host ""

    # rpi-imager spawns a child process for the actual disk write and the parent
    # exits early. Using System.Diagnostics.Process with redirected streams causes
    # the child to inherit the captured handles, so WaitAll blocks until the
    # entire process tree (parent + write backend) finishes and closes stdout.
    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $imager
    $psi.Arguments              = "--cli `"$ImagePath`" `"\\.\PhysicalDrive${DiskNumber}`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false

    $imagerProc = New-Object System.Diagnostics.Process
    $imagerProc.StartInfo = $psi
    $imagerProc.Start() | Out-Null

    $outTask = $imagerProc.StandardOutput.ReadToEndAsync()
    $errTask = $imagerProc.StandardError.ReadToEndAsync()
    [System.Threading.Tasks.Task]::WaitAll($outTask, $errTask)
    $imagerProc.WaitForExit()

    $imagerOut = $outTask.Result
    if ($imagerOut) { Write-Host $imagerOut.TrimEnd() }
    Write-Host ""

    $writeOk = $imagerProc.ExitCode -eq 0 -or ($imagerOut -match "Write successful")
    if (-not $writeOk) {
        Fail "rpi-imager failed (exit $($imagerProc.ExitCode)). Check output above."
    }
    Ok "Image written"

    # rpi-imager ejects the disk; wait for Windows to re-enumerate the partition
    Step "Waiting for boot partition to appear (up to 60 s)..."
    $bootVol = Wait-BootPartition -TimeoutSeconds 60
    if (-not $bootVol) {
        Warn "Boot partition not detected automatically."
        Write-Host "  Safely eject and re-insert the SD card, then re-run without -ImagePath." -ForegroundColor Gray
        exit 1
    }
    $Drive = $bootVol.DriveLetter
    Ok "Boot partition: ${Drive}: (bootfs)"
}

# ── Step 2: Find boot partition (provision-only mode) ─────────────────────────

if (-not $Drive) {
    Step "Looking for boot partition (FAT32, label 'bootfs')..."
    $bootVol = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FileSystemLabel -eq "bootfs" -and
            $_.FileSystem -in @("FAT32","FAT") -and
            $_.DriveType -eq "Removable" -and
            $_.DriveLetter
        } | Select-Object -First 1

    if ($bootVol) {
        $Drive = $bootVol.DriveLetter
        Ok "Boot partition: ${Drive}: (bootfs)"
    } else {
        $candidates = @(Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystem -in @("FAT32","FAT") -and $_.DriveType -eq "Removable" -and $_.DriveLetter })
        if ($candidates.Count -eq 1) {
            $Drive = $candidates[0].DriveLetter
            Warn "No 'bootfs' label - using only removable FAT32 drive: ${Drive}: ($($candidates[0].FileSystemLabel))"
        } elseif ($candidates.Count -gt 1) {
            Warn "Multiple removable FAT32 drives:"
            $candidates | ForEach-Object { Write-Host "  $($_.DriveLetter): ($($_.FileSystemLabel))" }
            $Drive = (Read-Host "Enter drive letter for the Pi boot partition").TrimEnd(':').Trim()
        } else {
            Fail "No removable FAT32 drive found. Insert the SD card or specify -Drive D"
        }
    }
}

$Drive    = $Drive.TrimEnd(':')
$bootPath = "${Drive}:"
if (-not (Test-Path $bootPath)) { Fail "Drive ${bootPath} not found." }

# ── Step 3: Collect passwords and generate firstrun.sh (full mode only) ───────

if ($fullMode) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Step 3: Collect credentials for the Pi image" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""

    # Admin password hash - read from committed file, embedded in firstrun.sh.
    # firstrun.sh runs as root on Boot 1, so no sudo is needed to apply it.
    # Rotation is handled by update.sh reading admin_password.hash from the repo.
    $adminHashFile = Join-Path $PSScriptRoot "admin_password.hash"
    if (-not (Test-Path $adminHashFile)) {
        # Fall back to the sibling shopperdb repo if both are checked out together
        $adminHashFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\shopperdb\client\scripts\admin_password.hash"))
    }
    if (-not (Test-Path $adminHashFile)) {
        Fail "admin_password.hash not found.`nExpected: $PSScriptRoot\admin_password.hash`nGenerate with: printf '%s' 'password' | uv run python hash_password.py > admin_password.hash"
    }
    $AdminPwHash = (Get-Content $adminHashFile -Raw).Trim()
    if ($AdminPwHash -notmatch '^\$6\$[a-zA-Z0-9./]{1,16}\$[a-zA-Z0-9./]{86}$') {
        Fail "admin_password.hash does not contain a valid SHA-512 crypt hash (expected: `$6`$<1-16 char salt>`$<86 char hash>)."
    }
    Ok "Admin password: loaded from $(Split-Path $adminHashFile -Leaf)"

    if ($WifiSsid -and $WifiSecurity -ne "open" -and -not $WifiPassword) {
        if ($_savedWifiPwEnc -and -not $_explicitParams.Contains('WifiPassword')) {
            $WifiPassword = Unprotect-Value $_savedWifiPwEnc
        } else {
            $savedWifiPw  = Unprotect-Value $_savedWifiPwEnc
            $WifiPassword = Read-DefaultSecure "WiFi password for '$WifiSsid'" $_savedWifiPwEnc
            if ($WifiPassword -ne $savedWifiPw) {
                $wifiConfirm = Read-Secure "Confirm WiFi password for '$WifiSsid'"
                if ($WifiPassword -ne $wifiConfirm) { Fail "WiFi passwords do not match." }
            }
        }
    }

    # Build the WiFi block. imager_custom set_wpa takes <ssid> <password> <country> (3 args).
    # scan_ssid=1 is needed for hidden networks in the wpa_supplicant fallback path.
    $wifiHiddenInt = if ($WifiHidden) { "1" } else { "0" }

    if ($WifiSsid) {
        if ($WifiSecurity -eq "open") {
            $wifiBlock = @"
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '__SSID__' '' '__COUNTRY__'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'WPAEOF'
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
fi
"@
        } else {
            $wifiBlock = @"
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '__SSID__' '__WIFIPW__' '__COUNTRY__'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'WPAEOF'
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
fi
"@
        }
    } else {
        $wifiBlock = "# No WiFi configured - Ethernet-only deployment"
    }

    # firstrun.sh template - uses placeholder tokens to avoid PowerShell
    # escape conflicts with bash dollar signs and backticks.
    $firstrunTemplate = @'
#!/bin/bash
# firstrun.sh - generated by provision-image.ps1
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
'@

    # String.Replace() is a literal substitution - unlike PowerShell's -replace
    # operator (which uses .NET regex replacement syntax), it treats $ in the
    # replacement value as a plain character. This is essential for the password
    # hash ($6$salt$...) and any passwords that contain $ characters.
    $firstrun = $firstrunTemplate
    $firstrun = $firstrun.Replace('__HOSTNAME__',        $Hostname)
    $firstrun = $firstrun.Replace('__USERNAME__',        $Username)
    $firstrun = $firstrun.Replace('__ADMIN_PW_HASH__',   $AdminPwHash)
    $firstrun = $firstrun.Replace('__KEYBOARD__',        $KeyboardLayout)
    $firstrun = $firstrun.Replace('__TIMEZONE__',        $Timezone)
    $firstrun = $firstrun.Replace('__LOCALE__',          $Locale)
    # __WIFI_BLOCK__ must be substituted before the individual WiFi tokens
    # because __SSID__ etc. only exist inside $wifiBlock, not in the template itself.
    $firstrun = $firstrun.Replace('__WIFI_BLOCK__',      $wifiBlock)
    $firstrun = $firstrun.Replace('__SSID__',            $WifiSsid)
    $firstrun = $firstrun.Replace('__WIFIPW__',          $WifiPassword)
    $firstrun = $firstrun.Replace('__COUNTRY__',         $WifiCountry)
    $firstrun = $firstrun.Replace('__WIFI_HIDDEN_INT__', $wifiHiddenInt)

    # Write firstrun.sh - LF line endings, no BOM
    $firstrunPath = Join-Path $bootPath "firstrun.sh"
    [IO.File]::WriteAllText($firstrunPath, $firstrun.Replace("`r`n","`n"), [Text.UTF8Encoding]::new($false))
    Ok "firstrun.sh written: $firstrunPath"

    # Write first_boot.sh to boot partition - firstrun.sh copies it to /opt/shopperdb/
    # and installs shopperdb-setup.service which runs it on Boot 2.
    $firstBootSrc = Join-Path $PSScriptRoot "first_boot.sh"
    if (Test-Path $firstBootSrc) {
        $firstBootContent = [IO.File]::ReadAllText($firstBootSrc)
        $firstBootPath = Join-Path $bootPath "first_boot.sh"
        [IO.File]::WriteAllText($firstBootPath, $firstBootContent.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        Ok "first_boot.sh written to boot partition"
    } else {
        Fail "first_boot.sh not found at $firstBootSrc"
    }

    # Modify cmdline.txt to trigger firstrun.sh on first boot
    $cmdlinePath = Join-Path $bootPath "cmdline.txt"
    if (Test-Path $cmdlinePath) {
        $cmdline = (Get-Content $cmdlinePath -Raw).TrimEnd("`r","`n"," ")
        if ($cmdline -notmatch "systemd.run=") {
            $trigger = " systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.run_failure_action=reboot"
            [IO.File]::WriteAllText($cmdlinePath, $cmdline + $trigger + "`n", [Text.UTF8Encoding]::new($false))
            Ok "cmdline.txt updated to trigger firstrun.sh on boot"
        } else {
            Ok "cmdline.txt already has systemd.run entry"
        }
    } else {
        Warn "cmdline.txt not found - firstrun.sh will not run automatically"
    }
}

# ── Step 4: station.conf ────────────────────────────────────────────────────

# Server URL - saved config, then auto-detect + prompt
if (-not $ServerUrl) {
    $defaultUrl = ""
    $localIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch "^(127\.|169\.254\.)" -and
            $_.PrefixOrigin -in @("Dhcp","Manual") -and
            $_.InterfaceAlias -notmatch "^(vEthernet|Loopback|Tunnel|isatap|Teredo)"
        } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if ($localIp) { $defaultUrl = "http://${localIp}:8000" }
    $urlPrompt  = if ($defaultUrl) { "Server URL [$defaultUrl]" } else { "Server URL (e.g. http://192.168.2.100:8000)" }
    $urlEntered = (Read-Host $urlPrompt).Trim()
    $ServerUrl  = if ($urlEntered) { $urlEntered } else { $defaultUrl }
}
if (-not $ServerUrl) { Fail "SERVER_URL is required." }
Ok "Server URL: $ServerUrl"

# Registration secret - saved fallback, then prompt
if (-not $RegistrationSecret) {
    if ($_savedRegSecEnc -and -not $_explicitParams.Contains('RegistrationSecret')) {
        $RegistrationSecret = Unprotect-Value $_savedRegSecEnc
        if ($RegistrationSecret) { Ok "Registration secret: using saved value" }
    }
}
if (-not $RegistrationSecret) {
    $RegistrationSecret = Read-DefaultSecure "Registration secret (provided by server administrator)" $null
}
if (-not $RegistrationSecret) { Fail "REGISTRATION_SECRET is required." }

# GitHub PAT
if (-not $GithubPat) {
    if ($_savedGithubPatEnc -and -not $_explicitParams.Contains('GithubPat')) {
        $GithubPat = Unprotect-Value $_savedGithubPatEnc
    } else {
        $GithubPat = Read-DefaultSecure "GitHub PAT (inventory-fleet-deploy, read-only Contents)" $_savedGithubPatEnc
    }
}
if (-not $GithubPat) { Fail "GITHUB_PAT is required." }
if ($GithubPat -notmatch "^ghp_|^github_pat_") { Warn "PAT does not look like a GitHub token (expected ghp_ or github_pat_ prefix)" }
Ok "GitHub PAT: provided"

# Admin SSH public key
$adminSshKey = ""
if ($AdminSshKeyPath -ne "" -and (Test-Path $AdminSshKeyPath -ErrorAction SilentlyContinue)) {
    $adminSshKey = (Get-Content $AdminSshKeyPath -Raw).Trim()
    if ($adminSshKey -notmatch "^ssh-") {
        Warn "Not an SSH public key: $AdminSshKeyPath"
        $adminSshKey = ""
    } else {
        Ok "Admin SSH key: $AdminSshKeyPath"
    }
} elseif ($AdminSshKeyPath -ne "") {
    Warn "Admin SSH key not found: $AdminSshKeyPath - password auth remains active"
}

# Store name (optional) - prompt only when no saved value and not passed explicitly
if (-not $_explicitParams.Contains('StoreName') -and -not $StoreName) {
    $entered = (Read-Host "Store display name (optional - Enter to skip)").Trim()
    if ($entered) { $StoreName = $entered }
}
if ($StoreName) { Ok "Store name: $StoreName" } else { Ok "Store name: (none - no public store page)" }

# WiFi password for station.conf (may already be set from firstrun.sh step)
if ($WifiSsid -and $WifiSecurity -ne "open" -and -not $WifiPassword) {
    if ($_savedWifiPwEnc -and -not $_explicitParams.Contains('WifiPassword')) {
        $WifiPassword = Unprotect-Value $_savedWifiPwEnc
    } else {
        $WifiPassword = Read-DefaultSecure "WiFi password for '$WifiSsid'" $_savedWifiPwEnc
    }
}

# Write station.conf
$outFile        = Join-Path $bootPath "station.conf"
$adminLine      = if ($adminSshKey)  { "ADMIN_SSH_KEY='$adminSshKey'" }   else { "ADMIN_SSH_KEY=" }
$wifiPassLine   = if ($WifiPassword) { "WIFI_PASSWORD='$WifiPassword'" }  else { "WIFI_PASSWORD=" }
# Double-quote the store name so apostrophes and spaces survive bash source
$storeNameLine  = if ($StoreName)    { "STORE_NAME=`"${StoreName}`"" }    else { "STORE_NAME=" }
$skipStoreLine    = "SKIP_STORE_CREATE=" + ($SkipStoreCreate.ToString().ToLower())
$skipPrintLine    = "SKIP_TEST_PRINT="   + ($SkipTestPrint.ToString().ToLower())

Step "Writing station.conf to $outFile..."

$conf = @"
# station.conf - First-boot configuration for inventory client station
# Written by create-image.ps1
#
# Sensitive fields are zeroed automatically after successful first boot.

# REQUIRED
REGISTRATION_SECRET='$RegistrationSecret'
SERVER_URL=$ServerUrl
GITHUB_PAT='$GithubPat'

# OPTIONAL - Admin SSH public key (enables passwordless SSH, disables password auth)
$adminLine

# OPTIONAL - Store display name for this Pi's public inventory page.
# If set, a store page is auto-created when the admin accepts the station.
$storeNameLine
$skipStoreLine
$skipPrintLine

# OPTIONAL - WiFi (leave blank for Ethernet-only)
WIFI_SSID=$WifiSsid
$wifiPassLine
WIFI_COUNTRY=$WifiCountry

# OPTIONAL - Static IP (leave blank for DHCP)
STATIC_IP=$StaticIp
STATIC_GATEWAY=$StaticGateway
STATIC_PREFIX=$StaticPrefix
STATIC_DNS=$StaticDns
"@

[IO.File]::WriteAllText($outFile, $conf.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
Ok "station.conf written"

# Save non-sensitive settings and DPAPI-encrypted secrets for next run
$newCfg = [ordered]@{
    ImagePath             = $ImagePath
    Hostname              = $Hostname
    Username              = $Username
    Timezone              = $Timezone
    KeyboardLayout        = $KeyboardLayout
    WifiSsid              = $WifiSsid
    WifiCountry           = $WifiCountry
    WifiSecurity          = $WifiSecurity
    WifiHidden            = [bool]$WifiHidden
    Locale                = $Locale
    ServerUrl             = $ServerUrl
    AdminSshKeyPath       = $AdminSshKeyPath
    StoreName             = $StoreName
    StaticIp              = $StaticIp
    StaticGateway         = $StaticGateway
    StaticPrefix          = $StaticPrefix
    StaticDns             = $StaticDns
    WifiPasswordEnc       = if ($WifiPassword)        { Protect-Value $WifiPassword }        else { $_savedWifiPwEnc }
    GithubPatEnc          = if ($GithubPat)           { Protect-Value $GithubPat }           else { $_savedGithubPatEnc }
    RegistrationSecretEnc = if ($RegistrationSecret)  { Protect-Value $RegistrationSecret }  else { $_savedRegSecEnc }
}
Export-Conf $newCfg
Ok "Settings saved for next run ($($script:ConfigPath | Split-Path -Leaf))"

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Done" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
if ($fullMode) {
    Write-Host "  The SD card is ready. Safely eject it from Windows, then:" -ForegroundColor Gray
    Write-Host "  1. Insert into the Pi and power on" -ForegroundColor Gray
    Write-Host "  2. Boot 1: firstrun.sh runs, Pi reboots automatically (~1 min)" -ForegroundColor Gray
    Write-Host "  3. Boot 2: first_boot.sh runs - provisioning + registration (~5 min)" -ForegroundColor Gray
    Write-Host "  4. Accept the station at: $ServerUrl/admin/clients" -ForegroundColor Gray
    Write-Host "  5. Monitor: ssh ${Username}@<pi-ip>  then: tail -f ~/first-boot.log" -ForegroundColor Gray
} else {
    Write-Host "  Safely eject the SD card, insert into the Pi, and power on." -ForegroundColor Gray
    Write-Host "  first_boot.sh runs on the next boot (~5 min)." -ForegroundColor Gray
    Write-Host "  Accept the station at: $ServerUrl/admin/clients" -ForegroundColor Gray
}
Write-Host ""
