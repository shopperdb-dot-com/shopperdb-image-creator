"""Shared fixtures for shopperdb-image-creator tests."""

import sys

import pytest


# Bash tests require a real bash environment - skip automatically on Windows.
def pytest_collection_modifyitems(items):
    if sys.platform != "win32":
        return
    skip = pytest.mark.skip(reason="bash tests require Linux or macOS")
    for item in items:
        if item.get_closest_marker("bash"):
            item.add_marker(skip)
