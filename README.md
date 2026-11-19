# claub-mac-voice

A local streaming speech server for macOS that uses only what ships with the OS: `say` speaks and Apple's
on-device recognizer (`SpeechAnalyzer` with `SpeechTranscriber`, macOS 26) listens. It serves two WebSocket
endpoints on localhost, `/v1/stt/stream` (speech to text) and `/v1/tts/stream` (text to speech), for a voice
call client that streams microphone audio in and plays reply audio out as it arrives.

The protocol is the one used by voice calls in Claub, the agent harness this was written for. Claub's
original voice server (called "the reference server" below) is a GPU speech server; claub-mac-voice speaks
the same protocol, so the client runs against either unchanged. Nothing here depends on Claub: the protocol is
described in full below, and any client that follows it works.

It is one Swift executable with no dependencies: Network.framework for the socket, a small WebSocket layer of
its own (Network.framework's WebSocket support does not expose the request's path and query, which the
protocol needs), the Speech framework in-process, and one `say` process per sentence.

## Requirements

- macOS 26 or later (`SpeechAnalyzer`). Tested on Apple silicon.
- Xcode or the Command Line Tools with Swift 6 to build.
- The on-device speech model for the locale (English by default). The server installs it through
  `AssetInventory` at startup; the first run on a Mac downloads it, once. Recognition itself never uses the
  network.
- [uv](https://docs.astral.sh/uv/) to run the tests.

No permissions to grant. `SpeechAnalyzer` needs no Speech Recognition authorization (unlike
`SFSpeechRecognizer`), and audio arrives over the socket, so the microphone is never opened. Tested as a
LaunchAgent and from a terminal: no prompt appears.

## Build and run by hand

```bash
swift build -c release
.build/release/claub-mac-voice --port 10301      # --host 127.0.0.1 --locale en-US --tts-rate 24000
                                                 # --max-connections 16 --ping-interval 20
```

| Option | Environment | Default | |
|---|---|---|---|
| `--host` | `CLAUB_MAC_VOICE_HOST` | `127.0.0.1` | interface to bind; nothing needs another one |
| `--port` | `CLAUB_MAC_VOICE_PORT` | `10301` | |
| `--locale` | `CLAUB_MAC_VOICE_LOCALE` | `en-US` | any `SpeechTranscriber` locale |
| `--tts-rate` | `CLAUB_MAC_VOICE_TTS_RATE` | `24000` | TTS sample rate, 8000 to 48000 Hz |
| `--max-connections` | | `16` | connections served at once; more get `503` |
| `--ping-interval` | | `20` | seconds between WebSocket pings (`0` turns them off) |

Command-line options override the environment. The server logs to stderr.

## Install (runs at login)

```bash
./install.sh            # builds, installs ~/.local/bin/claub-mac-voice, loads the LaunchAgent, checks /health
```

`./install.sh 10401` uses another port; `./install.sh uninstall` stops it and removes the LaunchAgent and the
binary (and the voice link's agents, below, if installed). Run `./install.sh` again after pulling changes. The
log is `~/Library/Logs/claub-mac-voice.log`.

The LaunchAgent is [`launchd/claub-mac-voice.plist`](launchd/claub-mac-voice.plist) (label `claub-mac-voice`,
`KeepAlive`, `RunAtLoad`, bound to `127.0.0.1`); `install.sh` fills in its `BINARY`, `PORT` and `LOG`
placeholders and copies it to `~/Library/LaunchAgents/`. To manage it by hand:

```bash
launchctl print gui/$(id -u)/claub-mac-voice | head        # state
launchctl kickstart -k gui/$(id -u)/claub-mac-voice        # restart
launchctl bootout gui/$(id -u)/claub-mac-voice             # stop until the next login
curl -s http://127.0.0.1:10301/health                      # {"ok":true,"stt":{"state":"ready",...},...}
```

## Voice link (for Claub)

When Claub runs on a dev box (an RDE, say) that cannot reach this Mac, the Mac dials in instead: the Mac
opens an `ssh -L` forward to the dev box, and the relay [`link/claub_voice_link.py`](link/claub_voice_link.py)
keeps a websocket to Claub's `/voice-link` through it, authenticated with a token Claub made. Claub carries
each of its voice connections over that link as a stream, and the relay connects each stream to this server
on `127.0.0.1:10301`. Claub needs `voice_link: {enabled: true}` in its `claub.yaml`. The relay is a
[uv](https://docs.astral.sh/uv/) script (its one dependency, `aiohttp`, is declared inline);
[`link/voice_link_wire.py`](link/voice_link_wire.py) is the wire format, a copy of Claub's that must change
with it. Nothing of Claub needs to be on this Mac.

The relay retries forever with backoff up to 30 s while the tunnel or Claub is down, and logs each change
once ("Link up", "Link down: ...", "No link to Claub: ..." with the cause, such as a refused token). It notices
a dead socket by websocket pings and at once when the Mac wakes from sleep.

On the Mac, once the voice server is installed (above) and Claub has started on the dev box:

```bash
# 1. The token Claub made on the dev box, copied once (a new one is made only if that file is deleted):
mkdir -p ~/.config/claub
scp DEVBOX:.claub/data/voice-link.token ~/.config/claub/voice-link.token
chmod 600 ~/.config/claub/voice-link.token

# 2. The tunnel and the relay, both run at login and restarted by launchd:
./install.sh --link --tunnel DEVBOX     # --token-file PATH for a token elsewhere
```

`--tunnel DEVBOX` installs the LaunchAgent `com.claub.tunnel`
([`launchd/com.claub.tunnel.plist`](launchd/com.claub.tunnel.plist)), which runs

```bash
ssh -N -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ExitOnForwardFailure=yes -o BatchMode=yes \
    -L 9420:127.0.0.1:9420 DEVBOX
```

The keepalives make a dead tunnel (the Mac slept, the network changed) exit within about 20 s, and launchd
starts it again. It needs ssh to `DEVBOX` (any `~/.ssh/config` host) without a prompt: a key in the ssh agent
or the keychain. The same forward brings Claub's web app to `http://localhost:9420`. If you open the tunnel
yourself instead, leave `--tunnel` out.

`--link` checks that `uv` is installed and that the token file exists with mode 600, copies the relay to
`~/.local/share/claub-mac-voice/link/` (so this checkout can move), and installs the LaunchAgent
`com.claub.voice-link` ([`launchd/com.claub.voice-link.plist`](launchd/com.claub.voice-link.plist)). Both
options are idempotent: run `git pull && ./install.sh --link` to update the relay. Logs:
`~/Library/Logs/claub-voice-link.log` and `~/Library/Logs/claub-tunnel.log`. To try the relay in a terminal
first: `uv run link/claub_voice_link.py --token-file ~/.config/claub/voice-link.token` (`--help` for its
options: `--url`, default `ws://127.0.0.1:9420/voice-link`, and `--voice`, default `127.0.0.1:10301`).

Privacy: the relay logs the link's state and stream ids only, never what the streams carry (a call's audio
and transcripts), and keeps aiohttp's own logging at warnings even with `--verbose`. The token stays in its
file and is sent only to Claub, through the tunnel.

## Privacy

Everything runs on the Mac: recognition is on-device and `say` is local. No speech content is logged and no
recordings are kept:

- The log has one line per utterance and per reply with timings and counts only (seconds of audio,
  characters of transcript, sentences, voice). No transcript, partial, sentence or reply text is ever logged.
- Incoming audio is fed to the recognizer in memory and never written to disk.
- `say` renders each sentence to a CAF file under `$TMPDIR/claub-mac-voice-say/<pid>/` (a spare `say` waiting
  for its sentence holds only an empty CAF header). The file is deleted as soon as the sentence has been read,
  failed or been cancelled. The `<pid>` directory is removed when the server stops, and at startup the server
  removes any directory left by a server that is no longer running.

## Protocol

Plain HTTP/1.1 with a WebSocket upgrade (RFC 6455, no extensions or subprotocols) on one port. The request
path is percent-decoded; in the query string `+` is a space. All JSON messages are WebSocket text messages
holding one JSON object with a `type` field; audio is WebSocket binary messages of raw 16-bit little-endian
signed PCM (no header).

### `GET /health`

A plain HTTP request (no upgrade). Answers `200` with JSON and closes:

```json
{"connections": 1, "ok": true,
 "stt": {"locale": "en-US", "state": "ready"},
 "tts": {"engine": "say", "rate": 24000, "voices": 180}}
```

`stt.state` is `ready` once the speech model is installed and loaded, otherwise what it is waiting for (for
example the model download). A plain request to any other path, or one to a WebSocket path without a valid
upgrade, gets `400`.

### Speech to text: `ws://HOST:PORT/v1/stt/stream?sample_rate=R&channels=C`

One socket per utterance.

- Query: `sample_rate` 8000 to 48000 (default 16000), `channels` 1 or 2 (default 1). Stereo is mixed to mono
  and everything is resampled to the model's 16 kHz.
- Client to server:
  - binary messages of PCM in that format, of any length that holds whole samples (`2 * channels` bytes
    each), streamed as captured (for example 20 ms frames);
  - `{"type": "stop"}` at the end of the utterance. Other JSON types are ignored.
- Server to client:
  - `{"type": "partial", "text": "..."}` each time the running hypothesis changes. `text` is always the whole
    transcript so far (finalized segments plus the current guess), not a delta.
  - After `stop`: `{"type": "final", "text": "..."}`, then a normal close (1000). If finalizing takes over
    4 s, the final is the transcript so far. `stop` with no usable audio gets `{"type": "final", "text": ""}`.
  - A client that closes or leaves before `stop` gets nothing more; the utterance is discarded.
- Errors: a bad `sample_rate` or `channels`, a binary message that does not hold whole samples, a text message
  that is not a JSON object, or more than 120 s of audio get `{"type": "error", "message": "..."}` and close
  code 1008. If recognition is unavailable or fails, the error is followed by close code 1011.

### Text to speech: `ws://HOST:PORT/v1/tts/stream?voice=NAME`

One socket per reply.

- Query: `voice` (optional), a `say -v` voice name; see [Voices](#voices).
- Client to server:
  - `{"type": "text", "text": "..."}`, any number of them, sent as the reply is written (a sentence may not
    span two `text` messages: each message is split into sentences on its own);
  - `{"type": "end"}` when the reply is complete. Messages after `end` are ignored.
- Server to client, for each sentence in order:
  - `{"type": "sentence", "text": "...", "rate": 24000, "width": 2, "channels": 1}` before the sentence's audio
    (`rate` in Hz, `width` in bytes per sample);
  - that sentence's audio as binary messages of 16-bit mono PCM at `rate`, 9600 bytes each (200 ms at
    24 kHz; the last of a sentence may be shorter), sent while `say` is still rendering.

  After `end` and the last sentence: `{"type": "done"}` and a normal close (1000). A reply with no text is
  `done` with no audio.
- Sentences break after `.`, `!`, `?` or `…` (plus closing quotes or brackets) when whitespace and then a
  capital, digit, quote or bracket follow; around an em dash; at an en dash or hyphen with spaces on both
  sides; and after `;` or `:`. Pieces with no letter or digit (a lone dash) are not spoken. So
  `"It is 7 a.m. now. Anything else?"` is two sentences and `"Two things: this works; that doesn't."` three.
- A sentence `say` cannot render is retried once with a fresh process, then skipped; the rest of the reply
  still plays. `say` text is literal: `[[` is broken up so a reply cannot carry `say` embedded commands.
- Closing the socket early (the user talked over the reply) stops rendering at once: the `say` process is
  killed and nothing more is sent.
- Errors: a binary message, a text message that is not a JSON object, or an unknown `type` get
  `{"type": "error", "message": "..."}` and close code 1008. An unexpected synthesis failure gets
  `{"type": "error", "message": "synthesis failed"}` and close code 1011.

### Any other WebSocket path

`{"type": "error", "message": "unknown path; ..."}` and close code 1008.

### Connections and limits

- A connection must send its whole HTTP request head (at most 16 KB) within 10 s, or it is dropped, so bare
  connects (`nc -z`, port scanners) cost nothing.
- At most `--max-connections` (16) connections are served at once; more get HTTP `503` with
  `{"error":"too many connections"}`.
- Pings: the server sends a WebSocket ping every `--ping-interval` seconds (20) and drops a peer that has not
  answered with a pong by the next ping, cancelling its utterance or reply. A Mac that slept, or a relay that
  lost its other end, so frees its sockets. WebSocket libraries answer pings automatically as long as
  something reads the socket.
- A message is at most 1 MB (larger closes with 1009). Unread client messages past 4 MB pause reading from that
  socket, so TCP holds the client back.
- Frames follow RFC 6455 strictly: unmasked client frames, reserved bits, bad control frames, bad close
  codes and broken fragmentation close with 1002, invalid UTF-8 with 1007.

## Voices

With no `voice`, `say` uses the system voice (System Settings > Accessibility > Spoken Content > System
voice). A `voice` names a `say -v` voice (`say -v '?'` lists them): exactly, ignoring case, or by its name
before the parenthesis, so `reed` finds `Reed (English (US))`. A name the Mac lacks falls back to the system
voice. Premium and Siri-style voices sound better and are downloaded in the same System Settings pane.

## How it is fast

- **TTS.** `say` writes its CAF file progressively, so the server tails the file and sends audio while the
  sentence is still rendering. Starting `say` costs about half a second, so a spare `say` waits on stdin for
  each recently used voice (up to four); a sentence takes it and a new spare starts. At startup the server
  renders one throwaway word, so the first reply after login does not pay for loading the voice from disk
  (about a second).
- **STT.** The model is installed, reserved and warmed at startup with `modelRetention: .processLifetime`.
  Each utterance gets its own analyzer fed live from the socket (stereo is mixed to mono, then
  `AVAudioConverter` resamples to the model's 16 kHz); `volatileResults` and `fastResults` give partials as the
  words come, and stop finalizes what is left.

Measured on an M-series MacBook (macOS 26.6) with this repository's tests:

| | |
|---|---|
| TTS first audio of a reply (warm, system voice) | 0.45 to 0.55 s from the first `text` |
| TTS first audio, first reply after startup | 0.45 s (after the startup warm-up; 1.5 s without it) |
| STT final after `stop` (utterance streamed in real time) | 0.08 to 0.11 s |
| STT first partial | about one word into the speech |

## Tests

```bash
swift build -c release
uv run --project tests pytest tests -q -s           # starts the server on a free port; prints the latencies
CLAUB_MAC_VOICE_URL=ws://127.0.0.1:10301 uv run --project tests pytest tests -q   # against a running server
```

`tests/test_protocol.py` drives the server with `aiohttp` as a call client does. It covers no speech in the
log and no audio left on disk (after a reply, a hang-up mid-sentence, and the server stopping), labelled
24 kHz audio for two sentences, the reference server's sentence-splitting cases, hanging up mid-reply (no
`say` left rendering), unknown, short and `+`-encoded voice names, dead spare `say` processes, empty replies,
bad requests, recognition of a `say`-generated utterance at 48 kHz stereo (partials before the final, the
expected words) and 16 kHz mono, stop with no usable audio, 300 bare connects without leaking a socket, the
request deadline, pings, the connection cap, RFC 6455 violations, and `install.sh` argument checks. Against a
running server the log checks are skipped. `tests/test_voice_link.py` runs the voice link relay against a
fake Claub `/voice-link` (token and subprotocol checked, the real wire): a reply and an utterance go through
the link to the server, and a wrong token is logged once and retried.

## Limits

- English (`en-US`) by default; `--locale` picks another installed `SpeechTranscriber` locale.
- No custom vocabulary or phonetic correction; Apple's model formats numbers as digits ("72 degrees").
- macOS only, by design.

## License

MIT; see [LICENSE](LICENSE).
