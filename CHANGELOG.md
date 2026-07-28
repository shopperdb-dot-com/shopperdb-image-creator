# Changelog

Release notes for shopperdb-image-creator. Each entry describes, in plain terms, what the release
addresses. Technical detail for individual changes lives in the pull requests.

The `release` job in CI publishes a GitHub Release for the version in the `VERSION` file on each
merge to main - so bump `VERSION` and add a section here in every pull request.

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
