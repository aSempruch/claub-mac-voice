# /// script
# requires-python = ">=3.12"
# dependencies = ["aiohttp>=3.11,<4"]
# ///
"""The Mac's end of Claub's voice link: dial Claub, keep the link up, carry its voice streams.

Claub (on a dev box) cannot reach this Mac; the Mac reaches it through
`ssh -N -L 9420:127.0.0.1:9420 <dev box>`. This relay dials `ws://127.0.0.1:9420/voice-link` through that
forward with the link token, and connects each stream Claub opens over it to the voice server here
(claub-mac-voice, 127.0.0.1:10301). From a checkout of claub-mac-voice:

    uv run link/claub_voice_link.py --token-file ~/.config/claub/voice-link.token

(`./install.sh --link` runs it at login instead.)

It runs until stopped. A link that cannot be made or drops (the tunnel down, Claub restarting, a wrong
token) is retried forever with backoff up to 30 s, and logged once per change, not per attempt. A dead
socket is noticed by websocket pings (every --heartbeat seconds) and at once after the Mac wakes from
sleep (the wall clock jumps ahead of the monotonic one). The wire is voice_link_wire.py beside this file, a
copy of Claub's.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import stat
import sys
import time
from pathlib import Path

import aiohttp

sys.path.insert(0, str(Path(__file__).resolve().parent))  # voice_link_wire.py sits beside this file

from voice_link_wire import PROTOCOL, FrameError, Mux  # noqa: E402

log = logging.getLogger("claub-voice-link")

DEFAULT_URL = "ws://127.0.0.1:9420/voice-link"
DEFAULT_TOKEN = Path.home() / ".config" / "claub" / "voice-link.token"
DEFAULT_VOICE = "127.0.0.1:10301"
BACKOFF = (1.0, 2.0, 5.0, 10.0, 20.0, 30.0)
HEARTBEAT_S = 15.0       # ping every 15 s; no pong within half of it drops the link
WAKE_CHECK_S = 2.0       # how often the sleep detector looks at the clocks
WAKE_JUMP_S = 10.0       # the wall clock ran this much ahead of the monotonic one: the Mac slept
STEADY_S = 30.0         # a link up this long starts the backoff again after it ends
HANDSHAKE_S = 15.0      # a handshake that takes longer (a tunnel that hangs) is given up and retried
# Claub's refusals (voice_link.py), by HTTP status.
REFUSALS = {
    401: "Claub refused the token: copy ~/.claub/data/voice-link.token from the dev box again",
    403: "Claub refused the connection (403): a browser Origin header, or an older Claub with a wrong token",
    400: "Claub speaks another voice link protocol: update claub-mac-voice (git pull && ./install.sh --link)",
    503: "Claub's voice link is not listening (its port is taken, or it is starting): see claubctl status",
    404: "Claub has no /voice-link: voice_link.enabled is off in its claub.yaml, or the URL is wrong",
}


class Relay:
    def __init__(self, url: str, token: str, voice: tuple[str, int], *, backoff=BACKOFF,
                 heartbeat: float = HEARTBEAT_S, wake_check: float = WAKE_CHECK_S, wake_jump: float = WAKE_JUMP_S,
                 handshake: float = HANDSHAKE_S, clocks=(time.time, time.monotonic)) -> None:
        self.url, self.token, self.voice = url, token, voice
        self.backoff, self.heartbeat = backoff, heartbeat
        self.wake_check, self.wake_jump = wake_check, wake_jump
        self.handshake = handshake
        self._wall, self._mono = clocks
        self.connected = asyncio.Event()  # set while a link is up (tests wait on it)
        self.links = 0                    # links made so far
        self.mux: Mux | None = None       # the live link's streams
        self._voice_ok = True             # the last dial of the voice server worked (logged on change)

    async def _dial_voice(self) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        try:
            connection = await asyncio.wait_for(asyncio.open_connection(*self.voice), 5)
        except (OSError, asyncio.TimeoutError) as exc:
            if self._voice_ok:
                log.warning("Cannot reach the voice server on %s:%d: %s (calls fail until it is up)",
                            *self.voice, exc or type(exc).__name__)
                self._voice_ok = False
            raise
        if not self._voice_ok:
            log.info("The voice server on %s:%d answers again", *self.voice)
            self._voice_ok = True
        return connection

    async def run(self) -> None:
        """Keep a link up until cancelled."""
        attempt, last_problem = 0, None
        async with aiohttp.ClientSession() as http:
            while True:
                began = self._mono()
                problem = await self._link_once(http)
                if problem is None:
                    last_problem = None
                    # A link that held starts the backoff again; one dropped at once (another relay
                    # replacing it in turn, say) keeps climbing it, so nothing reconnects in a tight loop.
                    if self._mono() - began >= STEADY_S:
                        attempt = 0
                elif problem != last_problem:
                    log.warning("No link to Claub: %s; retrying (every %g s at most)", problem, self.backoff[-1])
                    last_problem = problem
                delay = self.backoff[min(attempt, len(self.backoff) - 1)]
                attempt += 1
                if await self._pause(delay):
                    attempt = 0  # woke from sleep: try at once, Claub may well be back

    async def _pause(self, delay: float) -> bool:
        """Wait *delay* seconds (monotonic, which stands still while the Mac sleeps); True when the Mac
        slept meanwhile, cutting the wait short."""
        end = self._mono() + delay
        wall, mono = self._wall(), self._mono()
        while (left := end - self._mono()) > 0:
            await asyncio.sleep(min(left, self.wake_check))
            if self._slept(wall, mono):
                return True
            wall, mono = self._wall(), self._mono()
        return False

    def _slept(self, wall: float, mono: float) -> bool:
        return (self._wall() - wall) - (self._mono() - mono) > self.wake_jump

    async def _link_once(self, http: aiohttp.ClientSession) -> str | None:
        """One link: None once it was up and ended, else why it could not be made."""
        try:
            ws = await asyncio.wait_for(http.ws_connect(
                self.url, protocols=(PROTOCOL,), heartbeat=self.heartbeat, autoping=True,
                headers={"Authorization": f"Bearer {self.token}"}, max_msg_size=0,
                timeout=aiohttp.ClientWSTimeout(ws_receive=None, ws_close=5),
            ), self.handshake)
        except aiohttp.WSServerHandshakeError as exc:
            return REFUSALS.get(exc.status, f"the handshake failed (HTTP {exc.status})")
        except asyncio.TimeoutError:
            return f"no answer from {self.url} within {self.handshake:g} s (is the ssh -L tunnel up?)"
        except (aiohttp.ClientError, OSError) as exc:
            return f"cannot connect to {self.url}: {exc or type(exc).__name__} (is the ssh -L tunnel up?)"
        if ws.protocol != PROTOCOL:
            await ws.close()
            return f"Claub answered without {PROTOCOL}: update claub-mac-voice (git pull && ./install.sh --link)"
        self.links += 1
        log.info("Link up: %s -> voice server %s:%d", self.url, *self.voice)
        self.connected.set()
        mux = self.mux = Mux(ws.send_bytes, dial=self._dial_voice)
        watchdog = asyncio.create_task(self._watch_for_sleep(ws))
        reason = "Claub closed it"
        try:
            async for message in ws:
                if message.type == aiohttp.WSMsgType.BINARY:
                    try:
                        mux.receive(message.data)
                    except FrameError as exc:
                        reason = f"Claub broke the wire format: {exc}"
                        break
                elif message.type == aiohttp.WSMsgType.ERROR:
                    reason = f"error: {ws.exception()}"
                    break
            else:
                if ws.close_code == 4000:
                    reason = "another relay replaced it"
                elif watchdog.done():
                    reason = "the Mac slept"
                elif ws.close_code not in (None, 1000):
                    reason = f"closed ({ws.close_code})" if ws.close_code != 1006 else "the connection dropped"
        finally:
            self.connected.clear()
            watchdog.cancel()
            await mux.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(ws.close(), 2)
        log.info("Link down: %s", reason)
        return None

    async def _watch_for_sleep(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        """Close the link when the Mac wakes up: its socket is dead and the pings would take a while to say so."""
        wall, mono = self._wall(), self._mono()
        while True:
            await asyncio.sleep(self.wake_check)
            if self._slept(wall, mono):
                log.info("The Mac slept: reconnecting")
                await ws.close()
                return
            wall, mono = self._wall(), self._mono()


def read_token(path: Path) -> str:
    token = path.expanduser().read_text().strip()
    if not token:
        raise SystemExit(f"{path}: empty token file")
    mode = path.expanduser().stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        log.warning("%s is readable by others: chmod 600 it", path)
    return token


def parse_voice(text: str) -> tuple[str, int]:
    host, _, port = text.rpartition(":")
    if not host or not port.isdigit():
        raise argparse.ArgumentTypeError(f"expected host:port, not {text!r}")
    return host, int(port)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--url", default=os.environ.get("CLAUB_VOICE_LINK_URL", DEFAULT_URL),
                        help=f"Claub's voice link endpoint (default {DEFAULT_URL})")
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN,
                        help=f"the token Claub made in ~/.claub/data/voice-link.token (default {DEFAULT_TOKEN})")
    parser.add_argument("--voice", type=parse_voice, default=parse_voice(DEFAULT_VOICE),
                        help=f"the voice server here, host:port (default {DEFAULT_VOICE})")
    parser.add_argument("--heartbeat", type=float, default=HEARTBEAT_S, help="seconds between pings")
    parser.add_argument("-v", "--verbose", action="store_true", help="log each stream too")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    # The streams carry a call's audio and transcripts: the relay logs the link's state and the streams'
    # ids, never what they carry, and aiohttp's debug logging stays off even with --verbose.
    logging.getLogger("aiohttp").setLevel(logging.WARNING)
    relay = Relay(args.url, read_token(args.token_file), args.voice, heartbeat=args.heartbeat)
    log.info("Dialing %s; voice server %s:%d", args.url, *args.voice)
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(relay.run())


if __name__ == "__main__":
    main()
