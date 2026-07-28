"""City/state validation against the bundled US Census place list.

The city feeds the store's web address, so a typo there is baked into the subdomain permanently
and cannot be fixed without re-imaging. These check that the shipped dataset is well-formed, that
bash and PowerShell resolve places identically, and that an unlisted place is reported rather than
rejected - the list is thorough but not exhaustive.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CREATE_SH = REPO_ROOT / "create-image.sh"
CREATE_PS1 = REPO_ROOT / "create-image.ps1"
PLACES_FILE = REPO_ROOT / "data" / "us-places.tsv"

sys.path.insert(0, str(REPO_ROOT / "tools"))
from build_us_places import canonical_name, common_name, normalize_key, strip_ma_town_artifact  # noqa: E402

_HAS_PWSH = shutil.which("pwsh") is not None

# city, state -> canonical spelling. Drives both implementations, so they cannot drift apart.
# Every entry is here because it exercises a rule that was wrong at some point.
PLACE_CASES = [
    ("watertown", "CT", "Watertown"),
    ("WATERTOWN", "CT", "Watertown"),
    ("  watertown  ", "ct", "Watertown"),
    ("new britain", "CT", "New Britain"),
    ("NEW BRITAIN", "CT", "New Britain"),
    # Abbreviations people use interchangeably with the spelled-out form.
    ("saint louis", "MO", "St. Louis"),
    ("st louis", "MO", "St. Louis"),
    ("St. Louis", "MO", "St. Louis"),
    ("mount vernon", "NY", "Mount Vernon"),
    # Consolidated city-county governments: the official name is not what anyone types.
    ("nashville", "TN", "Nashville"),
    ("nashville-davidson", "TN", "Nashville"),
    ("louisville", "KY", "Louisville"),
    ("lexington", "KY", "Lexington"),
    ("athens", "GA", "Athens"),
    ("indianapolis", "IN", "Indianapolis"),
    # Ordinary hyphenated names are single places and must survive intact.
    ("winston-salem", "NC", "Winston-Salem"),
    ("wilkes-barre", "PA", "Wilkes-Barre"),
    # Massachusetts municipalities carry a Census-added "Town" that is not part of the name.
    ("watertown", "MA", "Watertown"),
    ("agawam", "MA", "Agawam"),
    ("methuen", "MA", "Methuen"),
    # ... but these places really are named that way.
    ("old town", "ME", "Old Town"),
    ("new town", "ND", "New Town"),
    ("charles town", "WV", "Charles Town"),
    # A name that ends in "City" keeps it.
    ("carson city", "NV", "Carson City"),
]


def _place_via_bash(city, state):
    result = subprocess.run(
        ["bash", str(CREATE_SH), "--check-place", "--store-city", city, "--store-state", state],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result.returncode, result.stdout.strip()


def _place_via_powershell(city, state):
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(CREATE_PS1), "-CheckPlace", "-StoreCity", city, "-StoreState", state],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result.returncode, result.stdout.strip()


class TestDatasetIntegrity:
    """A malformed dataset would silently reject every real city, so its shape is asserted."""

    def test_file_is_present_and_substantial(self):
        assert PLACES_FILE.exists(), "data/us-places.tsv missing - run tools/build_us_places.py"
        lines = [ln for ln in PLACES_FILE.read_text(encoding="utf-8").splitlines() if not ln.startswith("#")]
        assert len(lines) > 30000, f"only {len(lines)} places - the dataset looks truncated"

    def test_every_row_has_three_fields(self):
        for i, line in enumerate(PLACES_FILE.read_text(encoding="utf-8").splitlines(), 1):
            if line.startswith("#") or not line:
                continue
            parts = line.split("\t")
            assert len(parts) == 3, f"line {i} has {len(parts)} fields, expected 3"
            assert parts[1].isupper() and len(parts[1]) == 2, f"line {i}: bad state {parts[1]!r}"
            assert parts[2].strip(), f"line {i}: empty canonical name"

    def test_keys_are_already_normalized(self):
        """A key the lookup could never produce is dead weight and hides a generator bug."""
        for line in PLACES_FILE.read_text(encoding="utf-8").splitlines():
            if line.startswith("#") or not line:
                continue
            key = line.split("\t")[0]
            assert key == normalize_key(key), f"key {key!r} is not in normalized form"

    def test_no_duplicate_key_and_state(self):
        seen = set()
        for line in PLACES_FILE.read_text(encoding="utf-8").splitlines():
            if line.startswith("#") or not line:
                continue
            key, state, _ = line.split("\t")
            assert (key, state) not in seen, f"duplicate entry for {key!r} in {state}"
            seen.add((key, state))

    def test_the_shipped_file_uses_lf(self):
        """A CRLF checkout leaves a carriage return on the last field of every row, so every
        city resolves to "Watertown\\r". .gitattributes pins the file to LF and both readers
        strip a stray CR anyway; this catches the pinning itself regressing."""
        assert b"\r" not in PLACES_FILE.read_bytes(), "dataset has CRLF line endings"

    def test_covers_every_state(self):
        states = {ln.split("\t")[1] for ln in PLACES_FILE.read_text(encoding="utf-8").splitlines() if "\t" in ln}
        assert len(states) >= 51, f"only {len(states)} states present"
        for expected in ("CT", "MA", "CA", "TX", "AK", "HI", "DC"):
            assert expected in states


class TestGeneratorRules:
    """The name-cleaning rules, checked directly so a failure points at the rule, not the data."""

    @pytest.mark.parametrize(
        ("raw", "expected", "consolidated"),
        [
            ("Watertown town", "Watertown", False),
            ("Watertown CDP", "Watertown", False),
            ("Hartford city", "Hartford", False),
            ("Winston-Salem city", "Winston-Salem", False),
            ("Carson City", "Carson City", False),
            ("Princeton", "Princeton", False),
            ("Nashville-Davidson metropolitan government (balance)", "Nashville-Davidson", True),
            ("Lexington-Fayette urban county", "Lexington-Fayette", True),
            ("Indianapolis city (balance)", "Indianapolis", True),
        ],
    )
    def test_suffix_stripping(self, raw, expected, consolidated):
        name, is_consolidated = canonical_name(raw)
        assert name == expected
        assert is_consolidated == consolidated

    def test_hyphen_split_only_applies_to_merged_governments(self):
        """Winston-Salem is one place; splitting it would produce a city called "Winston"."""
        assert common_name("Winston-Salem", consolidated=False) == "Winston-Salem"
        assert common_name("Wilkes-Barre", consolidated=False) == "Wilkes-Barre"
        assert common_name("Nashville-Davidson", consolidated=True) == "Nashville"
        assert common_name("Macon-Bibb County", consolidated=False) == "Macon"

    def test_the_massachusetts_town_artifact_is_state_scoped(self):
        assert strip_ma_town_artifact("Watertown Town", "MA") == "Watertown"
        assert strip_ma_town_artifact("Old Town", "ME") == "Old Town"
        assert strip_ma_town_artifact("New Town", "ND") == "New Town"
        assert strip_ma_town_artifact("Charles Town", "WV") == "Charles Town"

    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("Saint Louis", "st louis"),
            ("St. Louis", "st louis"),
            ("Mount Vernon", "mt vernon"),
            ("Fort Worth", "ft worth"),
            ("  NEW   BRITAIN  ", "new britain"),
            ("Winston-Salem", "winston salem"),
            ("Coeur d'Alene", "coeur d alene"),
        ],
    )
    def test_key_normalization(self, raw, expected):
        assert normalize_key(raw) == expected


@pytest.mark.bash
class TestBashPlaceLookup:
    @pytest.mark.parametrize(("city", "state", "expected"), PLACE_CASES)
    def test_resolves_the_canonical_spelling(self, city, state, expected):
        code, out = _place_via_bash(city, state)
        assert code == 0, f"{city}, {state} was not found"
        assert out == f"{expected}, {state.upper()}"

    @pytest.mark.parametrize(("city", "state"), [("Watertwon", "CT"), ("Nowhereville", "CT")])
    def test_rejects_an_unknown_city(self, city, state):
        code, _ = _place_via_bash(city, state)
        assert code != 0

    def test_rejects_an_unknown_state(self):
        code, _ = _place_via_bash("Watertown", "XX")
        assert code != 0


@pytest.mark.skipif(not _HAS_PWSH, reason="pwsh not installed")
class TestPowerShellPlaceLookup:
    @pytest.mark.parametrize(("city", "state", "expected"), PLACE_CASES)
    def test_resolves_the_canonical_spelling(self, city, state, expected):
        code, out = _place_via_powershell(city, state)
        assert code == 0, f"{city}, {state} was not found"
        assert out == f"{expected}, {state.upper()}"

    def test_rejects_an_unknown_city(self):
        code, _ = _place_via_powershell("Watertwon", "CT")
        assert code != 0


@pytest.mark.bash  # needs a real bash; on Windows "bash" resolves to WSL
@pytest.mark.skipif(not _HAS_PWSH, reason="pwsh not installed")
@pytest.mark.parametrize(("city", "state", "_expected"), PLACE_CASES)
def test_both_implementations_agree(city, state, _expected):
    """The lookup rules live in bash, PowerShell and Python; drift is the real risk of that."""
    _, bash_out = _place_via_bash(city, state)
    _, ps_out = _place_via_powershell(city, state)
    assert bash_out == ps_out


@pytest.mark.bash
class TestCityValidationDuringImaging:
    """What actually reaches station.conf, which is the only thing the server ever sees."""

    def _run(self, boot, *extra):
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
                "--store-name",
                "Steve's Wheels and Deals",
                *extra,
            ],
            capture_output=True,
            text=True,
            timeout=60,
            stdin=subprocess.DEVNULL,
        )

    def _boot(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir(parents=True)
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        return boot

    @pytest.mark.parametrize("typed", ["watertown", "WATERTOWN", "  Watertown  "])
    def test_the_canonical_spelling_is_written(self, tmp_path, typed):
        boot = self._boot(tmp_path)
        result = self._run(boot, "--store-city", typed, "--store-state", "ct")
        assert result.returncode == 0, result.stderr
        conf = (boot / "station.conf").read_text()
        assert 'STORE_CITY="Watertown"' in conf
        assert 'STORE_STATE="CT"' in conf

    def test_an_unknown_city_warns_but_does_not_block(self, tmp_path):
        """The list is thorough but not exhaustive; refusing a real address it misses is worse."""
        boot = self._boot(tmp_path)
        result = self._run(boot, "--store-city", "Watertwon", "--store-state", "CT")
        assert result.returncode == 0, result.stderr
        assert "not in the US place list" in result.stdout
        assert 'STORE_CITY="Watertwon"' in (boot / "station.conf").read_text()

    def test_near_matches_are_offered_for_a_typo(self, tmp_path):
        boot = self._boot(tmp_path)
        result = self._run(boot, "--store-city", "Watertwon", "--store-state", "CT")
        assert "Watertown" in result.stdout, "a near match should be suggested"

    def test_the_verified_city_feeds_the_web_address(self, tmp_path):
        """Canonicalising the city must not change the slug, or a cached address would break."""
        boot = self._boot(tmp_path)
        result = self._run(boot, "--store-city", "WATERTOWN", "--store-state", "ct", "--print-slug")
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "steves-wheels-and-deals-watertown-ct"
