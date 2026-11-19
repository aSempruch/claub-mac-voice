"""The suite's shared fixtures: one server for the whole session, and an aiohttp session per test."""
from __future__ import annotations

import aiohttp
import pytest

from test_protocol import Server


@pytest.fixture(scope="session")
def server():
    s = Server()
    s.start()
    yield s
    s.stop()


@pytest.fixture
async def http():
    async with aiohttp.ClientSession() as session:
        yield session
