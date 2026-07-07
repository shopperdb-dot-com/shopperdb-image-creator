"""Tests for provision-image scripts and bundled support files."""

import json
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
