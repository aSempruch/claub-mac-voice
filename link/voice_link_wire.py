# A copy of Claub's voice_link_wire.py (bot/src/claude_assistant/), the server side of this wire. The two
# must change together: below this note the file is byte-identical to Claub's.

"""The voice link's wire: TCP streams multiplexed over one websocket.

Shared by Claub (``voice_link``, the side that opens streams) and the Mac's relay
(``link/claub_voice_link.py`` in claub-mac-voice, the side that dials the voice server for each), which
ships a copy of this file as ``link/voice_link_wire.py``: the two must change together. Standard library
only, so the relay runs without Claub's dependencies.

Each binary websocket message is one frame: a 1-byte kind, a 4-byte big-endian stream id, the payload.

- ``OPEN`` (Claub to relay, no payload): a new stream; the relay connects it to the voice server.
- ``DATA``: 1 to ``CHUNK`` bytes of the stream.
- ``CLOSE`` (optional UTF-8 reason): the stream is over, both ways: there is no half-close. The receiver
  writes out what it already got, then closes its TCP connection; data still in flight towards the side
  that sent CLOSE is dropped. Frames for a stream that is gone are dropped. That suits websockets, whose
  closing handshake is done before either end closes its socket, not protocols that shut down one
  direction and keep reading.
- ``CREDIT`` (a 4-byte count): the receiver wrote that many bytes out, so the sender may send that many more.

Each side starts a stream with ``WINDOW`` bytes of credit and gives credit back only once its TCP socket
took the bytes, so a stream whose reader stalls holds at most ``WINDOW`` bytes at the other end and stops
only itself. A peer that sends beyond its credit has the stream closed. A dead link is the transport's
business (websocket pings on both sides); ``Mux.close`` then ends every stream.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import struct
from collections.abc import Awaitable, Callable

log = logging.getLogger(__name__)

PROTOCOL = "claub-voice-link.1"  # the websocket subprotocol both sides name
OPEN, DATA, CLOSE, CREDIT = 1, 2, 3, 4
_KINDS = {OPEN: "OPEN", DATA: "DATA", CLOSE: "CLOSE", CREDIT: "CREDIT"}
HEADER = struct.Struct(">BI")
_COUNT = struct.Struct(">I")
WINDOW = 512 * 1024
CHUNK = 32 * 1024

Connect = Callable[[], Awaitable[tuple[asyncio.StreamReader, asyncio.StreamWriter]]]
Send = Callable[[bytes], Awaitable[None]]


class FrameError(ValueError):
    """A frame that breaks the wire format: the link is dropped."""


def encode(kind: int, stream: int, payload: bytes = b"") -> bytes:
    return HEADER.pack(kind, stream) + payload


def decode(frame: bytes) -> tuple[int, int, bytes]:
    """``(kind, stream id, payload)``; ``FrameError`` for a frame the format does not allow."""
    if len(frame) < HEADER.size:
        raise FrameError(f"a frame of {len(frame)} bytes is shorter than its header")
    kind, stream = HEADER.unpack_from(frame)
    payload = bytes(frame[HEADER.size:])
    if kind not in _KINDS:
        raise FrameError(f"unknown frame kind {kind}")
    if kind == OPEN and payload:
        raise FrameError("an OPEN frame carries no payload")
    if kind == DATA and not 0 < len(payload) <= CHUNK:
        raise FrameError(f"a DATA frame carries 1 to {CHUNK} bytes, not {len(payload)}")
    if kind == CREDIT and (len(payload) != _COUNT.size or not 0 < _COUNT.unpack(payload)[0] <= WINDOW):
        raise FrameError("a CREDIT frame carries a count of 1 to WINDOW bytes")
    return kind, stream, payload


def credit(stream: int, count: int) -> bytes:
    return encode(CREDIT, stream, _COUNT.pack(count))


class Stream:
    """One TCP connection carried by the link: *connect* gives its socket (the accepted one, or a new
    connection to the voice server), then bytes are pumped both ways under the credit rules."""

    def __init__(self, mux: Mux, stream_id: int, connect: Connect,
                 writer: asyncio.StreamWriter | None = None) -> None:
        """*writer*: the accepted socket's, known from the start, so it is closed even if the task never runs."""
        self.mux, self.id = mux, stream_id
        self._connect = connect
        self._credit = WINDOW         # bytes we may still send
        self._granted = asyncio.Event()
        self._granted.set()
        self._allowance = WINDOW      # bytes the peer may still send us
        self._inbound: asyncio.Queue[bytes | None] = asyncio.Queue()  # None: the peer closed it
        self._writer: asyncio.StreamWriter | None = writer
        self.task = asyncio.create_task(self._run())

    def abort(self) -> None:
        """End the stream at once (the link is gone, or the peer broke the rules): no CLOSE, the socket closed."""
        self.mux._streams.pop(self.id, None)
        self.task.cancel()
        if self._writer is not None:
            self._writer.close()  # also when the task is cancelled before it ever ran

    # --- From the link ---

    def data(self, payload: bytes) -> None:
        if len(payload) > self._allowance:
            log.warning("Voice link stream %d: the peer sent past its credit; closing it", self.id)
            self.abort()
            self.mux._spawn_send(encode(CLOSE, self.id, b"sent past its credit"))
            return
        self._allowance -= len(payload)
        self._inbound.put_nowait(payload)

    def more_credit(self, count: int) -> None:
        self._credit += count
        self._granted.set()

    def closed_by_peer(self, reason: str) -> None:
        if reason:
            log.info("Voice link stream %d closed by the other side: %s", self.id, reason)
        self._inbound.put_nowait(None)

    # --- The pumps ---

    async def _run(self) -> None:
        tell_peer = True
        reason = b""
        try:
            try:
                reader, self._writer = await self._connect()
            except (OSError, asyncio.TimeoutError) as exc:
                reason = f"cannot connect: {exc or type(exc).__name__}".encode()[:512]
                return
            except Exception as exc:  # the OPEN could not be sent: the link is going
                log.debug("Voice link stream %d did not open: %r", self.id, exc)
                tell_peer = False
                return
            outward = asyncio.create_task(self._outward(reader))
            inward = asyncio.create_task(self._inward(self._writer))
            try:
                done, _ = await asyncio.wait({outward, inward}, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in (outward, inward):
                    task.cancel()
                await asyncio.gather(outward, inward, return_exceptions=True)
            # The peer closed it and everything it sent is written out: nothing to tell it.
            tell_peer = not (inward in done and inward.exception() is None)
        except asyncio.CancelledError:
            tell_peer = False  # the link is gone (or the peer broke the rules and was told)
            raise
        except Exception:  # nothing escapes a stream's task
            log.exception("Voice link stream %d failed", self.id)
        finally:
            self.mux._streams.pop(self.id, None)
            if tell_peer:
                self.mux._spawn_send(encode(CLOSE, self.id, reason))
            if self._writer is not None:
                self._writer.close()
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(self._writer.wait_closed(), 1)

    async def _outward(self, reader: asyncio.StreamReader) -> None:
        """Our socket to the link, while there is credit; returns at its end."""
        while True:
            await self._granted.wait()
            try:
                chunk = await reader.read(min(CHUNK, self._credit))
            except OSError:
                return
            if not chunk:
                return
            self._credit -= len(chunk)
            if self._credit <= 0:
                self._granted.clear()
            await self.mux.send(encode(DATA, self.id, chunk))

    async def _inward(self, writer: asyncio.StreamWriter) -> None:
        """The link to our socket, crediting the peer for what the socket took; returns at the peer's CLOSE."""
        while (chunk := await self._inbound.get()) is not None:
            writer.write(chunk)
            await writer.drain()
            self._allowance += len(chunk)
            await self.mux.send(credit(self.id, len(chunk)))
        with contextlib.suppress(OSError):
            await writer.drain()


class Mux:
    """The streams of one live link. *send* writes one frame to its websocket. With *dial* (the relay) the
    other side's OPEN frames start streams to it; without (Claub) streams start only with ``open``."""

    def __init__(self, send: Send, dial: Connect | None = None) -> None:
        self._send = send
        self._dial = dial
        self._lock = asyncio.Lock()
        self._streams: dict[int, Stream] = {}
        self._next_id = 1
        self._sends: set[asyncio.Task] = set()
        self._closed = False

    def __len__(self) -> int:
        return len(self._streams)

    async def send(self, frame: bytes) -> None:
        async with self._lock:
            await self._send(frame)

    def _spawn_send(self, frame: bytes) -> None:
        """A frame sent without waiting (a stream's CLOSE as it ends); lost with the link."""
        if self._closed:
            return

        async def send() -> None:
            with contextlib.suppress(Exception):
                await self.send(frame)

        task = asyncio.create_task(send())
        self._sends.add(task)
        task.add_done_callback(self._sends.discard)

    def open(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> Stream:
        """Carry an accepted connection over the link (Claub's side): OPEN, then its bytes."""
        stream_id, self._next_id = self._next_id, self._next_id + 1

        async def accepted() -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
            await self.send(encode(OPEN, stream_id))
            return reader, writer

        stream = Stream(self, stream_id, accepted, writer)
        self._streams[stream_id] = stream
        return stream

    def receive(self, frame: bytes) -> None:
        """Act on one frame from the link; ``FrameError`` when it breaks the format (drop the link)."""
        kind, stream_id, payload = decode(frame)
        stream = self._streams.get(stream_id)
        if kind == OPEN:
            if self._dial is None:
                raise FrameError("this side opens the streams")
            if stream is not None:
                raise FrameError(f"stream {stream_id} is already open")
            self._streams[stream_id] = Stream(self, stream_id, self._dial)
        elif stream is None:
            return  # a stream that already ended
        elif kind == DATA:
            stream.data(payload)
        elif kind == CREDIT:
            stream.more_credit(_COUNT.unpack(payload)[0])
        else:
            stream.closed_by_peer(payload.decode("utf-8", "replace"))

    async def close(self) -> None:
        """The link is gone: end every stream (their sockets close) without telling the peer."""
        self._closed = True
        streams = list(self._streams.values())
        tasks = [stream.task for stream in streams] + list(self._sends)
        for stream in streams:
            stream.abort()
        for task in self._sends:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._streams.clear()
