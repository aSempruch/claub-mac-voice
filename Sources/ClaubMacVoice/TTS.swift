// Text to speech with macOS's `say`, streamed as it renders.
//
// Each sentence is one `say -f - -o <file>.caf` process. `say` writes the CAF
// file progressively, so the server tails it and sends audio while the sentence
// is still rendering. Starting `say` and loading its voice costs about half a
// second, so a spare process per voice is started ahead of time, waiting on
// stdin; a sentence takes the spare and writes its text, and a new spare starts.
import Foundation
import Synchronization

let ttsFrameBytes = 9600  // 200 ms of 24 kHz mono 16-bit, as the reference server sends

// MARK: Voices

struct VoiceCatalog: Sendable {
    let names: [String]

    /// The voices `say -v '?'` lists (e.g. "Samantha", "Reed (English (US))").
    static func load() -> VoiceCatalog {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return VoiceCatalog(names: []) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let pattern = try! NSRegularExpression(pattern: #"^(.+?)\s+[a-z]{2,3}[_-][A-Za-z0-9]+\s+#"#)
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let s = String(line)
            if let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                names.append(String(s[r]))
            }
        }
        return VoiceCatalog(names: names)
    }

    /// The `say -v` name for a requested voice, or nil (the system voice) when there is no such voice.
    /// Matches exactly, then ignoring case, then by the name before " (", so "reed" finds "Reed (English (US))".
    func resolve(_ requested: String?) -> String? {
        guard let wanted = requested?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { return nil }
        if names.contains(wanted) { return wanted }
        if let hit = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return hit }
        func base(_ name: String) -> String {
            name.components(separatedBy: " (").first ?? name
        }
        return names.first(where: { base($0).caseInsensitiveCompare(wanted) == .orderedSame })
    }
}

// MARK: Sentences

/// The reference server's sentence break: after ., !, ? or … (and closing
/// quotes or brackets) and whitespace before a capital, digit, quote or bracket; around an em dash; at a
/// spaced en dash or hyphen; after ; or :.
private let sentenceEnd = try! NSRegularExpression(
    pattern: #"(?<=[.!?…])["')\]]*\s+(?=[A-Z0-9"'(\[])|\s*—\s*|\s+[–-]\s+|(?<=[;:])\s+"#)

/// A piece with a word to say; a dash left on its own is not rendered.
private func speakable(_ piece: String) -> Bool {
    piece.contains { $0.isLetter || $0.isNumber }
}

/// Split one `text` message into sentences exactly as the reference server does.
func splitSentences(_ text: String) -> [String] {
    var rest = text
    var out: [String] = []
    while let m = sentenceEnd.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
          let range = Range(m.range, in: rest) {
        let piece = rest[..<range.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
        rest = String(rest[range.upperBound...])
        if speakable(piece) { out.append(piece) }
    }
    let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    if speakable(last) { out.append(last) }
    return out
}

// MARK: say processes

/// Where `say` renders: a directory per server process under the temp dir, one subdirectory per `say`.
///
/// No audio is kept. A sentence's file goes as soon as the sentence has been read, failed or been cancelled
/// (`SayProcess.render` stops its process, which removes it); the server's directory goes when it stops
/// (`SayPool.stopAll`), and one left by a server that died is removed when the next one starts (`prepare`).
enum SayFiles {
    /// `$TMPDIR` when set (Foundation's own temp dir ignores it), else the user's temp dir.
    static let temp = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    static let parent = temp.appendingPathComponent("claub-mac-voice-say")
    static let root = parent.appendingPathComponent(String(getpid()))

    /// Create this server's directory and remove those of servers that are no longer running.
    static func prepare() {
        let files = FileManager.default
        try? files.createDirectory(at: parent, withIntermediateDirectories: true)
        for name in (try? files.contentsOfDirectory(atPath: parent.path)) ?? [] {
            if let pid = Int32(name), pid == getpid() || kill(pid, 0) == 0 || errno == EPERM { continue }
            try? files.removeItem(at: parent.appendingPathComponent(name))
        }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// One `say` process waiting for its text on stdin, rendering into a CAF file.
///
/// Used by one task at a time; only `stop` may come from another (a cancellation), and it is idempotent
/// behind `stopped`. `Process` and `Pipe` are safe to signal and close from any thread.
final class SayProcess: @unchecked Sendable {
    let voice: String?
    let rate: Int
    private let process = Process()
    private let stdin = Pipe()
    private let directory: URL
    let output: URL
    private let stopped = Mutex(false)

    init(voice: String?, rate: Int) throws {
        self.voice = voice
        self.rate = rate
        directory = SayFiles.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        output = directory.appendingPathComponent("speech.caf")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let voice { args += ["-v", voice] }
        args += ["-f", "-", "-o", output.path, "--file-format=caff", "--data-format=LEI16@\(rate)"]
        process.arguments = args
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        guard !stopped.withLock({ let was = $0; $0 = true; return was }) else { return }
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Speak `text`, handing over its 16-bit PCM and sample rate (from the file's header) as it renders.
    /// Cancelling stops `say`. However it ends, the rendered file is deleted before this returns.
    func render(_ text: String, chunk: (Data, Int) async throws -> Void) async throws {
        defer { stop() }
        // `say` reads embedded commands ("[[rate 300]]") in its text; keep them literal.
        let literal = text.replacingOccurrences(of: "[[", with: "[ [")
        try stdin.fileHandleForWriting.write(contentsOf: Data(literal.utf8))
        try stdin.fileHandleForWriting.close()
        var reader: FileHandle?
        var header = Data()
        var audioStart: Int?
        var sent = 0
        var pending = Data()
        var sampleRate = rate
        let deadline = Date().addingTimeInterval(60)
        while true {
            try Task.checkCancellation()
            let exited = !process.isRunning
            if reader == nil { reader = try? FileHandle(forReadingFrom: output) }
            var fresh = Data()
            if let reader {
                while let data = try reader.read(upToCount: 1 << 16), !data.isEmpty { fresh.append(data) }
            }
            if audioStart == nil {
                header.append(fresh)
                fresh = Data()
                if let parsed = CAF.parse(header) {
                    audioStart = parsed.audioOffset
                    if parsed.sampleRate > 0 { sampleRate = parsed.sampleRate }
                    fresh = header.count > parsed.audioOffset ? Data(header[parsed.audioOffset...]) : Data()
                }
            }
            if audioStart != nil {
                pending.append(fresh)
                if exited {
                    // The finished file's header has the audio's real length; drop anything after it.
                    if let whole = try? Data(contentsOf: output), let parsed = CAF.parse(whole), let length = parsed.audioLength {
                        let available = max(0, length - sent)
                        if pending.count > available { pending = Data(pending.prefix(available)) }
                    }
                }
                let ready = exited ? pending.count - pending.count % 2 : (pending.count / ttsFrameBytes) * ttsFrameBytes
                if ready > 0 {
                    var offset = 0
                    while offset < ready {
                        let size = min(ttsFrameBytes, ready - offset)
                        try await chunk(Data(pending[pending.startIndex + offset ..< pending.startIndex + offset + size]), sampleRate)
                        offset += size
                    }
                    pending.removeFirst(ready)
                    sent += ready
                }
            }
            if exited {
                if process.terminationStatus != 0 { throw TTSError.sayFailed(process.terminationStatus) }
                return
            }
            if Date() > deadline { throw TTSError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

enum TTSError: Error, CustomStringConvertible {
    case sayFailed(Int32)
    case timedOut
    var description: String {
        switch self {
        case .sayFailed(let status): return "say exited with status \(status)"
        case .timedOut: return "say took over 60 s"
        }
    }
}

/// The parts of a CAF file's header the tail reader needs.
enum CAF {
    struct Header {
        let audioOffset: Int   // first PCM byte
        let audioLength: Int?  // nil while `say` is still writing (size -1)
        let sampleRate: Int
    }

    static func parse(_ data: Data) -> Header? {
        let bytes = [UInt8](data.prefix(1 << 16))  // say puts the audio at 4096, after a "free" chunk
        guard bytes.count >= 8, bytes[0..<4] == [0x63, 0x61, 0x66, 0x66] else { return nil }  // "caff"
        func be64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(bytes[at + $1]) } }
        var offset = 8
        var rate = 0
        while offset + 12 <= bytes.count {
            let type = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = be64(offset + 4)
            if type == "desc", offset + 20 <= bytes.count {
                rate = Int(Double(bitPattern: be64(offset + 12)))
            }
            if type == "data" {
                let start = offset + 12 + 4  // after the edit count
                let length: Int? = size == UInt64.max ? nil : Int(size) - 4
                return start <= data.count ? Header(audioOffset: start, audioLength: length, sampleRate: rate) : nil
            }
            guard size < UInt64(Int.max) else { return nil }
            offset += 12 + Int(size)
        }
        return nil
    }
}

/// Spare `say` processes, one per recently used voice, so a sentence never waits for one to start.
actor SayPool {
    let rate: Int
    private var spares: [String: SayProcess] = [:]
    private var order: [String] = []
    private static let maxVoices = 4

    init(rate: Int) { self.rate = rate }

    private static func key(_ voice: String?) -> String { voice ?? "" }

    /// The voice's spare if it is still running (a dead one is cleaned up), else a new process.
    func take(voice: String?) throws -> SayProcess {
        let key = Self.key(voice)
        var process: SayProcess?
        if let spare = spares.removeValue(forKey: key) {
            if spare.isRunning { process = spare } else { spare.stop() }
        }
        refill(voice: voice)
        return try process ?? SayProcess(voice: voice, rate: rate)
    }

    func refill(voice: String?) {
        let key = Self.key(voice)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.maxVoices {
            let old = order.removeFirst()
            spares.removeValue(forKey: old)?.stop()
        }
        if let spare = spares[key], !spare.isRunning {
            spare.stop()
            spares[key] = nil
        }
        if spares[key] == nil { spares[key] = try? SayProcess(voice: voice, rate: rate) }
    }

    /// The first sentence after login loads the system voice from disk (about a second); do that now.
    func warmUp() async {
        let started = Date()
        guard let say = try? take(voice: nil) else { return }
        try? await say.render("Ready.") { _, _ in }
        log(String(format: "tts: system voice warmed up in %.2fs", Date().timeIntervalSince(started)))
    }

    /// Stop the spares and remove the server's `say` directory, with whatever a sentence still rendering left.
    func stopAll() {
        for spare in spares.values { spare.stop() }
        spares = [:]
        SayFiles.removeAll()
    }
}

// MARK: The /v1/tts/stream handler

/// One reply's counts, for its log line.
final class ReplyStats: Sendable {
    private struct State {
        var sentences = 0
        var seconds = 0.0
        var firstAudio: Double?
        var done = false
    }
    private let state = Mutex(State())

    func spoke(seconds: Double) { state.withLock { $0.sentences += 1; $0.seconds += seconds } }
    func audioStarted(after: Double) { state.withLock { if $0.firstAudio == nil { $0.firstAudio = after } } }
    func finished() { state.withLock { $0.done = true } }
    var done: Bool { state.withLock { $0.done } }
    var sentences: Int { state.withLock { $0.sentences } }
    var seconds: Double { state.withLock { $0.seconds } }
    var firstAudioText: String { state.withLock { $0.firstAudio }.map { String(format: "%.3fs", $0) } ?? "none" }
}

struct TTSService: Sendable {
    let catalog: VoiceCatalog
    let pool: SayPool

    func handle(_ ws: WSConnection, query: [String: String]) async {
        let requested = (query["voice"] ?? "").trimmingCharacters(in: .whitespaces)
        let voice = catalog.resolve(requested)
        let id = ws.id
        let (sentences, queue) = AsyncStream.makeStream(of: String?.self)
        let started = Date()
        let stats = ReplyStats()

        let speaker = Task {
            do {
                for await item in sentences {
                    guard let sentence = item else {
                        try await ws.sendJSON(["type": "done"])
                        stats.finished()
                        ws.close()
                        return
                    }
                    try Task.checkCancellation()
                    try await speak(sentence, voice: voice, ws: ws, stats: stats, started: started)
                }
            } catch is CancellationError {
            } catch is WSConnection.Closed {
            } catch {
                log("tts #\(id) failed: \(error)")
                await ws.trySendJSON(["type": "error", "message": "synthesis failed"])
                ws.close(code: 1011, reason: "synthesis failed")
            }
        }

        var ended = false
        while let message = await ws.receive() {
            if ended { continue }  // nothing counts after end; reading on notices a hang-up
            var bad: String?
            switch message {
            case .binary:
                bad = "send text messages, not binary frames"
            case .text(let text):
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    bad = "messages must be JSON objects"
                    break
                }
                let type = object["type"] as? String
                if type == "text" {
                    for sentence in splitSentences((object["text"] as? String) ?? "") { queue.yield(sentence) }
                } else if type == "end" {
                    queue.yield(nil)
                    queue.finish()
                    ended = true
                } else {
                    bad = "unknown message type \(type.map { "'\($0)'" } ?? "None")"
                }
            }
            if let bad {
                speaker.cancel()
                queue.finish()
                await ws.trySendJSON(["type": "error", "message": bad])
                ws.close(code: 1008, reason: "bad request")
                log("tts #\(id) bad request: \(bad)")
                return
            }
        }
        // The socket is gone. Unless the reply was all sent, that cancels the rest of it.
        if !stats.done { speaker.cancel() }
        await speaker.value
        let voiceName = (voice ?? "system default") + (!requested.isEmpty && voice == nil ? " (no voice \(requested))" : "")
        if stats.done {
            log(String(format: "tts #%d %d sentence(s) -> %.1fs audio, voice %@, first audio %@, total %.2fs",
                       id, stats.sentences, stats.seconds, voiceName, stats.firstAudioText, Date().timeIntervalSince(started)))
        } else {
            log("tts #\(id) client left after \(stats.sentences) sentence(s), first audio \(stats.firstAudioText), voice \(voiceName)")
        }
    }

    /// Speak one sentence. A `say` that fails before any audio (e.g. a spare that died) is retried once
    /// with a fresh one; a sentence that still fails is skipped, as the reference server skips it.
    private func speak(_ sentence: String, voice: String?, ws: WSConnection, stats: ReplyStats, started: Date) async throws {
        var announced = false
        var bytes = 0
        var rate = pool.rate
        for attempt in 1...2 {
            let say = attempt == 1 ? try await pool.take(voice: voice) : try SayProcess(voice: voice, rate: pool.rate)
            do {
                try await withTaskCancellationHandler {
                    try await say.render(sentence) { pcm, sampleRate in
                        if !announced {
                            rate = sampleRate
                            try await ws.sendJSON(["type": "sentence", "text": sentence, "rate": sampleRate, "width": 2, "channels": 1])
                            announced = true
                            stats.audioStarted(after: Date().timeIntervalSince(started))
                        }
                        bytes += pcm.count
                        try await ws.send(.binary(pcm))
                    }
                } onCancel: {
                    say.stop()
                }
                break
            } catch let error where error is CancellationError || error is WSConnection.Closed {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if announced || attempt == 2 {
                    log("tts #\(ws.id): say failed (\(error)); skipping the rest of that sentence")
                    break
                }
                log("tts #\(ws.id): say failed before any audio (\(error)); retrying with a new process")
            }
        }
        if announced { stats.spoke(seconds: Double(bytes) / Double(2 * rate)) }
    }
}
