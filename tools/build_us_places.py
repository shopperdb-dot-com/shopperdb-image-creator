#!/usr/bin/env python3
"""Regenerate data/us-places.tsv from the US Census Gazetteer.

The Gazetteer is public domain, so the generated file ships with the repo and the scripts never
touch the network. Run this to refresh it when a new year's file is published:

    uv run tools/build_us_places.py            # downloads the current source
    uv run tools/build_us_places.py FILE.txt   # uses an already-downloaded copy

Source: https://www.census.gov/geographies/reference-files/time-series/geo/gazetteer-files.html

The output is `<key>\\t<STATE>\\t<Canonical Name>` sorted by key, which is all create-image.sh and
create-image.ps1 need: an exact lookup and a canonical spelling to display. `normalize_key` here
must stay in step with `place_key` in create-image.sh and `Get-PlaceKey` in create-image.ps1 -
tests/test_us_places.py asserts all three agree.
"""

import io
import sys
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

SOURCE_URL = "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2023_Gazetteer/2023_Gaz_place_national.zip"
OUT_PATH = Path(__file__).resolve().parent.parent / "data" / "us-places.tsv"

# Census appends the legal/statistical area type to every name ("Watertown town"). Longest first,
# so " metro government" is removed before " government" can strip half of it.
LSAD_SUFFIXES = [
    " municipality and borough",
    " metropolitan government",
    " consolidated government",
    " unified government",
    " city and borough",
    " metro government",
    " metro township",
    " urban county",
    " municipality",
    " corporation",
    " reservation",
    " plantation",
    " comunidad",
    " zona urbana",
    " township",
    " borough",
    " village",
    " purchase",
    " location",
    " county",
    " city",
    " town",
    " grant",
    " gore",
    " CDP",
]

# Abbreviations people type interchangeably with the spelled-out form. Applied to the lookup key
# only, never to the displayed name, so "St. Louis" and "Saint Louis" land on the same record.
KEY_ALIASES = {"saint": "st", "sainte": "ste", "mount": "mt", "fort": "ft"}


def normalize_key(text: str) -> str:
    """Fold a place name to its lookup key: accent-free, punctuation-free, lowercase, single spaces."""
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode("ascii")
    text = text.lower()
    text = "".join(c if c.isalnum() or c.isspace() else " " for c in text)
    words = [KEY_ALIASES.get(w, w) for w in text.split()]
    return " ".join(words)


def canonical_name(raw: str) -> tuple[str, bool]:
    """Strip the Census area-type suffix, leaving the name a person would recognise.

    Also reports whether the suffix marked a merged city-county government, which is the only
    reliable signal that a hyphenated name is two places joined rather than one hyphenated one.
    """
    name = raw.strip()
    consolidated = False
    if name.endswith("(balance)"):
        name = name[: -len("(balance)")].strip()
        consolidated = True
    for suffix in LSAD_SUFFIXES:
        if name.endswith(suffix):
            if "government" in suffix or suffix == " urban county":
                consolidated = True
            name = name[: -len(suffix)].strip()
            break
    return name, consolidated


def common_name(name: str, consolidated: bool) -> str:
    """Reduce a merged city-county name to what people actually call the place.

    "Nashville-Davidson" is the official name; nobody types it. The full form stays indexed as an
    alias, so both spellings resolve - only the displayed value changes.

    The hyphen split is gated on `consolidated` precisely so it cannot reach an ordinary
    hyphenated name: Winston-Salem and Wilkes-Barre are single places and must survive intact.
    """
    if "/" in name:
        return name.split("/", 1)[0].strip()
    if "," in name:
        return name.split(",", 1)[0].strip()
    if "-" in name and (consolidated or name.endswith(" County")):
        return name.split("-", 1)[0].strip()
    return name


def strip_ma_town_artifact(name: str, state: str) -> str:
    """Drop the trailing "Town" the Gazetteer adds to Massachusetts municipalities.

    MA places that are legally towns but classified as cities are listed as "Watertown Town city";
    the extra "Town" is a Census artifact, not part of the name. Restricted to MA deliberately -
    Old Town ME, New Town ND and Charles Town WV are all genuinely named that way, and a blanket
    rule would mangle them into "Old", "New" and "Charles".
    """
    if state == "MA" and name.endswith(" Town") and name != " Town":
        return name[: -len(" Town")].strip() or name
    return name


def build(rows):
    """Map (key, state) -> canonical name, preferring incorporated places over CDPs on a tie."""
    table = {}
    for state, raw_name, funcstat in rows:
        stripped, consolidated = canonical_name(raw_name)
        merged = common_name(stripped, consolidated)
        display = strip_ma_town_artifact(merged, state)
        if not display:
            continue
        # Rank: an active incorporated place beats a statistical one when both claim a name.
        rank = 0 if funcstat == "A" else 1
        # The official forms stay indexed as aliases, so typing either spelling resolves.
        for key_source in {display, merged, stripped}:
            key = normalize_key(key_source)
            if not key:
                continue
            existing = table.get((key, state))
            if existing is None or rank < existing[0]:
                table[(key, state)] = (rank, display)
    return table


def main() -> int:
    if len(sys.argv) > 1:
        text = Path(sys.argv[1]).read_text(encoding="latin-1")
    else:
        print(f"Downloading {SOURCE_URL}")
        with urllib.request.urlopen(SOURCE_URL, timeout=180) as resp:  # noqa: S310 - fixed census.gov URL
            payload = resp.read()
        with zipfile.ZipFile(io.BytesIO(payload)) as zf:
            name = next(n for n in zf.namelist() if n.endswith(".txt"))
            text = zf.read(name).decode("latin-1")

    rows = []
    for line in text.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        rows.append((parts[0].strip(), parts[3].strip(), parts[5].strip()))

    table = build(rows)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", encoding="utf-8", newline="\n") as f:
        f.write("# US place names for offline city/state validation.\n")
        f.write("# Generated by tools/build_us_places.py from the US Census Gazetteer (public domain).\n")
        f.write(f"# Source: {SOURCE_URL}\n")
        f.write("# Format: <lookup key>\\t<state>\\t<canonical name>\n")
        for (key, state), (_rank, display) in sorted(table.items()):
            f.write(f"{key}\t{state}\t{display}\n")

    print(f"Wrote {OUT_PATH} ({len(table)} entries, {OUT_PATH.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
