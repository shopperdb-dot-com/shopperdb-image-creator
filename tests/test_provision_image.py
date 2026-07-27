"""Tests for provision-image scripts and bundled support files."""

import json
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CREATE_SH = REPO_ROOT / "create-image.sh"
STATION_CONF_EXAMPLE = REPO_ROOT / "station.conf.example"
FIRST_BOOT_SH = REPO_ROOT / "first_boot.sh"
_DEFAULTS_FILE = REPO_ROOT / ".create-image.defaults.json"


@pytest.fixture(autouse=True)
def _restore_defaults():
    """Save and restore .create-image.defaults.json around each test to prevent pollution."""
    saved = _DEFAULTS_FILE.read_text() if _DEFAULTS_FILE.exists() else None
    yield
    if saved is not None:
        _DEFAULTS_FILE.write_text(saved)
    elif _DEFAULTS_FILE.exists():
        _DEFAULTS_FILE.unlink()


# ═════════════════════════════════════════════════════════════════════
# station.conf.example
# ═════════════════════════════════════════════════════════════════════


class TestProvisionConfExample:
    """station.conf.example must define all required and optional fields."""

    def test_required_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "SERVER_URL", "GITHUB_PAT"):
            assert field in content, f"Required field {field} missing from station.conf.example"

    def test_admin_ssh_key_field_present(self):
        assert "ADMIN_SSH_KEY=" in STATION_CONF_EXAMPLE.read_text()

    def test_wifi_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("WIFI_SSID", "WIFI_PASSWORD", "WIFI_COUNTRY"):
            assert field in content, f"WiFi field {field} missing from station.conf.example"

    def test_static_ip_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("STATIC_IP", "STATIC_GATEWAY", "STATIC_PREFIX", "STATIC_DNS"):
            assert field in content, f"Static IP field {field} missing from station.conf.example"

    def test_lcd_display_field_present_and_defaults_false(self):
        content = STATION_CONF_EXAMPLE.read_text()
        assert "LCD_DISPLAY=false" in content, "LCD_DISPLAY missing or not defaulted to false in station.conf.example"

    def test_required_fields_are_blank(self):
        """Template must ship with empty values - no accidental secrets committed."""
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "GITHUB_PAT"):
            assert f"{field}=\n" in content or f"{field}=" in content, (
                f"{field} in station.conf.example must have a blank value"
            )


# ═════════════════════════════════════════════════════════════════════
# first_boot.sh
# ═════════════════════════════════════════════════════════════════════


class TestFirstBootSh:
    """first_boot.sh is present, executable, and syntactically valid."""

    def test_file_exists(self):
        assert FIRST_BOOT_SH.exists(), "first_boot.sh not found in repo root"

    @pytest.mark.skipif(sys.platform == "win32", reason="file mode bits not meaningful on Windows")
    def test_file_is_executable(self):
        assert FIRST_BOOT_SH.stat().st_mode & stat.S_IXUSR, "first_boot.sh is not executable"

    @pytest.mark.bash
    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(FIRST_BOOT_SH)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"first_boot.sh syntax error:\n{result.stderr}"

    def test_provision_conf_path_referenced(self):
        """first_boot.sh must read from the standard station.conf location."""
        assert "/boot/firmware/station.conf" in FIRST_BOOT_SH.read_text()

    def test_references_bundled_path_not_scripts_subdir(self):
        """first_boot.sh in the image creator should not reference client/scripts/."""
        content = FIRST_BOOT_SH.read_text()
        assert "client/scripts/first_boot.sh" not in content, (
            "first_boot.sh comment still references client/scripts/ path from shopperdb repo"
        )

    def test_credentials_use_x_access_token_format(self):
        """Credentials must use https://x-access-token:TOKEN@github.com format.

        Writing just https://TOKEN@github.com puts the PAT in the username field;
        git falls back to interactive prompting with no password, which fails with
        'no such device or address' when running in a systemd service (no TTY).
        """
        content = FIRST_BOOT_SH.read_text()
        assert "x-access-token:" in content, (
            "first_boot.sh must use https://x-access-token:TOKEN@github.com format for git credentials"
        )

    def test_lcd_config_uses_device_tree_model_detection(self):
        """The LCD config must detect the board with the same /proc/device-tree/model
        method used for server registration, and gate on a Raspberry Pi match.
        """
        content = FIRST_BOOT_SH.read_text()
        assert "configure_lcd_display" in content, "first_boot.sh missing configure_lcd_display function"
        assert "/proc/device-tree/model" in content, (
            "first_boot.sh LCD config must read /proc/device-tree/model to detect the board"
        )

    def test_lcd_config_is_model_aware_for_usb_power(self):
        """Pi 4/5 (USB-C) must be handled separately from older micro-USB boards
        so max_usb_current is only applied where it is meaningful.
        """
        content = FIRST_BOOT_SH.read_text()
        assert "Raspberry Pi 5" in content and "Raspberry Pi 4" in content, (
            "first_boot.sh LCD config must branch on Pi 4/5 vs older boards"
        )
        assert "max_usb_current=1" in content, "first_boot.sh LCD config must set max_usb_current on micro-USB boards"

    def test_lcd_config_uses_kms_video_cmdline(self):
        """The forced HDMI mode must use the KMS video= cmdline mechanism, which is
        what actually applies on Bookworm/Trixie (legacy hdmi_* config.txt is ignored).
        """
        content = FIRST_BOOT_SH.read_text()
        assert "video=HDMI-A-1:1024x600M@60D" in content, (
            "first_boot.sh LCD config must set the KMS video= mode for the 1024x600 panel"
        )

    def test_lcd_config_gated_on_station_conf_flag(self):
        """LCD config must only run when LCD_DISPLAY=true is set in station.conf."""
        content = FIRST_BOOT_SH.read_text()
        assert 'LCD_DISPLAY="${LCD_DISPLAY:-false}"' in content, (
            "first_boot.sh must read LCD_DISPLAY from station.conf with a false default"
        )
        assert 'if [ "$LCD_DISPLAY" = "true" ]' in content, "first_boot.sh must gate LCD config on LCD_DISPLAY=true"

    def test_explicit_chown_after_fix_owner(self):
        """first_boot.sh must explicitly chown the credentials file when running as root.

        fix_owner() can silently fail on some filesystems; the explicit chown
        is a belt-and-suspenders fallback to ensure update.sh (runs as PI_USER)
        can always read the credentials file.
        """
        content = FIRST_BOOT_SH.read_text()
        cred_section = content[content.find("CRED_FILE=") : content.find("git config --global credential.helper")]
        assert 'chown "${PI_USER}:${PI_USER}" "$CRED_FILE"' in cred_section, (
            "first_boot.sh must explicitly chown the credentials file after fix_owner"
        )


# ═════════════════════════════════════════════════════════════════════
# create-image.sh
# ═════════════════════════════════════════════════════════════════════


class TestCreateImageShAdminHash:
    """create-image.sh embeds the admin password hash safely."""

    def test_admin_hash_placeholder_is_single_quoted(self):
        """The __ADMIN_PW_HASH__ placeholder must be surrounded by single quotes in the
        firstrun.sh template so bash does not expand the $ signs in the SHA-512 hash
        after string substitution. Double quotes would silently corrupt the hash.
        """
        content = CREATE_SH.read_text()
        assert "'__ADMIN_PW_HASH__'" in content, (
            "create-image.sh: __ADMIN_PW_HASH__ must be in single quotes in the firstrun.sh "
            "template to prevent bash $ expansion after substitution"
        )

    def test_no_userpassword_txt_reference(self):
        """Plaintext password file approach must not be used - passwords are managed
        via admin_password.hash baked into the image at creation time.
        """
        content = CREATE_SH.read_text()
        assert "userpassword.txt" not in content, (
            "create-image.sh still references userpassword.txt - plaintext password "
            "delivery has been replaced by admin_password.hash"
        )

    def test_hash_fetched_via_github_api_or_local_file(self):
        """Admin hash must come from the private shopperdb repo, never stored
        in the image-creator repo itself.
        """
        content = CREATE_SH.read_text()
        assert "admin_password.hash" in content, "create-image.sh does not reference admin_password.hash"
        assert "api.github.com" in content, "create-image.sh does not fall back to GitHub API for admin hash fetch"


@pytest.mark.bash
class TestProvisionImageShHelp:
    """create-image.sh --help and error handling."""

    def test_help_exits_zero(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--help"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0

    def test_help_contains_key_options(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--help"],
            capture_output=True,
            text=True,
        )
        for option in ("--image-path", "--boot-mount", "--server-url", "--github-pat", "--wifi-ssid"):
            assert option in result.stdout, f"--help output missing option: {option}"

    def test_unknown_option_fails(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--no-such-option"],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0

    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(CREATE_SH)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"create-image.sh syntax error:\n{result.stderr}"


@pytest.mark.bash
class TestProvisionImageShPath:
    """create-image.sh references the bundled first_boot.sh, not a parent scripts/ dir."""

    def test_first_boot_path_is_local(self):
        content = CREATE_SH.read_text()
        assert "../scripts/first_boot.sh" not in content, (
            "create-image.sh still references ../scripts/first_boot.sh - should use $SCRIPT_DIR/first_boot.sh"
        )

    def test_first_boot_path_in_script_dir(self):
        assert "$SCRIPT_DIR/first_boot.sh" in CREATE_SH.read_text()


@pytest.mark.bash
class TestProvisionOnly:
    """create-image.sh provision-only mode writes a valid station.conf."""

    def test_writes_provision_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2 rootfstype=ext4\n")

        result = subprocess.run(
            [
                "bash",
                str(CREATE_SH),
                "--boot-mount",
                str(boot),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test-secret-abc",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, f"create-image.sh failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        assert (boot / "station.conf").exists(), "station.conf was not written to boot mount"

    def test_provision_conf_contains_required_fields(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2\n")

        subprocess.run(
            [
                "bash",
                str(CREATE_SH),
                "--boot-mount",
                str(boot),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "my-test-secret",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        conf_text = (boot / "station.conf").read_text()
        assert "REGISTRATION_SECRET='my-test-secret'" in conf_text
        assert "SERVER_URL=http://192.168.1.100:8000" in conf_text
        assert "GITHUB_PAT=" in conf_text

    def test_nonexistent_boot_mount_fails(self, tmp_path):
        result = subprocess.run(
            [
                "bash",
                str(CREATE_SH),
                "--boot-mount",
                str(tmp_path / "nonexistent"),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test",
                "--github-pat",
                "ghp_testtoken123",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0

    def test_missing_github_pat_fails(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        result = subprocess.run(
            [
                "bash",
                str(CREATE_SH),
                "--boot-mount",
                str(boot),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test",
                "--github-pat",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0

    def _base_args(self, boot):
        return [
            "bash",
            str(CREATE_SH),
            "--boot-mount",
            str(boot),
            "--server-url",
            "http://192.168.1.100:8000",
            "--registration-secret",
            "test-secret",
            "--github-pat",
            "ghp_testtoken123",
            "--admin-ssh-key",
            "",
        ]

    def test_store_name_written_to_station_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        subprocess.run(
            self._base_args(boot) + ["--store-name", "Joe's Thrift Shop"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        conf_text = (boot / "station.conf").read_text()
        assert 'STORE_NAME="Joe\'s Thrift Shop"' in conf_text

    def test_skip_flags_written_to_station_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        subprocess.run(
            self._base_args(boot) + ["--skip-store-create", "--skip-test-print"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        conf_text = (boot / "station.conf").read_text()
        assert "SKIP_STORE_CREATE=true" in conf_text
        assert "SKIP_TEST_PRINT=true" in conf_text

    def test_lcd_display_flag_written_to_station_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        subprocess.run(
            self._base_args(boot) + ["--lcd-display"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert "LCD_DISPLAY=true" in (boot / "station.conf").read_text()

    def test_lcd_display_defaults_false_in_station_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        subprocess.run(self._base_args(boot), capture_output=True, text=True, timeout=30)
        assert "LCD_DISPLAY=false" in (boot / "station.conf").read_text()

    def test_encrypted_credentials_saved_to_defaults(self, tmp_path):
        """Sensitive values are AES-encrypted and written to the defaults file after a run."""
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        defaults_file = tmp_path / "defaults.json"

        script = CREATE_SH.read_text()
        patched = script.replace(
            'DEFAULTS_FILE="$SCRIPT_DIR/.create-image.defaults.json"',
            f'DEFAULTS_FILE="{defaults_file}"',
        )
        patched_script = tmp_path / "create-image-patched.sh"
        patched_script.write_text(patched)
        patched_script.chmod(0o755)

        subprocess.run(
            [
                "bash",
                str(patched_script),
                "--boot-mount",
                str(boot),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test-secret-xyz",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
                "--store-name",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env={"HOME": str(tmp_path), "PATH": "/usr/bin:/bin:/usr/local/bin"},
        )

        assert defaults_file.exists(), "defaults file was not created"
        defaults = json.loads(defaults_file.read_text())
        assert defaults.get("RegistrationSecretEnc"), (
            "RegistrationSecretEnc not saved to defaults - sensitive values not being encrypted"
        )
        assert defaults.get("GithubPatEnc"), "GithubPatEnc not saved to defaults - sensitive values not being encrypted"
        assert defaults["RegistrationSecretEnc"] != "test-secret-xyz", (
            "RegistrationSecretEnc stored as plaintext - encryption not applied"
        )

    def test_defaults_saved_and_loaded(self, tmp_path):
        """store name written on first run is reused on second run without --store-name."""
        boot1 = tmp_path / "boot1"
        boot1.mkdir()
        (boot1 / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        defaults_file = tmp_path / "defaults.json"

        env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin:/usr/local/bin"}
        script = CREATE_SH.read_text()
        patched = script.replace(
            'DEFAULTS_FILE="$SCRIPT_DIR/.create-image.defaults.json"',
            f'DEFAULTS_FILE="{defaults_file}"',
        )
        patched_script = tmp_path / "create-image-patched.sh"
        patched_script.write_text(patched)
        patched_script.chmod(0o755)

        subprocess.run(
            [
                "bash",
                str(patched_script),
                "--boot-mount",
                str(boot1),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
                "--store-name",
                "Saved Store Name",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
        )
        assert defaults_file.exists(), "defaults file was not created"

        boot2 = tmp_path / "boot2"
        boot2.mkdir()
        (boot2 / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        subprocess.run(
            [
                "bash",
                str(patched_script),
                "--boot-mount",
                str(boot2),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
        )
        conf_text = (boot2 / "station.conf").read_text()
        assert 'STORE_NAME="Saved Store Name"' in conf_text, (
            "store name from saved defaults was not written to station.conf on second run"
        )


@pytest.mark.bash
class TestWifiStationConf:
    """WiFi credentials are written correctly to station.conf.

    Uses a patched defaults file so tests don't pollute .create-image.defaults.json
    with a non-empty WifiSsid that would cause WiFi password prompts in other tests.
    """

    def _run_with_wifi(self, tmp_path, ssid, password):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2\n")
        defaults_file = tmp_path / "defaults.json"

        script = CREATE_SH.read_text()
        patched = script.replace(
            'DEFAULTS_FILE="$SCRIPT_DIR/.create-image.defaults.json"',
            f'DEFAULTS_FILE="{defaults_file}"',
        )
        patched_script = tmp_path / "create-image-patched.sh"
        patched_script.write_text(patched)
        patched_script.chmod(0o755)

        result = subprocess.run(
            [
                "bash",
                str(patched_script),
                "--boot-mount",
                str(boot),
                "--server-url",
                "http://192.168.1.100:8000",
                "--registration-secret",
                "test-secret",
                "--github-pat",
                "ghp_testtoken123",
                "--admin-ssh-key",
                "",
                "--wifi-ssid",
                ssid,
                "--wifi-password",
                password,
                "--store-name",
                "",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, f"create-image.sh failed:\n{result.stdout}\n{result.stderr}"
        return (boot / "station.conf").read_text()

    def test_ssid_written_to_station_conf(self, tmp_path):
        content = self._run_with_wifi(tmp_path, "MyNetwork", "MyPassword1")
        assert "WIFI_SSID=MyNetwork" in content

    def test_wifi_password_written_to_station_conf(self, tmp_path):
        content = self._run_with_wifi(tmp_path, "MyNetwork", "MyPassword1")
        assert "WIFI_PASSWORD='MyPassword1'" in content

    def test_country_written_to_station_conf(self, tmp_path):
        content = self._run_with_wifi(tmp_path, "MyNetwork", "MyPassword1")
        assert "WIFI_COUNTRY=US" in content


# ═════════════════════════════════════════════════════════════════════
# Store web address (subdomain label)
# ═════════════════════════════════════════════════════════════════════

CREATE_PS1 = REPO_ROOT / "create-image.ps1"

# name, city, state -> expected address. The same table drives both implementations, so the
# bash and PowerShell copies cannot drift apart unnoticed.
SLUG_CASES = [
    ("Steve's Wheels and Deals", "Watertown", "CT", "steves-wheels-and-deals-watertown-ct"),
    ("Shop", "", "", "shop"),
    ("  --Foo & Bar!!  ", "", "", "foo-bar"),
    ("Cafe Bleu", "Hartford", "CT", "cafe-bleu-hartford-ct"),
    # Too long: the name is shortened at a word boundary, the city/state tail survives intact.
    (
        "Steves Wheels and Deals Automotive Sales and Service Center",
        "Watertown",
        "CT",
        "steves-wheels-and-deals-automotive-sales-and-watertown-ct",
    ),
    (
        "Northern Connecticut Automotive Repair and Tire Service",
        "New Britain",
        "CT",
        "northern-connecticut-automotive-repair-and-tire-new-britain-ct",
    ),
]

SLUG_MAX_LENGTH = 63


def _slug_via_bash(name, city, state):
    result = subprocess.run(
        [
            "bash",
            str(CREATE_SH),
            "--print-slug",
            "--store-name",
            name,
            "--store-city",
            city,
            "--store-state",
            state,
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _slug_via_powershell(name, city, state):
    result = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-File",
            str(CREATE_PS1),
            "-PrintSlug",
            "-StoreName",
            name,
            "-StoreCity",
            city,
            "-StoreState",
            state,
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


_HAS_PWSH = shutil.which("pwsh") is not None


class TestStoreAddress:
    """The store address is a DNS label, so it is capped at 63 characters.

    An over-length address produces a store that looks correct everywhere but whose subdomain
    never resolves, so this is checked before the card is written rather than after.
    """

    @pytest.mark.bash
    @pytest.mark.parametrize(("name", "city", "state", "expected"), SLUG_CASES)
    def test_bash_proposes_expected_address(self, name, city, state, expected):
        code, out, err = _slug_via_bash(name, city, state)
        assert code == 0, err
        assert out == expected

    @pytest.mark.bash
    def test_bash_proposal_never_exceeds_the_limit(self):
        code, out, _ = _slug_via_bash("A" * 200, "Watertown", "CT")
        assert code == 0
        assert len(out) <= SLUG_MAX_LENGTH
        assert out.endswith("-watertown-ct")  # the disambiguating tail is preserved
        assert not out.endswith("-")  # a label may not end in a hyphen

    @pytest.mark.bash
    @pytest.mark.parametrize("bad", ["www", "admin", "a" * 64, "Upper", "double--hyphen", "-lead"])
    def test_bash_rejects_invalid_addresses(self, bad):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--print-slug", "--store-name", "x", "--store-slug", bad],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0, f"{bad!r} should have been rejected"

    @pytest.mark.bash
    def test_bash_print_slug_requires_a_store_name(self):
        code, _, _ = _slug_via_bash("", "Watertown", "CT")
        assert code != 0

    @pytest.mark.skipif(not _HAS_PWSH, reason="pwsh not installed")
    @pytest.mark.parametrize(("name", "city", "state", "expected"), SLUG_CASES)
    def test_powershell_proposes_expected_address(self, name, city, state, expected):
        code, out, err = _slug_via_powershell(name, city, state)
        assert code == 0, err
        assert out == expected

    @pytest.mark.bash  # needs a real bash; on Windows "bash" resolves to WSL
    @pytest.mark.skipif(not _HAS_PWSH, reason="pwsh not installed")
    @pytest.mark.parametrize(("name", "city", "state", "_expected"), SLUG_CASES)
    def test_both_implementations_agree(self, name, city, state, _expected):
        """The rules live in three places (server, bash, PowerShell); two of them are checked here.

        Drift between them is the real risk of duplicating the logic, so it is asserted directly
        rather than assumed.
        """
        _, bash_out, _ = _slug_via_bash(name, city, state)
        _, ps_out, _ = _slug_via_powershell(name, city, state)
        assert bash_out == ps_out


PRODUCTION_URL = "https://shopperdb.com"


class TestServerUrlBothImplementations:
    """Checked statically so the PowerShell side is covered on Windows too, where bash is skipped."""

    def test_both_default_to_production(self):
        assert f'DEFAULT_SERVER_URL="{PRODUCTION_URL}"' in CREATE_SH.read_text()
        assert f"$script:DefaultServerUrl = '{PRODUCTION_URL}'" in CREATE_PS1.read_text()

    def test_neither_caches_the_override(self):
        sh = CREATE_SH.read_text()
        assert "_load_saved ServerUrl" not in sh
        assert '"ServerUrl":       "_D_SERVER_URL"' not in sh
        ps1 = CREATE_PS1.read_text()
        assert "ServerUrl             = $ServerUrl" not in ps1
        assert "'ServerUrl','AdminSshKeyPath'" not in ps1

    def test_the_store_domain_is_shown_in_the_proposal(self):
        assert 'STORE_DOMAIN="shopperdb.com"' in CREATE_SH.read_text()
        assert "$script:StoreDomain = 'shopperdb.com'" in CREATE_PS1.read_text()

    def test_both_offer_a_reconfirm_escape_hatch(self):
        assert "--reconfirm-address" in CREATE_SH.read_text()
        assert "$ReconfirmAddress" in CREATE_PS1.read_text()


@pytest.mark.bash
class TestServerUrl:
    """Cards are built for the production site; the dev override must never be sticky.

    A card pointed at a laptop is indistinguishable from a real one until it boots and fails
    to register, so the default is fixed and any override is announced.
    """

    def test_defaults_to_production_without_being_asked(self, tmp_path):
        boot = _boot(tmp_path)
        result = _run_provision(boot, "--store-name", "")
        assert result.returncode == 0, result.stderr
        assert f"SERVER_URL={PRODUCTION_URL}" in (boot / "station.conf").read_text()

    def test_flag_overrides_the_default(self, tmp_path):
        boot = _boot(tmp_path)
        result = _run_provision(boot, "--store-name", "", "--server-url", "http://192.168.2.100:8000")
        assert result.returncode == 0, result.stderr
        assert "SERVER_URL=http://192.168.2.100:8000" in (boot / "station.conf").read_text()

    def test_an_override_is_announced(self, tmp_path):
        boot = _boot(tmp_path)
        result = _run_provision(boot, "--store-name", "", "--server-url", "http://192.168.2.100:8000")
        assert "override" in result.stdout.lower()

    def test_a_url_without_a_scheme_is_rejected(self, tmp_path):
        boot = _boot(tmp_path)
        result = _run_provision(boot, "--store-name", "", "--server-url", "192.168.2.100:8000")
        assert result.returncode != 0
        assert not (boot / "station.conf").exists()

    def test_a_trailing_slash_is_trimmed(self, tmp_path):
        boot = _boot(tmp_path)
        result = _run_provision(boot, "--store-name", "", "--server-url", "https://shopperdb.com/")
        assert result.returncode == 0, result.stderr
        assert f"SERVER_URL={PRODUCTION_URL}\n" in (boot / "station.conf").read_text()

    def test_the_override_is_not_remembered(self, tmp_path):
        """The whole point: a dev URL used once must not ship on the next real card."""
        boot = _boot(tmp_path)
        _run_provision(boot, "--store-name", "", "--server-url", "http://192.168.2.100:8000")
        saved = json.loads(_DEFAULTS_FILE.read_text(encoding="utf-8-sig"))
        assert "ServerUrl" not in saved

        boot2 = _boot(tmp_path / "second")
        result = _run_provision(boot2, "--store-name", "")
        assert result.returncode == 0, result.stderr
        assert f"SERVER_URL={PRODUCTION_URL}" in (boot2 / "station.conf").read_text()

    def test_a_stale_cached_url_is_ignored_and_purged(self, tmp_path):
        """Earlier versions cached ServerUrl - an existing one must not resurrect."""
        boot = _boot(tmp_path)
        _DEFAULTS_FILE.write_text(json.dumps({"ServerUrl": "http://192.168.2.100:8000"}, indent=2))
        result = _run_provision(boot, "--store-name", "")
        assert result.returncode == 0, result.stderr
        assert f"SERVER_URL={PRODUCTION_URL}" in (boot / "station.conf").read_text()
        assert "ServerUrl" not in json.loads(_DEFAULTS_FILE.read_text(encoding="utf-8-sig"))


class TestStoreAddressInConf:
    """station.conf.example and the writers must carry the address fields."""

    @pytest.mark.parametrize("field", ["STORE_CITY", "STORE_STATE", "STORE_SLUG"])
    def test_example_defines_the_field(self, field):
        assert f"{field}=" in STATION_CONF_EXAMPLE.read_text()

    @pytest.mark.parametrize("field", ["STORE_CITY", "STORE_STATE", "STORE_SLUG"])
    def test_bash_writer_emits_the_field(self, field):
        assert f"{field}=" in CREATE_SH.read_text()

    @pytest.mark.parametrize("field", ["STORE_CITY", "STORE_STATE", "STORE_SLUG"])
    def test_powershell_writer_emits_the_field(self, field):
        assert f"{field}=" in CREATE_PS1.read_text()

    def test_address_is_saved_between_runs(self):
        """The confirmed address is remembered so later cards for the same store reuse it."""
        assert '"StoreSlug":       "_D_STORE_SLUG"' in CREATE_SH.read_text()
        assert "StoreSlug             = $StoreSlug" in CREATE_PS1.read_text()


def _boot(tmp_path):
    boot = tmp_path / "bootfs"
    boot.mkdir(parents=True)
    (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2\n")
    return boot


def _run_provision(boot, *extra):
    """Provision-only run with no terminal attached.

    Prompts read /dev/tty, so a run that needs to ask something fails here instead of hanging.
    That makes "did it prompt?" directly observable: a successful run asked nothing.
    """
    return subprocess.run(
        [
            "bash",
            str(CREATE_SH),
            "--boot-mount",
            str(boot),
            "--registration-secret",
            "test-secret",
            "--github-pat",
            "ghp_testtoken123",
            "--admin-ssh-key",
            "",
            *extra,
        ],
        capture_output=True,
        text=True,
        timeout=30,
        stdin=subprocess.DEVNULL,
    )


STORE_ARGS = ("--store-name", "Steve's Wheels and Deals", "--store-city", "Watertown", "--store-state", "CT")
STORE_SLUG = "steves-wheels-and-deals-watertown-ct"


@pytest.mark.bash
class TestStoreAddressIsRemembered:
    """An address is confirmed once, then reused for every later card for the same store.

    Re-confirming on every run is how a second card for one store ends up on a different
    subdomain, so the saved value is reused unless something that would move it changed.
    """

    def _seed(self, **values):
        _DEFAULTS_FILE.write_text(json.dumps(values, indent=2))

    def test_saved_address_is_reused_without_asking(self, tmp_path):
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug=STORE_SLUG,
        )
        result = _run_provision(boot)
        assert result.returncode == 0, result.stderr
        assert f'STORE_SLUG="{STORE_SLUG}"' in (boot / "station.conf").read_text()
        assert "Proposed store address" not in result.stdout

    def test_a_differently_cased_city_is_the_same_answer(self, tmp_path):
        """Inputs are compared slugified, so "watertown" does not count as a change."""
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug=STORE_SLUG,
        )
        result = _run_provision(boot, "--store-city", "watertown")
        assert result.returncode == 0, result.stderr
        assert f'STORE_SLUG="{STORE_SLUG}"' in (boot / "station.conf").read_text()

    @pytest.mark.parametrize(
        ("flag", "value"),
        [("--store-city", "Hartford"), ("--store-state", "MA"), ("--store-name", "Different Store")],
    )
    def test_changing_the_store_identity_asks_again(self, tmp_path, flag, value):
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug=STORE_SLUG,
        )
        result = _run_provision(boot, flag, value)
        assert result.returncode != 0, "a moved address must be re-confirmed, not reused"
        assert not (boot / "station.conf").exists()

    def test_reconfirm_flag_asks_again(self, tmp_path):
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug=STORE_SLUG,
        )
        result = _run_provision(boot, "--reconfirm-address")
        assert result.returncode != 0
        assert not (boot / "station.conf").exists()

    def test_an_unusable_saved_address_is_not_reused(self, tmp_path):
        """A hand-edited or over-long saved value must not slip through unvalidated."""
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug="a" * 64,
        )
        result = _run_provision(boot, *STORE_ARGS)
        assert result.returncode != 0
        assert not (boot / "station.conf").exists()

    def test_explicit_slug_overrides_the_saved_one(self, tmp_path):
        boot = _boot(tmp_path)
        self._seed(
            StoreName="Steve's Wheels and Deals",
            StoreCity="Watertown",
            StoreState="CT",
            StoreSlug=STORE_SLUG,
        )
        result = _run_provision(boot, "--store-slug", "steves-wheels-hartford-ct")
        assert result.returncode == 0, result.stderr
        assert 'STORE_SLUG="steves-wheels-hartford-ct"' in (boot / "station.conf").read_text()

    @pytest.mark.parametrize(
        "extra",
        [
            ("--store-name", "Joe's Thrift Shop"),
            ("--store-name", "Joe's Thrift Shop", "--store-city", "Watertown", "--store-state", "CT"),
        ],
    )
    def test_a_run_with_no_terminal_finishes_instead_of_hanging(self, tmp_path, extra):
        """Every prompt reads /dev/tty, so with no terminal an unanswered question loops forever.

        This hung the whole run rather than failing it, which is worse: a scripted build sits
        until something kills it. With nobody to confirm an address, none is invented - the
        city/state still travel and the server derives the address, refusing any that would
        not resolve.
        """
        boot = _boot(tmp_path)
        _DEFAULTS_FILE.unlink(missing_ok=True)
        result = _run_provision(boot, *extra)
        assert result.returncode == 0, result.stderr
        conf = (boot / "station.conf").read_text()
        assert 'STORE_NAME="Joe\'s Thrift Shop"' in conf
        assert 'STORE_SLUG=""' in conf  # nothing confirmed, so nothing claimed

    def test_defaults_written_with_a_bom_are_still_read(self, tmp_path):
        """create-image.ps1 writes this file with a BOM; a plain utf-8 read fails on it
        silently, making every saved value - including the address - look absent."""
        boot = _boot(tmp_path)
        payload = json.dumps(
            {
                "StoreName": "Steve's Wheels and Deals",
                "StoreCity": "Watertown",
                "StoreState": "CT",
                "StoreSlug": STORE_SLUG,
            },
            indent=2,
        )
        _DEFAULTS_FILE.write_bytes(b"\xef\xbb\xbf" + payload.encode("utf-8"))
        result = _run_provision(boot)
        assert result.returncode == 0, result.stderr
        assert f'STORE_SLUG="{STORE_SLUG}"' in (boot / "station.conf").read_text()
