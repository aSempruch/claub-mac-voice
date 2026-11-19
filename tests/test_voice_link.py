"""The voice link relay (link/claub_voice_link.py) against the real server.

A fake Claub serves /voice-link as Claub does (Bearer token, the claub-voice-link.1 subprotocol, the wire's
Mux) and listens for voice clients; each client connection there is carried over the link the relay
made, and the relay connects it to this server.
"""
from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import logging
import subprocess
from pathlib import Path
from types import SimpleNamespace

import aiohttp
import pytest
from aiohttp import web

from test_protocol import EXPECTED_WORDS, UTTERANCE, free_port, say_wav, stt, tts, words

ROOT = Path(__file__).resolve().parent.parent
RELAY = ROOT / "link" / "claub_voice_link.py"
TOKEN = "a" * 64


def load_relay():
    spec = importlib.util.spec_from_file_location("claub_voice_link", RELAY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


relay_module = load_relay()
import voice_link_wire as wire  # noqa: E402  (on sys.path once the relay is loaded, as the relay imports it)


class FakeClaub:
    """Claub's side of the link: ``/voice-link`` on an aiohttp server, and a listener for voice clients."""

    def __init__(self) -> None:
        self.attempts = 0
        self.mux: wire.Mux | None = None
        self.linked = asyncio.Event()

    async def start(self) -> None:
        app = web.Application()
        app.router.add_get("/voice-link", self.serve)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        port = free_port()
        await web.TCPSite(self.runner, "127.0.0.1", port).start()
        self.url = f"ws://127.0.0.1:{port}/voice-link"
        self.listener = await asyncio.start_server(self.accept, "127.0.0.1", 0)
        self.voice_url = f"ws://127.0.0.1:{self.listener.sockets[0].getsockname()[1]}"

    async def stop(self) -> None:
        self.listener.close()
        await self.runner.cleanup()

    async def serve(self, request: web.Request) -> web.StreamResponse:
        self.attempts += 1
        if request.headers.get("Authorization") != f"Bearer {TOKEN}":
            raise web.HTTPUnauthorized()
        ws = web.WebSocketResponse(protocols=(wire.PROTOCOL,))
        if not ws.can_prepare(request).ok or ws.can_prepare(request).protocol != wire.PROTOCOL:
            raise web.HTTPBadRequest()
        await ws.prepare(request)
        mux = self.mux = wire.Mux(ws.send_bytes)
        self.linked.set()
        try:
            async for message in ws:
                if message.type == aiohttp.WSMsgType.BINARY:
                    mux.receive(message.data)
        finally:
            self.linked.clear()
            await mux.close()
        return ws

    async def accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self.mux is None or not self.linked.is_set():
            writer.close()
            return
        self.mux.open(reader, writer)


@contextlib.asynccontextmanager
async def running(relay):
    task = asyncio.create_task(relay.run())
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


def voice_target(server) -> tuple[str, int]:
    host, port = server.url.removeprefix("ws://").rsplit(":", 1)
    return host, int(port)


async def test_speech_goes_through_the_link(http, server):
    claub = FakeClaub()
    await claub.start()
    relay = relay_module.Relay(claub.url, TOKEN, voice_target(server))
    try:
        async with running(relay):
            await asyncio.wait_for(claub.linked.wait(), 10)
            through = SimpleNamespace(url=claub.voice_url)  # what Claub's voice clients dial
            sentences, _, close_code = await tts(http, through, ["Hello over the link.", "And a second one."])
            assert [s["text"] for s, _ in sentences] == ["Hello over the link.", "And a second one."]
            assert all(len(pcm) > 9600 for _, pcm in sentences) and close_code == 1000
            _, final, _ = await stt(http, through, say_wav(UTTERANCE, 16000), rate=16000, channels=1,
                                    realtime=False)
            for word in EXPECTED_WORDS:
                assert word in words(final), (word, final)
            assert relay.links == 1
    finally:
        await claub.stop()


async def test_a_wrong_token_is_logged_once_and_retried(caplog):
    claub = FakeClaub()
    await claub.start()
    relay = relay_module.Relay(claub.url, "b" * 64, ("127.0.0.1", free_port()), backoff=(0.05,))
    caplog.set_level(logging.INFO, logger="claub-voice-link")
    try:
        async with running(relay):
            for _ in range(200):
                if claub.attempts >= 3:
                    break
                await asyncio.sleep(0.05)
        assert claub.attempts >= 3 and relay.links == 0
        refusals = [r for r in caplog.records if relay_module.REFUSALS[401] in r.getMessage()]
        assert len(refusals) == 1
    finally:
        await claub.stop()


# --- install.sh --link / --tunnel: what it refuses before touching anything ---


@pytest.mark.parametrize("args", [["--tunnel"], ["--tunnel", "-oProxyCommand=x"], ["--tunnel", "a b"],
                                  ["--token-file", "x"], ["--link", "10301"], ["--link", "--token-file"]])
def test_install_rejects_bad_link_arguments(args):
    result = subprocess.run([str(ROOT / "install.sh"), *args], capture_output=True, text=True)
    assert result.returncode == 2 and "usage" in result.stderr


def test_install_link_needs_a_private_token_file(tmp_path):
    token = tmp_path / "voice-link.token"
    result = subprocess.run([str(ROOT / "install.sh"), "--link", "--token-file", str(token)],
                            capture_output=True, text=True)
    assert result.returncode == 1 and "no token file" in result.stderr
    token.write_text(TOKEN)
    token.chmod(0o644)
    result = subprocess.run([str(ROOT / "install.sh"), "--link", "--token-file", str(token)],
                            capture_output=True, text=True)
    assert result.returncode == 1 and "chmod 600" in result.stderr
