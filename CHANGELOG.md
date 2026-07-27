# Changelog

Release notes for shopperdb-image-creator. Each entry describes, in plain terms, what the release
addresses. Technical detail for individual changes lives in the pull requests.

The `release` job in CI publishes a GitHub Release for the version in the `VERSION` file on each
merge to main - so bump `VERSION` and add a section here in every pull request.

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
