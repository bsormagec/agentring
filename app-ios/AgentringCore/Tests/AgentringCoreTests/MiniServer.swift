import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny HTTP/1.1 + WebSocket server on 127.0.0.1 for tests, in the spirit of OkHttp's
/// MockWebServer: enqueue replies, make requests, then take the recorded requests.
/// POSIX sockets only, so it runs on macOS and Linux without dependencies.
final class MiniServer: @unchecked Sendable {
    struct Request {
        let method: String
        /// Path with the query string, e.g. `/v1/ws?after_seq=3`.
        let path: String
        /// Lower-cased header names.
        let headers: [String: String]
        let body: Data

        var bodyString: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var bodyJson: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    enum WsAction {
        case send(String)
        case close(code: UInt16, reason: String)
        case sleep(TimeInterval)
    }

    enum Reply {
        case http(status: Int, body: String = "", headers: [String: String] = [:])
        /// Upgrades and runs the actions; then answers pings and waits for the client's close.
        case webSocket([WsAction])
        /// Never answers (until shutdown).
        case hang
    }

    private let lock = NSLock()
    private let cond = NSCondition()
    private var replies: [Reply] = []
    private var requests: [Request] = []
    private var clients: [Int32] = []
    private var running = true
    private let listenFd: Int32
    let port: UInt16

    var url: String { "http://127.0.0.1:\(port)" }

    init() {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        precondition(fd >= 0, "socket() failed")
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0, "bind() failed")
        precondition(listen(fd, 16) == 0, "listen() failed")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFd = fd
        port = UInt16(bigEndian: addr.sin_port)
        let t = Thread { [self] in acceptLoop() }
        t.start()
    }

    deinit { shutdown() }

    func enqueue(_ reply: Reply) {
        lock.lock()
        replies.append(reply)
        lock.unlock()
    }

    /// The next recorded request, in arrival order; nil after `timeout`.
    func takeRequest(timeout: TimeInterval = 5) -> Request? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while requests.isEmpty {
            if !cond.wait(until: deadline) { return nil }
        }
        return requests.removeFirst()
    }

    func shutdown() {
        lock.lock()
        let wasRunning = running
        running = false
        let fds = clients
        clients = []
        lock.unlock()
        guard wasRunning else { return }
        for fd in fds { _ = close(fd) }
        _ = close(listenFd)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            guard Self.waitReadable(listenFd, ms: 50) else { continue }
            let fd = accept(listenFd, nil, nil)
            if fd < 0 { continue }
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            lock.lock()
            clients.append(fd)
            lock.unlock()
            let t = Thread { [self] in serve(Connection(fd: fd, server: self)) }
            t.start()
        }
    }

    private func nextReply() -> Reply {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? .http(status: 500, body: "no reply enqueued") : replies.removeFirst()
    }

    private func record(_ r: Request) {
        cond.lock()
        requests.append(r)
        cond.broadcast()
        cond.unlock()
    }

    // MARK: Connection handling

    final class Connection {
        let fd: Int32
        unowned let server: MiniServer
        var buffer = [UInt8]()

        init(fd: Int32, server: MiniServer) {
            self.fd = fd
            self.server = server
        }

        /// Reads more bytes into the buffer; false on EOF, error or shutdown.
        func fill() -> Bool {
            while server.isRunning {
                guard MiniServer.waitReadable(fd, ms: 50) else { continue }
                var chunk = [UInt8](repeating: 0, count: 16384)
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { return false }
                buffer += chunk[0..<n]
                return true
            }
            return false
        }

        func read(_ count: Int) -> [UInt8]? {
            while buffer.count < count { if !fill() { return nil } }
            let out = Array(buffer[0..<count])
            buffer.removeFirst(count)
            return out
        }

        func write(_ bytes: [UInt8]) {
            var off = 0
            while off < bytes.count {
                #if canImport(Glibc)
                let flags = Int32(MSG_NOSIGNAL)
                #else
                let flags: Int32 = 0
                #endif
                let n = bytes[off...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func serve(_ c: Connection) {
        defer {
            lock.lock()
            if let i = clients.firstIndex(of: c.fd) {
                clients.remove(at: i)
                _ = close(c.fd)
            }
            lock.unlock()
        }
        while let req = readRequest(c) {
            record(req)
            switch nextReply() {
            case .http(let status, let body, let headers):
                var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
                let bytes = Array(body.utf8)
                var h = headers
                if status != 204 {
                    h["Content-Length"] = "\(bytes.count)"
                    if h["Content-Type"] == nil, !bytes.isEmpty { h["Content-Type"] = "application/json" }
                }
                for (k, v) in h { head += "\(k): \(v)\r\n" }
                head += "\r\n"
                c.write(Array(head.utf8) + (status == 204 ? [] : bytes))
            case .webSocket(let actions):
                guard let key = req.header("Sec-WebSocket-Key") else { return }
                let accept = Data(SHA1.hash(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                c.write(Array((
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
                ).utf8))
                runWebSocket(c, actions)
                return
            case .hang:
                while isRunning { Thread.sleep(forTimeInterval: 0.05) }
                return
            }
        }
    }

    private func readRequest(_ c: Connection) -> Request? {
        let marker: [UInt8] = [13, 10, 13, 10]
        var headEnd: Int?
        while headEnd == nil {
            if c.buffer.count >= 4 {
                for i in 0...(c.buffer.count - 4) where Array(c.buffer[i..<i + 4]) == marker {
                    headEnd = i
                    break
                }
            }
            if headEnd == nil, !c.fill() { return nil }
        }
        let head = String(decoding: c.buffer[0..<headEnd!], as: UTF8.self)
        c.buffer.removeFirst(headEnd! + 4)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard let body = c.read(length) else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body))
    }

    private func runWebSocket(_ c: Connection, _ actions: [WsAction]) {
        for action in actions {
            switch action {
            case .send(let text):
                c.write(Self.frame(opcode: 0x1, payload: Array(text.utf8)))
            case .close(let code, let reason):
                c.write(Self.frame(opcode: 0x8, payload: [UInt8(code >> 8), UInt8(code & 0xff)] + Array(reason.utf8)))
                // Wait briefly for the client's close, then drop the connection.
                _ = readFrames(c, until: Date().addingTimeInterval(2))
                return
            case .sleep(let s):
                Thread.sleep(forTimeInterval: s)
            }
        }
        _ = readFrames(c, until: .distantFuture)
    }

    /// Answers pings and returns when the client closes (or the deadline / shutdown).
    private func readFrames(_ c: Connection, until deadline: Date) -> Bool {
        while Date() < deadline && isRunning {
            if c.buffer.count < 2, !Self.waitReadable(c.fd, ms: 50) { continue }
            guard let h = c.read(2) else { return false }
            let opcode = h[0] & 0x0f
            let masked = h[1] & 0x80 != 0
            var len = Int(h[1] & 0x7f)
            if len == 126 {
                guard let b = c.read(2) else { return false }
                len = Int(b[0]) << 8 | Int(b[1])
            } else if len == 127 {
                guard let b = c.read(8) else { return false }
                len = b.reduce(0) { $0 << 8 | Int($1) }
            }
            let mask = masked ? (c.read(4) ?? [0, 0, 0, 0]) : [0, 0, 0, 0]
            guard var payload = c.read(len) else { return false }
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            switch opcode {
            case 0x8:
                c.write(Self.frame(opcode: 0x8, payload: Array(payload.prefix(2))))
                return true
            case 0x9:
                c.write(Self.frame(opcode: 0xA, payload: payload))
            default:
                break
            }
        }
        return false
    }

    static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            out += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8(truncatingIfNeeded: payload.count >> (i * 8))) }
        }
        return out + payload
    }

    static func waitReadable(_ fd: Int32, ms: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, ms) > 0
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 401: return "Unauthorized"
        case 409: return "Conflict"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// SHA-1, only for the WebSocket handshake of the test server.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt32($0) * 8)) } }
    }
}
