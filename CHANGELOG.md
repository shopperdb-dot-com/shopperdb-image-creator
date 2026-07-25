# Changelog

Release notes for shopperdb-image-creator. Each entry describes, in plain terms, what the release
addresses. Technical detail for individual changes lives in the pull requests.

The `release` job in CI publishes a GitHub Release for the version in the `VERSION` file on each
merge to main - so bump `VERSION` and add a section here in every pull request.

## 1.0.0 - 2026-07-24

- First automated release. Added a GitHub Actions CI pipeline: Python lint (ruff), shell lint
  (shellcheck), and the test suite on every pull request and push, plus tagged GitHub Releases with
  these notes on each merge to main. Added a build-status badge to the README.
