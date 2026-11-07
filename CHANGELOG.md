# Changelog

Release notes for shopperdb-image-creator. Each entry describes, in plain terms, what the release
addresses. Technical detail for individual changes lives in the pull requests.

The `release` job in CI publishes a GitHub Release for the version in the `VERSION` file on each
merge to main - so bump `VERSION` and add a section here in every pull request.

## 1.2.3 - 2026-11-07

- Security: a newly imaged station now refreshes its system CA trust store on first boot, right
  after the network comes up and before the first HTTPS fetch. A Pi OS image can be months old, and
  trust-store changes such as the 2026 eMudhra root distrust only arrive through the
  `ca-certificates` package. The step only upgrades the already-installed package, runs
  non-interactively, needs no reboot or service restart, and finishes before the scanner service
  is installed, so there is nothing running to interrupt. If it fails, first boot warns and carries
  on with the image's trust store.
- Security: cleared the advisories the dependency scan reported in the development tools.
  `virtualenv` 21.3.1 -> 21.15.6 (PYSEC-2026-4014, CVE-2026-113714 and ten related advisories) and
  `filelock` 3.29.0 -> 4.2.9 (CVE-2026-112907 and related), both pulled in by `pre-commit`. Other
  dev tools refreshed: `ruff` 0.17.4, `pytest` 9.2.0, `pre-commit` 4.7.0. The tool itself has no
  runtime Python dependencies, so nothing that ships to a station changed. pip-audit reports no
  known vulnerabilities.
- Tooling: pre-commit hooks updated to ruff v0.17.4 (now the `ruff-check` hook id), shellcheck-py
  v0.11.0.1-1, and pre-commit-hooks v6.0.0. CI moved to `actions/checkout` v7 and
  `astral-sh/setup-uv` v10.3.3, a full version tag because setup-uv no longer publishes floating
  major tags.

## 1.2.2 - 2026-08-21

- Added an MIT license. The project now ships a `LICENSE` file, so anyone can see the terms the
  tool is offered under rather than having to guess.
- The README now shows a latest-release badge and a license badge next to the existing CI badge,
  so the current version and the license are visible at a glance from the repository front page.

## 1.2.1 - 2026-08-16

- First boot no longer tries to fetch packages before the network is up. On a freshly imaged Pi,
  the setup step that installs git could run before the Ethernet DHCP lease had landed, throwing a
  burst of "Temporary failure resolving deb.debian.org" errors on the console before the connection
  came up a few seconds later. The build had been turning off the boot-layer network gate outright;
  it now keeps that gate but caps the wait at 45 seconds, so first boot waits for the link to be
  reachable before that first fetch and a clean boot no longer shows those errors.
- The cap means a missing or slow connection never stalls boot: the login prompt still appears
  immediately (it does not depend on the network), and if the network never comes up, setup simply
  retries on the next boot as it already did. As a fallback, first_boot.sh also waits for working
  DNS before its own first package fetch.

## 1.2.0 - 2026-07-28

- The store's city and state are now checked against a list of every US place while the card is
  being written. Type "watertown" and it becomes "Watertown"; type "NEW BRITAIN" and it becomes
  "New Britain". The city ends up in the store's web address, so a misspelling there would be
  stuck in the subdomain permanently.
- A city that is not on the list is flagged with a few near matches ("Watertwon" suggests
  Watertown, Waterbury, Waterford) and you can correct it or keep what you typed. It is a
  spell-check, not a gate: the list is thorough but not exhaustive, and refusing a real address
  it happens to miss would be worse than letting it through.
- A state that is not a real US state code is now rejected at the prompt rather than accepted
  because it happened to be two letters.
- New `--check-place` / `-CheckPlace` option answers "is this a real city?" without touching a
  card, e.g. `./create-image.sh --check-place --store-city watertown --store-state ct`.
- The place list ships with the repo, so none of this needs a network connection, an API key or
  an account. It comes from the US Census Gazetteer, which is public domain.

## 1.1.0 - 2026-07-26

- The image creator now asks for the store's city and state alongside its name, then shows
  the web address the store will get and waits for you to accept it or type your own.
  Nothing is shortened behind your back: if a name is too long, you are shown a suggestion
  that keeps the city and state and you decide.
- The confirmed address is written to station.conf and used by the server as given, so a
  store's address is what was approved when the card was written.
- New `--print-slug` / `-PrintSlug` option answers "what address would this store get?"
  without touching a card.
- Skipped entirely when store creation is turned off, since no store means no address.
- You are asked to confirm the address once. Later cards for the same store reuse the address
  you already accepted instead of asking again, so a second station cannot land on a different
  subdomain by accident. Changing the store name, city or state brings the question back, as
  does the new `--reconfirm-address` / `-ReconfirmAddress` option.
- Stations now register with https://shopperdb.com by default and the server is no longer asked
  for on every run. `--server-url` / `-ServerUrl` still points a test card at a local development
  server; that override is announced on screen and deliberately not remembered, so it cannot
  linger and ship on the next real card.
- Fixed: on Mac and Linux the script could not read a settings file written on Windows, so saved
  values - including the store address and the stored credentials - silently appeared to be
  missing.
- The setup instructions now read for someone being onboarded: the registration secret and
  GitHub access token are values ShopperDB supplies, not tokens you create yourself.

## 1.0.0 - 2026-07-24

- First automated release. Added a GitHub Actions CI pipeline: Python lint (ruff), shell lint
  (shellcheck), and the test suite on every pull request and push, plus tagged GitHub Releases with
  these notes on each merge to main. Added a build-status badge to the README.
