"""Protocol tests for claub-mac-voice, as Claub's client (aiohttp) speaks it.

Run from the repository root after `swift build -c release`:

    uv run --project tests pytest tests -q -s

The suite starts the release binary on a free port and stops it afterwards.
Set CLAUB_MAC_VOICE_URL (e.g. ws://127.0.0.1:10301) to test a running server
instead; then the log checks are skipped.
"""
from __future__ import annotations

import array
import asyncio
import json
import os
import re
import socket
import subprocess
import tempfile
import time
import wave
from pathlib import Path

import aiohttp
import pytest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build" / "release" / "claub-mac-voice"
UTTERANCE = "Please turn on the kitchen lights and set the thermostat to seventy two degrees."
EXPECTED_WORDS = ["turn", "kitchen", "lights", "thermostat", "72", "degrees"]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, *args: str, own: bool = False, tmpdir: str | None = None) -> None:
        self.args = args
        self.tmpdir = tmpdir  # the server's TMPDIR, where say renders
        self.url = "" if own else os.environ.get("CLAUB_MAC_VOICE_URL", "").rstrip("/")
        self.process: subprocess.Popen | None = None
        self.log_path = Path(tempfile.mkstemp(prefix="claub-mac-voice-", suffix=".log")[1])

    def start(self) -> None:
        if self.url:
            return
        if not BINARY.exists():
            pytest.exit(f"build first: (cd {ROOT} && swift build -c release)")
        port = free_port()
        self.url = f"ws://127.0.0.1:{port}"
        env = {**os.environ, "TMPDIR": self.tmpdir} if self.tmpdir else None
        self.process = subprocess.Popen([str(BINARY), "--port", str(port), *self.args], stdout=subprocess.DEVNULL,
                                        stderr=self.log_path.open("w"), env=env)
        deadline = time.time() + 120
        while time.time() < deadline:  # ready once the speech model is installed and warm
            if "system voice warmed up" in self.log() and ("model warmed up" in self.log() or "stt: unavailable" in self.log()):
                return
            if self.process.poll() is not None:
                pytest.exit(f"server exited: {self.log()}")
            time.sleep(0.1)
        pytest.exit("server did not become ready")

    def stop(self) -> None:
        if self.process is not None:
            self.process.terminate()
            self.process.wait(10)
        self.log_path.unlink(missing_ok=True)

    def log(self) -> str:
        return self.log_path.read_text()

    def wait_log(self, pattern: str, timeout: float = 5) -> str:
        if self.process is None:
            pytest.skip("log checks need the suite's own server")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if m := re.search(pattern, self.log()):
                return m.group(0)
            time.sleep(0.05)
        raise AssertionError(f"no log line matching {pattern!r} in:\n{self.log()}")

    def say_children(self) -> int:
        assert self.process is not None
        out = subprocess.run(["pgrep", "-P", str(self.process.pid), "say"], capture_output=True, text=True).stdout
        return len(out.split())


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


async def tts(http, server, texts, *, voice=None, stop_after_audio=None):
    """Speak ``texts``; returns [(sentence message, pcm bytes)], first-audio seconds, and the closing frame."""
    query = f"?voice={voice}" if voice else ""
    sentences: list[tuple[dict, bytearray]] = []
    first_audio = None
    started = time.perf_counter()
    async with http.ws_connect(f"{server.url}/v1/tts/stream{query}") as ws:
        for text in texts:
            await ws.send_str(json.dumps({"type": "text", "text": text}))
        await ws.send_str(json.dumps({"type": "end"}))
        done = False
        async for message in ws:
            if message.type == aiohttp.WSMsgType.BINARY:
                assert sentences, "audio before a sentence"
                if first_audio is None:
                    first_audio = time.perf_counter() - started
                sentences[-1][1].extend(message.data)
                if stop_after_audio is not None and len(sentences[-1][1]) >= stop_after_audio:
                    await ws.close()
                    return sentences, first_audio, None
            else:
                data = json.loads(message.data)
                if data["type"] == "sentence":
                    sentences.append((data, bytearray()))
                elif data["type"] == "done":
                    done = True
                else:
                    raise AssertionError(data)
        assert done, "socket closed without done"
        return sentences, first_audio, ws.close_code


def rms(pcm: bytes) -> float:
    samples = array.array("h", pcm)
    return (sum(s * s for s in samples) / max(len(samples), 1)) ** 0.5


async def test_health(http, server):
    async with http.get(server.url.replace("ws://", "http://") + "/health") as response:
        body = await response.json()
    assert body["ok"] is True
    assert body["stt"]["state"] == "ready"
    assert body["tts"]["engine"] == "say"


async def test_tts_two_sentences_are_labelled_24k_mono_pcm(http, server):
    sentences, first_audio, close_code = await tts(http, server, ["Hello there.", "This is the second sentence."])
    assert [s["text"] for s, _ in sentences] == ["Hello there.", "This is the second sentence."]
    for header, pcm in sentences:
        assert (header["rate"], header["width"], header["channels"]) == (24000, 2, 1)
        assert len(pcm) % 2 == 0
        seconds = len(pcm) / 48000
        assert 0.4 < seconds < 6, seconds
        assert rms(pcm) > 300, "silent audio"
    assert close_code == 1000
    print(f"\nTTS first audio {first_audio:.3f}s")


async def test_tts_one_message_with_two_sentences_is_split(http, server):
    sentences, _, _ = await tts(http, server, ["First one here. And a second one!"])
    assert [s["text"] for s, _ in sentences] == ["First one here.", "And a second one!"]


async def test_tts_first_audio_latency(http, server):
    """First audio of a fresh reply, measured a few times (the spare say process is warm)."""
    times = []
    for _ in range(5):
        _, first_audio, _ = await tts(http, server, ["Sure, I can help with that."])
        times.append(first_audio)
        await asyncio.sleep(0.8)  # let the next spare start, as between real replies
    print(f"\nTTS first audio over {len(times)} replies: " + ", ".join(f"{t:.3f}" for t in times))
    assert min(times) < 1.5


async def test_tts_close_mid_render_stops_synthesis(http, server):
    texts = [f"This is sentence number {n} of a long reply that keeps going." for n in range(1, 11)]
    sentences, _, _ = await tts(http, server, texts, stop_after_audio=9600)
    assert len(sentences) == 1
    line = server.wait_log(r"tts #\d+ client left after \d+ sentence")
    assert int(re.search(r"after (\d+)", line).group(1)) <= 1
    await asyncio.sleep(1.0)  # the spare may be restarting
    assert server.say_children() <= 2, "say kept rendering after the client left"


async def test_tts_unknown_voice_falls_back_to_default(http, server):
    sentences, _, close_code = await tts(http, server, ["Falling back."], voice="NoSuchVoice")
    assert len(sentences) == 1 and rms(sentences[0][1]) > 300
    assert close_code == 1000
    server.wait_log(r"voice system default \(no voice NoSuchVoice\)")


async def test_tts_named_voice_by_short_name(http, server):
    voices = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    if "Samantha" not in voices:
        pytest.skip("no Samantha voice")
    sentences, _, _ = await tts(http, server, ["Named voice."], voice="samantha")
    assert len(sentences) == 1 and sentences[0][1]
    server.wait_log(r"voice Samantha,")


async def test_tts_empty_reply_is_done_without_audio(http, server):
    sentences, _, close_code = await tts(http, server, [])
    assert sentences == [] and close_code == 1000


@pytest.mark.parametrize("message, error", [
    ("not json", "JSON"), (json.dumps({"type": "nope"}), "unknown message type 'nope'"),
])
async def test_tts_bad_messages_get_an_error(http, server, message, error):
    async with http.ws_connect(f"{server.url}/v1/tts/stream") as ws:
        await ws.send_str(message)
        reply = await ws.receive_json(timeout=5)
        assert reply["type"] == "error" and error in reply["message"]
        assert (await ws.receive(timeout=5)).type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED)
        assert ws.close_code == 1008


def say_wav(text: str, rate: int) -> bytes:
    """16-bit mono PCM of ``text`` spoken by say."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "utterance.wav"
        subprocess.run(["say", "-o", str(path), f"--data-format=LEI16@{rate}", text], check=True)
        with wave.open(str(path)) as w:
            assert (w.getframerate(), w.getsampwidth(), w.getnchannels()) == (rate, 2, 1)
            return w.readframes(w.getnframes())


def stereo(mono: bytes) -> bytes:
    samples = array.array("h", mono)
    out = array.array("h", bytes(len(mono) * 2))
    out[0::2] = samples
    out[1::2] = samples
    return out.tobytes()


async def stt(http, server, pcm: bytes, *, rate: int, channels: int, realtime: bool = True):
    """Stream ``pcm`` in 20 ms frames as a call does; returns partials, final, and seconds from stop to final."""
    frame = rate * channels * 2 // 50
    partials: list[str] = []
    async with http.ws_connect(f"{server.url}/v1/stt/stream?sample_rate={rate}&channels={channels}") as ws:
        async def read():
            async for message in ws:
                data = json.loads(message.data)
                if data["type"] == "partial":
                    partials.append(data["text"])
                elif data["type"] == "final":
                    return data["text"], time.perf_counter()
                else:
                    raise AssertionError(data)
            raise AssertionError("closed without final")

        reader = asyncio.create_task(read())
        start = time.perf_counter()
        for n, offset in enumerate(range(0, len(pcm), frame)):
            await ws.send_bytes(pcm[offset:offset + frame])
            if realtime:
                await asyncio.sleep(max(0.0, start + (n + 1) * 0.02 - time.perf_counter()))
        # Claub sends stop 1.7 s after the last loud frame; that pause is audio too.
        silence = bytes(frame)
        for n in range(10 if realtime else 0):
            await ws.send_bytes(silence)
            await asyncio.sleep(0.02)
        stopped = time.perf_counter()
        await ws.send_str(json.dumps({"type": "stop"}))
        final, at = await asyncio.wait_for(reader, 10)
        await ws.receive(timeout=5)
        assert ws.closed or ws.close_code is not None
        return partials, final, at - stopped


def words(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower())


async def test_stt_say_utterance_48k_stereo_partials_then_final(http, server):
    pcm = stereo(say_wav(UTTERANCE, 48000))
    partials, final, latency = await stt(http, server, pcm, rate=48000, channels=2)
    print(f"\nSTT final {latency:.3f}s after stop; {len(partials)} partials; final {final!r}")
    for word in EXPECTED_WORDS:
        assert word in words(final), (word, final)
    assert len(partials) >= 3, partials
    assert partials[0] != partials[-1]
    assert partials == [p for i, p in enumerate(partials) if i == 0 or p != partials[i - 1]], "repeated partial"
    assert latency < 0.6


async def test_stt_16k_mono_faster_than_realtime(http, server):
    pcm = say_wav("What is the weather like tomorrow in Paris?", 16000)
    partials, final, latency = await stt(http, server, pcm, rate=16000, channels=1, realtime=False)
    assert "weather" in words(final) and "paris" in words(final), final
    print(f"\nSTT (sent at once) final {latency:.3f}s after stop: {final!r}")


async def test_stt_second_utterance_on_a_new_socket(http, server):
    pcm = say_wav("Hello computer.", 24000)
    _, final, _ = await stt(http, server, pcm, rate=24000, channels=1, realtime=False)
    assert "hello" in words(final)


@pytest.mark.parametrize("query", ["sample_rate=4000&channels=1", "sample_rate=16000&channels=3"])
async def test_stt_bad_format_gets_an_error(http, server, query):
    async with http.ws_connect(f"{server.url}/v1/stt/stream?{query}") as ws:
        reply = await ws.receive_json(timeout=5)
        assert reply["type"] == "error" and "sample_rate" in reply["message"]
        await ws.receive(timeout=5)
        assert ws.close_code == 1008


async def test_stt_odd_byte_frame_is_rejected(http, server):
    async with http.ws_connect(f"{server.url}/v1/stt/stream?sample_rate=16000&channels=1") as ws:
        await ws.send_bytes(b"\x00\x01\x02")
        reply = await ws.receive_json(timeout=5)
        assert reply == {"type": "error", "message": "PCM frames must hold whole 16-bit samples"}


async def test_stt_disconnect_without_stop(http, server):
    async with http.ws_connect(f"{server.url}/v1/stt/stream?sample_rate=16000&channels=1") as ws:
        await ws.send_bytes(say_wav("Never mind.", 16000))
    server.wait_log(r"stt #\d+ client left before stop")


async def test_unknown_path_gets_an_error(http, server):
    async with http.ws_connect(f"{server.url}/v1/nope") as ws:
        reply = await ws.receive_json(timeout=5)
        assert reply["type"] == "error" and "/v1/stt/stream" in reply["message"]


async def test_stt_stop_without_audio_is_an_empty_final(http, server):
    async with http.ws_connect(f"{server.url}/v1/stt/stream?sample_rate=48000&channels=2") as ws:
        await ws.send_str(json.dumps({"type": "stop"}))
        assert await ws.receive_json(timeout=5) == {"type": "final", "text": ""}


# --- Review fixes: sockets, queries, splitting, failures, keepalive, framing, limits --------------------

def open_fds(pid: int) -> int:
    return len(subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines())


async def test_bare_connects_do_not_leak_sockets(http, server):
    if server.process is None:
        pytest.skip("needs the suite's own server")
    port = int(server.url.rsplit(":", 1)[1])
    await asyncio.sleep(1)
    before = open_fds(server.process.pid)
    for _ in range(300):  # as nc -z does
        _, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.close()
        await writer.wait_closed()
    for _ in range(10):  # half a request, then gone
        _, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"GET /health HTTP/1.1\r\n")
        await writer.drain()
        writer.close()
    await asyncio.sleep(1)
    after = open_fds(server.process.pid)
    assert after - before <= 4, (before, after)
    await test_health(http, server)
    sentences, _, _ = await tts(http, server, ["Still here."])
    assert len(sentences) == 1


async def test_a_silent_connection_is_dropped_after_the_request_deadline(server):
    if server.process is None:
        pytest.skip("needs the suite's own server")
    port = int(server.url.rsplit(":", 1)[1])
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    started = time.time()
    assert await asyncio.wait_for(reader.read(), 15) == b""
    assert 9 < time.time() - started < 13
    writer.close()


async def test_plus_in_the_query_is_a_space(http, server):
    from urllib.parse import urlencode
    voices = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    name = "Reed (English (US))"
    if name not in voices:
        pytest.skip("no Reed voice")
    query = urlencode({"voice": name})  # as Claub's synthesize_stream builds it
    assert "+" in query
    async with http.ws_connect(f"{server.url}/v1/tts/stream?{query}") as ws:
        await ws.send_str(json.dumps({"type": "text", "text": "Plus signs."}))
        await ws.send_str(json.dumps({"type": "end"}))
        async for message in ws:
            if message.type == aiohttp.WSMsgType.TEXT and json.loads(message.data)["type"] == "done":
                break
    server.wait_log(re.escape(f"voice {name},"))


async def test_stt_stop_after_a_frame_too_short_to_resample(http, server):
    async with http.ws_connect(f"{server.url}/v1/stt/stream?sample_rate=48000&channels=2") as ws:
        await ws.send_bytes(b"\x01\x00\x01\x00")  # one stereo sample: nothing at 16 kHz
        started = time.time()
        await ws.send_str(json.dumps({"type": "stop"}))
        assert await ws.receive_json(timeout=5) == {"type": "final", "text": ""}
        assert time.time() - started < 1


# The reference server's own sentence-splitting cases.
@pytest.mark.parametrize("text, expected", [
    ("It is 7 a.m. now. Anything else?", ["It is 7 a.m. now.", "Anything else?"]),
    ("Set for 7 a.m. tomorrow. Anything else?", ["Set for 7 a.m. tomorrow.", "Anything else?"]),
    ("no terminator at all", ["no terminator at all"]),
    ("   ", []),
    ("Not quite — your left pointer never moves.", ["Not quite —", "your left pointer never moves."]),
    ("Not quite—your pointer.", ["Not quite—", "your pointer."]),
    ("Close – but no.", ["Close –", "but no."]),
    ("Close - but no.", ["Close -", "but no."]),
    ("Two things: this works; that doesn't.", ["Two things:", "this works;", "that doesn't."]),
    ("Yeah, pages 10–20 at 7:30 are well-known.", ["Yeah, pages 10–20 at 7:30 are well-known."]),
    ("— and then it stops.", ["and then it stops."]),
])
async def test_sentences_split_as_the_reference_server_splits_them(http, server, text, expected):
    sentences, _, _ = await tts(http, server, [text])
    assert [s["text"] for s, _ in sentences] == expected


async def test_dead_spare_say_is_replaced(http, server):
    if server.process is None:
        pytest.skip("needs the suite's own server")
    await asyncio.sleep(0.5)
    subprocess.run(["pkill", "-P", str(server.process.pid), "say"])  # the spares die, as with `killall say`
    sentences, _, close_code = await tts(http, server, ["After the spares died.", "And one more."])
    assert [s["text"] for s, _ in sentences] == ["After the spares died.", "And one more."]
    assert all(rms(pcm) > 300 for _, pcm in sentences)
    assert close_code == 1000


async def test_sentence_rate_comes_from_the_rendered_file(http):
    s = Server("--tts-rate", "16000", own=True)
    s.start()
    try:
        async with aiohttp.ClientSession() as session:
            sentences, _, _ = await tts(session, s, ["Sixteen kilohertz."])
        assert sentences[0][0]["rate"] == 16000
    finally:
        s.stop()


async def test_no_speech_in_the_log_and_no_audio_kept():
    """The log holds counts and timings, never what was said or spoken, and no rendered audio outlives its
    sentence: not after a reply, a hang-up mid-sentence, or the server stopping. A dead server's leftovers go
    at the next start."""
    with tempfile.TemporaryDirectory() as tmp:
        say_dir = Path(tmp) / "claub-mac-voice-say"
        stale = say_dir / "999999" / "0BADF00D"  # a server that died mid-sentence (no such pid)
        stale.mkdir(parents=True)
        (stale / "speech.caf").write_bytes(b"caff" + bytes(100))
        old = Path(tmp) / "claub-mac-voice-6F9619FF-8B86-D011-B42D-00C04FC964FF"  # the layout before
        old.mkdir()
        (old / "speech.caf").write_bytes(b"caff")
        s = Server(own=True, tmpdir=tmp)
        s.start()
        try:
            root = say_dir / str(s.process.pid)
            assert root.is_dir()
            assert not stale.parent.exists() and not old.exists()
            spoken = ["Periwinkle marmosets are quite rare.", "Another quokka sentence follows."]
            async with aiohttp.ClientSession() as http:
                sentences, _, _ = await tts(http, s, spoken)
                assert [m["text"] for m, _ in sentences] == spoken
                long = [f"The periwinkle marmoset number {n} keeps talking for a while." for n in range(5)]
                await tts(http, s, long, stop_after_audio=9600)  # hang up mid-sentence
                s.wait_log(r"tts #\d+ client left after")
                _, final, _ = await stt(http, s, say_wav("The pelican ate seventeen tangerines.", 16000),
                                        rate=16000, channels=1, realtime=False)
            heard = [w for w in ("pelican", "tangerines") if w in words(final)]
            assert heard, final
            s.wait_log(r"stt #\d+ [\d.]+s audio -> \d+ chars")
            log = s.log().lower()
            for marker in ["periwinkle", "marmoset", "quokka", *heard]:
                assert marker not in log, (marker, log)
            await asyncio.sleep(1.0)  # the hung-up sentence's say is stopped and its file removed
            # What is left is the spare say waiting for its next sentence: its file is CAF's header (say puts
            # the audio at 4096), with no audio yet.
            left = [p for p in say_dir.rglob("*") if p.is_file()]
            assert len(left) <= 1 and all(p.stat().st_size <= 4096 for p in left), [
                (p, p.stat().st_size) for p in left]
        finally:
            s.stop()
        assert not root.exists(), "the server's say directory outlived it"


# --- Raw frames -------------------------------------------------------------------------------------

def frame(opcode: int, payload: bytes = b"", *, fin: bool = True, masked: bool = True, length: int | None = None) -> bytes:
    n = len(payload) if length is None else length
    head = bytes([(0x80 if fin else 0) | opcode])
    mask_bit = 0x80 if masked else 0
    if n < 126:
        head += bytes([mask_bit | n])
    else:
        head += bytes([mask_bit | 126]) + n.to_bytes(2, "big")
    if not masked:
        return head + payload
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


class Raw:
    """A WebSocket client that sends exactly the frames it is told to and never answers pings."""

    async def open(self, url: str, path: str) -> "Raw":
        host, port = url.removeprefix("ws://").split(":")
        self.reader, self.writer = await asyncio.open_connection(host, int(port))
        self.writer.write((f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = await self.reader.readuntil(b"\r\n\r\n")
        assert head.startswith(b"HTTP/1.1 101"), head
        return self

    def send(self, data: bytes) -> None:
        self.writer.write(data)

    async def read_frame(self, timeout: float = 5) -> tuple[int, bytes] | None:
        try:
            head = await asyncio.wait_for(self.reader.readexactly(2), timeout)
        except asyncio.IncompleteReadError:
            return None
        n = head[1] & 0x7F
        if n == 126:
            n = int.from_bytes(await self.reader.readexactly(2), "big")
        elif n == 127:
            n = int.from_bytes(await self.reader.readexactly(8), "big")
        return head[0] & 0x0F, await self.reader.readexactly(n)

    async def close_code(self, timeout: float = 5) -> int | None:
        while (got := await self.read_frame(timeout)) is not None:
            opcode, payload = got
            if opcode == 0x8:
                return int.from_bytes(payload[:2], "big")
        return None


@pytest.mark.parametrize("data, code", [
    (frame(0x1, b'{"type": "end"}', masked=False), 1002),          # unmasked
    (frame(0x9, b"x" * 126), 1002),                                # control frame over 125 bytes
    (frame(0x9, b"hi", fin=False), 1002),                          # fragmented control frame
    (frame(0x8, (999).to_bytes(2, "big")), 1002),                  # invalid close code
    (frame(0x8, (1005).to_bytes(2, "big")), 1002),                 # reserved close code
    (frame(0x8, b"\x03"), 1002),                                   # one-byte close payload
    (frame(0x8, (1000).to_bytes(2, "big") + b"\xff"), 1007),       # close reason not UTF-8
    (frame(0x1, b"\xff\xfe"), 1007),                               # text not UTF-8
    (frame(0x0, b"orphan"), 1002),                                 # continuation with no start
    (frame(0x1, b"part", fin=False) + frame(0x1, b"new"), 1002),   # new message mid-fragment
])
async def test_protocol_violations_close_the_socket(server, data, code):
    raw = await Raw().open(server.url, "/v1/tts/stream")
    raw.send(data)
    assert await raw.close_code() == code


async def test_fragmented_text_is_reassembled(server):
    raw = await Raw().open(server.url, "/v1/tts/stream")
    raw.send(frame(0x1, b'{"type": ', fin=False) + frame(0x0, b'"end"}'))
    assert await raw.read_frame() == (0x1, b'{"type":"done"}')
    assert await raw.close_code() == 1000


async def test_no_pong_after_the_server_closed(server):
    raw = await Raw().open(server.url, "/v1/tts/stream")
    raw.send(frame(0x1, b'{"type": "end"}'))
    assert await raw.read_frame() == (0x1, b'{"type":"done"}')
    opcode, _ = await raw.read_frame()
    assert opcode == 0x8
    raw.send(frame(0x9, b"late"))
    rest = []
    while (got := await raw.read_frame(3)) is not None:
        rest.append(got[0])
    assert 0xA not in rest


# --- Keepalive and limits (their own servers) ---------------------------------------------------------

async def test_a_peer_that_never_pongs_is_dropped_and_its_reply_cancelled():
    s = Server("--ping-interval", "1", own=True)
    s.start()
    try:
        raw = await Raw().open(s.url, "/v1/tts/stream")
        long_reply = " ".join(f"Sentence {n} of a reply nobody hears any more." for n in range(30))
        raw.send(frame(0x1, json.dumps({"type": "text", "text": long_reply}).encode()))
        started = time.time()
        s.wait_log(r"ws #\d+ no pong within 1 s", timeout=6)
        assert time.time() - started < 4
        s.wait_log(r"tts #\d+ client left after \d+ sentence")
        # aiohttp answers pings while something reads the socket, as Claub's SttStream always does.
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(f"{s.url}/v1/stt/stream?sample_rate=16000&channels=1") as ws:
                async def final():
                    async for message in ws:
                        if (data := json.loads(message.data))["type"] == "final":
                            return data["text"]
                reader = asyncio.create_task(final())
                await asyncio.sleep(3.5)
                await ws.send_bytes(say_wav("Still connected.", 16000))
                await ws.send_str(json.dumps({"type": "stop"}))
                text = await asyncio.wait_for(reader, 5)
        assert "connected" in text.lower()
    finally:
        s.stop()


async def test_connections_past_the_cap_get_503():
    s = Server("--max-connections", "2", own=True)
    s.start()
    try:
        health = s.url.replace("ws://", "http://") + "/health"
        idle = [await Raw().open(s.url, "/v1/stt/stream?sample_rate=16000&channels=1") for _ in range(2)]
        async with aiohttp.ClientSession() as session:
            async with session.get(health) as response:
                assert response.status == 503
            for raw in idle:
                raw.writer.close()
            await asyncio.sleep(0.5)
            async with session.get(health) as response:
                assert response.status == 200
    finally:
        s.stop()


@pytest.mark.parametrize("arg", ["uninstal", "0", "70000", "abc"])
def test_install_rejects_a_bad_argument(arg):
    result = subprocess.run([str(ROOT / "install.sh"), arg], capture_output=True, text=True)
    assert result.returncode == 2 and "usage" in result.stderr
