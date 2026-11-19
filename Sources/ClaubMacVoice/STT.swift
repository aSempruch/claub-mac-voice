// Speech to text with Apple's on-device SpeechAnalyzer + SpeechTranscriber (macOS 26).
//
// Audio is transcribed by the system's on-device model; nothing goes to the network
// (the model itself is downloaded once through AssetInventory). Each utterance is
// one analyzer fed live from the socket; volatile results become `partial`s and
// `stop` finalizes the rest.
import AVFAudio
import Foundation
import Speech
import Synchronization

let maxUtteranceSeconds = 120.0

/// The transcription model for one locale, installed and kept loaded for the server's lifetime.
actor SpeechModel {
    let requestedLocale: Locale
    private(set) var locale: Locale?
    private(set) var format: AVAudioFormat?
    private(set) var state = "starting"
    private var preparing: Task<Void, Error>?

    init(locale: Locale) { requestedLocale = locale }

    func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    /// Install the model if needed (first run downloads it) and find the audio format it takes.
    func prepare() async throws {
        if let preparing { return try await preparing.value }
        let task = Task { try await self.install() }
        preparing = task
        do { try await task.value } catch { preparing = nil; throw error }
    }

    private func install() async throws {
        guard SpeechTranscriber.isAvailable else {
            state = "unavailable: SpeechTranscriber is not available on this Mac"
            throw STTError.unavailable(state)
        }
        guard let found = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            state = "unavailable: no on-device model for \(requestedLocale.identifier)"
            throw STTError.unavailable(state)
        }
        let transcriber = makeTranscriber(found)
        _ = try? await AssetInventory.reserve(locale: found)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = "installing the \(found.identifier) speech model"
            log("stt: \(state) (status \(status); downloads once)")
            let progress = request.progress
            let reporter = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    log(String(format: "stt: model download %.0f%%", progress.fractionCompleted * 100))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
            log("stt: \(found.identifier) speech model installed")
        }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            state = "unavailable: no audio format for the speech model"
            throw STTError.unavailable(state)
        }
        locale = found
        format = best
        state = "ready"
        log("stt: \(found.identifier) model ready, analyzer audio \(best)")
        await warmUp(locale: found, format: best)
    }

    /// Run one second of silence through an analyzer, so the first real utterance finds the model loaded.
    private func warmUp(locale: Locale, format: AVAudioFormat) async {
        let started = Date()
        let transcriber = makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.options)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
        buffer.frameLength = buffer.frameCapacity  // zeroed: silence
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let drain = Task { for try await _ in transcriber.results {} }
        do {
            try await analyzer.start(inputSequence: inputs)
            feed.yield(AnalyzerInput(buffer: buffer))
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log("stt: warm-up failed: \(error)")
        }
        _ = await drain.result
        log(String(format: "stt: model warmed up in %.2fs", Date().timeIntervalSince(started)))
    }

    static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
}

enum STTError: Error, CustomStringConvertible {
    case unavailable(String)
    case badAudio(String)
    var description: String {
        switch self {
        case .unavailable(let message), .badAudio(let message): return message
        }
    }
}

/// Turns the client's 16-bit interleaved PCM into buffers in the analyzer's format.
final class PCMConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let channels: Int

    init(rate: Int, channels: Int, output: AVAudioFormat) throws {
        self.channels = channels
        // Stereo is mixed to mono here, so the converter only changes rate and sample type.
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true) else {
            throw STTError.badAudio("unsupported audio format")
        }
        inputFormat = input
        outputFormat = output
        if input.sampleRate == output.sampleRate && output.commonFormat == .pcmFormatInt16 && output.channelCount == 1 {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: input, to: output) else { throw STTError.badAudio("cannot convert audio") }
            converter = made
        }
    }

    func convert(_ pcm: Data, flush: Bool = false) throws -> AVAudioPCMBuffer? {
        let frames = pcm.count / (2 * channels)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))) else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = input.int16ChannelData![0]
            if channels == 1 {
                for i in 0..<frames { out[i] = Int16(littleEndian: samples[i]) }
            } else {
                for i in 0..<frames {
                    let left = Int32(Int16(littleEndian: samples[2 * i])), right = Int32(Int16(littleEndian: samples[2 * i + 1]))
                    out[i] = Int16((left + right) / 2)
                }
            }
        }
        guard let converter else { return frames > 0 ? input : nil }
        let capacity = AVAudioFrameCount(Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if given || frames == 0 {
                outStatus.pointee = flush ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? STTError.badAudio("audio conversion failed") }
        return output.frameLength > 0 ? output : nil
    }
}

/// The running transcript of one utterance: finalized segments, then the latest volatile guess.
struct Transcript {
    private(set) var finalized = ""
    private(set) var volatile = ""

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
        return a + " " + b
    }

    mutating func add(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    var text: String {
        Self.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

// MARK: The /v1/stt/stream handler

/// One utterance's transcript as results arrive, shared by the result reader and the handler.
actor UtteranceState {
    private var transcript = Transcript()
    private var last = ""
    private(set) var firstPartial: Double?

    /// Add a result; returns the new hypothesis if it changed.
    func add(_ text: String, isFinal: Bool, elapsed: Double) -> String? {
        transcript.add(text, isFinal: isFinal)
        let now = transcript.text
        guard now != last else { return nil }
        last = now
        if firstPartial == nil, !now.isEmpty { firstPartial = elapsed }
        return now
    }

    var text: String { transcript.text }
}

/// Seconds `stop` may wait for the analyzer to finalize before the server answers with what it has.
let finalizeTimeout: Double = 4

struct STTService: Sendable {
    let model: SpeechModel

    func handle(_ ws: WSConnection, query: [String: String]) async {
        let id = ws.id
        let rate = Int(query["sample_rate"] ?? "16000") ?? -1
        let channels = Int(query["channels"] ?? "1") ?? -1
        guard (8000...48000).contains(rate), [1, 2].contains(channels) else {
            await ws.trySendJSON(["type": "error", "message": "sample_rate must be 8000-48000 and channels 1 or 2"])
            ws.close(code: 1008, reason: "bad audio format")
            return
        }
        let t0 = Date()
        do {
            try await model.prepare()
        } catch {
            await ws.trySendJSON(["type": "error", "message": "recognition unavailable: \(error)"])
            ws.close(code: 1011, reason: "recognition unavailable")
            return
        }
        guard let locale = await model.locale, let format = await model.format else { return }
        let transcriber = await model.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechModel.options)
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let converter: PCMConverter
        do {
            converter = try PCMConverter(rate: rate, channels: channels, output: format)
            try await analyzer.start(inputSequence: inputs)
        } catch {
            await ws.trySendJSON(["type": "error", "message": "recognition failed: \(error)"])
            ws.close(code: 1011, reason: "recognition failed")
            return
        }

        let state = UtteranceState()
        let reader = Task {
            for try await result in transcriber.results {
                if let text = await state.add(String(result.text.characters), isFinal: result.isFinal,
                                              elapsed: Date().timeIntervalSince(t0)) {
                    try? await ws.sendJSON(["type": "partial", "text": text])
                }
            }
        }

        var received = 0
        var fed = false  // some audio reached the analyzer (a short frame may resample to nothing)
        var stoppedAt: Date?
        var bad: String?
        loop: while let message = await ws.receive() {
            switch message {
            case .binary(let pcm):
                if pcm.count % (2 * channels) != 0 { bad = "PCM frames must hold whole 16-bit samples"; break loop }
                received += pcm.count
                if Double(received) / Double(2 * channels * rate) > maxUtteranceSeconds {
                    bad = "utterance exceeded 120 second audio limit"; break loop
                }
                do {
                    if let buffer = try converter.convert(pcm) { feed.yield(AnalyzerInput(buffer: buffer)); fed = true }
                } catch {
                    bad = "\(error)"; break loop
                }
            case .text(let text):
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    bad = "messages must be JSON objects"; break loop
                }
                if object["type"] as? String == "stop" {
                    stoppedAt = Date()
                    break loop
                }
            }
        }

        guard let stoppedAt, bad == nil else {
            // A bad frame, or the client left before stop: no transcript.
            feed.finish()
            await analyzer.cancelAndFinishNow()
            reader.cancel()
            _ = await reader.result
            if let bad {
                await ws.trySendJSON(["type": "error", "message": bad])
                ws.close(code: 1008, reason: "bad request")
                log("stt #\(id) bad request: \(bad)")
            } else {
                log("stt #\(id) client left before stop")
            }
            return
        }
        do {
            if let tail = try converter.convert(Data(), flush: true) { feed.yield(AnalyzerInput(buffer: tail)); fed = true }
        } catch {
            log("stt #\(id) audio flush failed: \(error)")
        }
        feed.finish()
        var note = ""
        if !fed {
            // Nothing to finalize: the analyzer would wait for input forever.
            await analyzer.cancelAndFinishNow()
            reader.cancel()
            note = ", no audio reached the recognizer"
        } else if await finalize(analyzer) {
            _ = await reader.result  // the results end once the analyzer has finished
        } else {
            // Answer with the transcript so far rather than hang the caller.
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
            note = String(format: ", finalize timed out after %.0fs", finalizeTimeout)
        }
        let text = await state.text
        do {
            try await ws.sendJSON(["type": "final", "text": text])
        } catch {
            log("stt #\(id) client left before the final transcript")
            return
        }
        ws.close()
        let firstPartial = await state.firstPartial
        // Never the transcript itself: speech content stays out of the log (only its length).
        log(String(format: "stt #%d %.2fs audio -> %d chars (first partial %@, post_stop %.3fs, total %.3fs%@)",
                   id, Double(received) / Double(2 * channels * rate), text.count,
                   firstPartial.map { String(format: "%.3fs", $0) } ?? "none",
                   Date().timeIntervalSince(stoppedAt), Date().timeIntervalSince(t0), note))
    }

    /// Finalize what the analyzer has; false if that failed or took longer than `finalizeTimeout`.
    /// (Not a task group: that would wait for a finalize that never returns.)
    private func finalize(_ analyzer: SpeechAnalyzer) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Task {
                let ok = (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil
                if once.claim() { done.resume(returning: ok) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(finalizeTimeout * 1e9))
                if once.claim() { done.resume(returning: false) }
            }
        }
    }
}

/// True for the first caller only.
final class Once: Sendable {
    private let claimed = Mutex(false)
    func claim() -> Bool { claimed.withLock { was in defer { was = true }; return !was } }
}
