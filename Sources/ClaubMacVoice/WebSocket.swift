// A small RFC 6455 server over Network.framework TCP.
//
// Network.framework's own WebSocket protocol does not expose the request path or
// query, which the speech protocol needs (`?sample_rate=`, `?voice=`), so the
// HTTP upgrade and the framing are done here. No extensions, no subprotocols.
//
// Every mutable field of a connection is touched only on its serial `queue`;
// the async methods hop onto it. That is why the class can be `Sendable`.
import CryptoKit
import Foundation
import Network

enum WSMessage: Sendable {
    case text(String)
    case binary(Data)
}

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]  // lower-cased names
}

/// Decode a query string as Python's `parse_qs` does: `+` is a space, then percent-escapes; first value wins.
func parseQuery(_ query: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        func decode(_ s: Substring) -> String {
            let spaced = s.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        let name = decode(parts[0])
        if result[name] == nil { result[name] = parts.count > 1 ? decode(parts[1]) : "" }
    }
    return result
}

final class WSConnection: @unchecked Sendable {
    static let maxMessageBytes = 1 << 20      // as the reference server's max_size
    static let maxQueuedBytes = 4 << 20       // unread messages past this pause reading from the socket
    static let requestDeadline: TimeInterval = 10
    nonisolated(unsafe) static var pingInterval: TimeInterval = 20  // set once at startup
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    let id: Int
    private let conn: NWConnection
    private let queue: DispatchQueue

    // Confined to `queue`.
    private var buffer = Data()
    private var inbox: [WSMessage] = []
    private var inboxBytes = 0
    private var waiter: CheckedContinuation<WSMessage?, Never>?
    private var ended = false          // no more messages will arrive
    private var closeSent = false
    private var paused = false         // reading stopped until the inbox drains
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var inFragment = false
    private var requestDone = false
    private var pingSentAt: Date?
    private var pinger: DispatchSourceTimer?
    private var cancelled = false

    init(id: Int, connection: NWConnection) {
        self.id = id
        self.conn = connection
        self.queue = DispatchQueue(label: "ws.\(id)")
    }

    // MARK: Lifetime

    /// Start the socket; it is cancelled if no whole request head arrives within `requestDeadline`.
    func start() {
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: endInbox(); stopPinger()
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [self] in
            if !requestDone { cancelNow() }
        }
    }

    /// Drop the TCP connection now (whatever state it is in).
    func cancel() {
        queue.async { self.cancelNow() }
    }

    private func cancelNow() {
        guard !cancelled else { return }
        cancelled = true
        endInbox()
        stopPinger()
        conn.cancel()
    }

    private func endInbox() {
        ended = true
        if let waiter, inbox.isEmpty {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    // MARK: HTTP

    /// Read the HTTP request head (nil if it is malformed, too big, late, or the peer left).
    func readRequest() async -> HTTPRequest? {
        while true {
            if let head = await onQueue({ () -> String?? in
                guard let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    return self.buffer.count > 16 * 1024 ? .some(nil) : nil
                }
                let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                self.buffer.removeSubrange(..<end.upperBound)
                self.requestDone = true
                return .some(head)
            }) {
                return head.flatMap(Self.parse)
            }
            guard let chunk = await receiveChunk() else { return nil }
            await onQueue { self.buffer.append(chunk) }
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: body()) } }
    }

    private static func parse(_ head: String) -> HTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let (path, query) = target.firstIndex(of: "?").map { (String(target[..<$0]), String(target[target.index(after: $0)...])) }
            ?? (target, "")
        return HTTPRequest(method: String(parts[0]), path: path.removingPercentEncoding ?? path,
                           query: parseQuery(query), headers: headers)
    }

    /// Answer a plain HTTP request and close.
    func respond(status: String, json: String) async {
        let body = Data(json.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        await write(Data(head.utf8) + body)
        cancel()
    }

    /// Complete the handshake. Afterwards `receive` yields the client's messages until it closes or leaves.
    func upgrade(_ request: HTTPRequest) async -> Bool {
        guard request.headers["upgrade"]?.lowercased() == "websocket", let key = request.headers["sec-websocket-key"] else {
            await respond(status: "400 Bad Request", json: #"{"error":"expected a WebSocket upgrade"}"#)
            return false
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))).base64EncodedString()
        await write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        queue.async { [self] in
            startPinger()
            drainFrames()
        }
        return true
    }

    // MARK: Reading

    private func receiveChunk() async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    done.resume(returning: data)
                } else if isComplete || error != nil {
                    done.resume(returning: nil)
                } else {
                    done.resume(returning: Data())
                }
            }
        }
    }

    /// The client's next message, or nil once it has closed or left.
    func receive() async -> WSMessage? {
        await withCheckedContinuation { (done: CheckedContinuation<WSMessage?, Never>) in
            queue.async { [self] in
                if !inbox.isEmpty {
                    done.resume(returning: pop())
                } else if ended {
                    done.resume(returning: nil)
                } else {
                    waiter = done
                }
            }
        }
    }

    private func pop() -> WSMessage {
        let message = inbox.removeFirst()
        inboxBytes -= Self.size(message)
        if paused && inboxBytes < Self.maxQueuedBytes / 2 {
            paused = false
            drainFrames()
        }
        return message
    }

    private static func size(_ message: WSMessage) -> Int {
        switch message {
        case .text(let s): return s.utf8.count
        case .binary(let d): return d.count
        }
    }

    private func deliver(_ message: WSMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
            return
        }
        inbox.append(message)
        inboxBytes += Self.size(message)
    }

    /// On `queue`: parse what is buffered, then wait for more (unless the inbox is full).
    private func drainFrames() {
        while true {
            guard let more = parseFrame() else { break }
            if !more { return }
        }
        if cancelled { return }
        if inboxBytes > Self.maxQueuedBytes { paused = true; return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { buffer.append(data) }
            if (isComplete || error != nil) && (data?.isEmpty ?? true) {
                cancelNow()
                return
            }
            drainFrames()
        }
    }

    private static func validCloseCode(_ code: UInt16) -> Bool {
        [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011].contains(code) || (3000...4999).contains(code)
    }

    /// One frame from `buffer`: nil when incomplete, false when reading must stop, true to continue.
    private func parseFrame() -> Bool? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let rsv = bytes[0] & 0x70
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        let isControl = opcode & 0x8 != 0
        if rsv != 0 { return fail(1002, "reserved bits set") }
        if !masked { return fail(1002, "client frames must be masked") }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if isControl && (length > 125 || !fin) { return fail(1002, "bad control frame") }
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for i in 2..<10 { value = value << 8 | UInt64(bytes[i]) }
            guard value <= UInt64(Self.maxMessageBytes) else { return fail(1009, "message too big") }
            length = Int(value)
            offset = 10
        }
        if length > Self.maxMessageBytes { return fail(1009, "message too big") }
        let maskOffset = offset
        offset += 4
        guard buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex
        var payload = Data(buffer[(start + offset)..<(start + offset + length)])
        let mask = [UInt8](buffer[(start + maskOffset)..<(start + maskOffset + 4)])
        payload.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<p.count { p[i] ^= mask[i & 3] }
        }
        buffer.removeSubrange(start..<(start + offset + length))
        switch opcode {
        case 0x0, 0x1, 0x2:
            if opcode == 0 && !inFragment { return fail(1002, "continuation without a message") }
            if opcode != 0 && inFragment { return fail(1002, "new message inside a fragmented one") }
            if opcode != 0 { fragments = Data(); fragmentOpcode = opcode; inFragment = true }
            fragments.append(payload)
            if fragments.count > Self.maxMessageBytes { return fail(1009, "message too big") }
            if fin {
                inFragment = false
                let data = fragments
                fragments = Data()
                if closeSent { return true }  // closing: only the peer's close matters now
                if fragmentOpcode == 0x1 {
                    guard let text = String(validating: data, as: UTF8.self) else { return fail(1007, "invalid UTF-8") }
                    deliver(.text(text))
                } else {
                    deliver(.binary(data))
                }
            }
        case 0x8:  // close: answer it (unless ours went first), then hang up
            var code: UInt16 = 1000
            if payload.count == 1 { return fail(1002, "bad close frame") }
            if payload.count >= 2 {
                code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                if !Self.validCloseCode(code) { return fail(1002, "bad close code") }
                if String(validating: payload.dropFirst(2), as: UTF8.self) == nil { return fail(1007, "invalid UTF-8") }
            }
            endInbox()
            if closeSent {
                cancelNow()
            } else {
                sendClose(code: code, reason: "")
            }
            return false
        case 0x9:
            if !closeSent { sendFrame(opcode: 0xA, payload: payload) }
        case 0xA:
            pingSentAt = nil
        default:
            return fail(1002, "bad opcode")
        }
        return true
    }

    private func fail(_ code: UInt16, _ reason: String) -> Bool {
        log("ws #\(id) protocol error: \(reason)")
        endInbox()
        sendClose(code: code, reason: reason)
        return false
    }

    // MARK: Keepalive

    /// Ping every `pingInterval`; a peer that has not answered the last ping by the next one is gone.
    private func startPinger() {
        guard Self.pingInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [self] in
            if pingSentAt != nil {
                log("ws #\(id) no pong within \(Int(Self.pingInterval)) s; dropping the connection")
                cancelNow()
                return
            }
            if closeSent || ended { return }
            pingSentAt = Date()
            sendFrame(opcode: 0x9, payload: Data("claub".utf8))
        }
        timer.resume()
        pinger = timer
    }

    private func stopPinger() {
        pinger?.cancel()
        pinger = nil
    }

    // MARK: Writing

    private func write(_ data: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in done.resume() })
        }
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var head: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            head.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            head += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            head.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { head.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        return Data(head) + payload
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        conn.send(content: Self.frame(opcode: opcode, payload: payload), completion: .contentProcessed { _ in })
    }

    struct Closed: Error {}

    /// Send one message once the socket took it; throws `Closed` once either side has closed.
    func send(_ message: WSMessage) async throws {
        let data: Data
        switch message {
        case .text(let text): data = Self.frame(opcode: 0x1, payload: Data(text.utf8))
        case .binary(let bytes): data = Self.frame(opcode: 0x2, payload: bytes)
        }
        let sent = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard !closeSent, !ended, !cancelled else { return done.resume(returning: false) }
                conn.send(content: data, completion: .contentProcessed { error in done.resume(returning: error == nil) })
            }
        }
        if !sent { throw Closed() }
    }

    func sendJSON(_ object: [String: any Sendable]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await send(.text(String(decoding: data, as: UTF8.self)))
    }

    /// Like `sendJSON`, for messages after which nothing more matters (errors).
    func trySendJSON(_ object: [String: any Sendable]) async {
        try? await sendJSON(object)
    }

    private func sendClose(code: UInt16, reason: String) {
        guard !closeSent, !cancelled else { return }
        closeSent = true
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(120)))
        sendFrame(opcode: 0x8, payload: payload)
        if ended {  // the peer closed first: this was the answer
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { [self] _ in cancelNow() })
            return
        }
        // Give the peer a moment to answer with its close, then drop the TCP connection.
        queue.asyncAfter(deadline: .now() + 2) { [self] in cancelNow() }
    }

    /// Close the WebSocket: the client's own close (or 2 s) then ends the TCP connection.
    func close(code: UInt16 = 1000, reason: String = "") {
        queue.async { self.sendClose(code: code, reason: reason) }
    }
}
