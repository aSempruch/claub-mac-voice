// claub-mac-voice: Claub's streaming speech protocol on macOS's own speech engines.
//
//   ws://HOST:PORT/v1/stt/stream?sample_rate=48000&channels=2   SpeechAnalyzer (on device)
//   ws://HOST:PORT/v1/tts/stream?voice=NAME                    say
//   http://HOST:PORT/health                                    JSON status
//
// The wire protocol is described in README.md.
import Foundation
import Network
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)  // a peer or a say that went away is an error to handle, not a reason to die

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()
private let logLock = Mutex(())

func log(_ message: String) {
    logLock.withLock { _ in
        FileHandle.standardError.write(Data("\(logFormatter.string(from: Date())) \(message)\n".utf8))
    }
}

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 10301
    var locale = "en-US"
    var ttsRate = 24000
    var maxConnections = 16
    var pingInterval = 20.0

    static let usage = """
        usage: claub-mac-voice [--host 127.0.0.1] [--port 10301] [--locale en-US] [--tts-rate 24000]
                               [--max-connections 16] [--ping-interval 20]
        Environment: CLAUB_MAC_VOICE_HOST, CLAUB_MAC_VOICE_PORT, CLAUB_MAC_VOICE_LOCALE, CLAUB_MAC_VOICE_TTS_RATE.
        --ping-interval: seconds between pings; a peer that has not answered by the next one is dropped (0: off).
        """

    static func parse() -> Options {
        var o = Options()
        let env = ProcessInfo.processInfo.environment
        if let v = env["CLAUB_MAC_VOICE_HOST"] { o.host = v }
        if let v = env["CLAUB_MAC_VOICE_PORT"].flatMap(UInt16.init) { o.port = v }
        if let v = env["CLAUB_MAC_VOICE_LOCALE"] { o.locale = v }
        if let v = env["CLAUB_MAC_VOICE_TTS_RATE"].flatMap(Int.init) { o.ttsRate = v }
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            func value() -> String {
                guard let v = args.next() else { fail("\(arg) needs a value") }
                return v
            }
            switch arg {
            case "--host": o.host = value()
            case "--port": o.port = UInt16(value()) ?? { fail("bad --port") }()
            case "--locale": o.locale = value()
            case "--tts-rate": o.ttsRate = Int(value()) ?? { fail("bad --tts-rate") }()
            case "--max-connections": o.maxConnections = Int(value()) ?? { fail("bad --max-connections") }()
            case "--ping-interval": o.pingInterval = Double(value()) ?? { fail("bad --ping-interval") }()
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(arg)")
            }
        }
        guard (8000...48000).contains(o.ttsRate) else { fail("--tts-rate must be 8000-48000") }
        guard o.maxConnections > 0, o.pingInterval >= 0 else { fail("bad --max-connections or --ping-interval") }
        return o
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("claub-mac-voice: \(message)\n\(usage)\n".utf8))
        exit(2)
    }
}

let options = Options.parse()
SayFiles.prepare()
let catalog = VoiceCatalog.load()
let pool = SayPool(rate: options.ttsRate)
let model = SpeechModel(locale: Locale(identifier: options.locale))
let tts = TTSService(catalog: catalog, pool: pool)
let stt = STTService(model: model)
private let sttPath = "/v1/stt/stream"
private let ttsPath = "/v1/tts/stream"

func serve(_ ws: WSConnection) async {
    ws.start()
    guard let request = await ws.readRequest() else {
        ws.cancel()  // a bare connect (nc -z), a malformed or late request head
        return
    }
    if request.method == "GET", request.path == "/health", request.headers["upgrade"] == nil {
        let state = await model.state
        let body: [String: Any] = [
            "ok": true, "stt": ["locale": options.locale, "state": state],
            "tts": ["engine": "say", "voices": catalog.names.count, "rate": options.ttsRate],
            "connections": active.withLock { $0 },
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        await ws.respond(status: "200 OK", json: json)
        return
    }
    guard await ws.upgrade(request) else { return }
    switch request.path {
    case sttPath: await stt.handle(ws, query: request.query)
    case ttsPath: await tts.handle(ws, query: request.query)
    default:
        await ws.trySendJSON(["type": "error", "message": "unknown path; use \(sttPath) or \(ttsPath)"])
        ws.close(code: 1008, reason: "unknown path")
    }
}

/// Connections being served now; past `maxConnections` a new one gets 503.
let active = Mutex(0)
let nextID = Mutex(0)
WSConnection.pingInterval = options.pingInterval

let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(options.host), port: NWEndpoint.Port(rawValue: options.port)!)
let listener: NWListener
do {
    listener = try NWListener(using: parameters)
} catch {
    Options.fail("cannot listen on \(options.host):\(options.port): \(error)")
}
listener.newConnectionHandler = { connection in
    let id = nextID.withLock { $0 += 1; return $0 }
    let ws = WSConnection(id: id, connection: connection)
    let admitted = active.withLock { count in
        guard count < options.maxConnections else { return false }
        count += 1
        return true
    }
    Task {
        if admitted {
            await serve(ws)
            active.withLock { $0 -= 1 }
        } else {
            log("connection #\(id) refused: \(options.maxConnections) connections already open")
            ws.start()
            await ws.respond(status: "503 Service Unavailable", json: #"{"error":"too many connections"}"#)
        }
    }
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        log("listening on ws://\(options.host):\(options.port)\(sttPath) and \(ttsPath) (\(catalog.names.count) say voices, TTS \(options.ttsRate) Hz)")
    case .failed(let error):
        log("listener failed: \(error)")
        Task {
            await pool.stopAll()  // no spare say or temp dir outlives the server
            exit(1)
        }
    default:
        break
    }
}
listener.start(queue: DispatchQueue(label: "listener"))

// Install and load the speech model now, so the first call does not wait for it; warm the default voice.
Task {
    do { try await model.prepare() } catch { log("stt: \(error)") }
}
Task.detached { await pool.warmUp() }

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("stopping")
        Task {
            await pool.stopAll()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}
dispatchMain()
