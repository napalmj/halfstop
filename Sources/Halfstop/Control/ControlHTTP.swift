import Foundation

// The small, strict HTTP/1.1 subset the local AI control server speaks: one request per
// connection, a Content-Length body (no chunked encoding), and one reply, after which the
// connection closes. Everything here is pure, so the self-test can drive it without sockets.

struct HTTPHead: Sendable {
    var method: String
    var target: String
    var version: String
    /// In arrival order; look them up with `header(_:)` (names are case-insensitive).
    var headers: [(name: String, value: String)]

    /// The value of a header that may appear once (nil when absent).
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func count(_ name: String) -> Int {
        headers.reduce(0) { $0 + ($1.name.caseInsensitiveCompare(name) == .orderedSame ? 1 : 0) }
    }

    /// `Expect: 100-continue` (curl sends it for larger bodies and waits for the go-ahead).
    var expectsContinue: Bool { header("Expect")?.lowercased() == "100-continue" }
}

struct HTTPRequest: Sendable {
    var head: HTTPHead
    var body: Data
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// The bytes on the wire. Every reply closes the connection and is never cached.
    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        for key in all.keys.sorted() { lines.append("\(key): \(all[key]!)") }
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(body)
        return out
    }

    static let continueLine = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status"
        }
    }
}

extension HTTPResponse: Error {}

/// Reads one request from bytes that may arrive in any number of pieces.
struct HTTPRequestParser {
    /// Request line plus headers.
    static let maxHeadBytes = 16 * 1024
    static let maxHeaderCount = 64
    /// MCP messages are small: a whole request is a few kilobytes.
    static let maxBodyBytes = 1 << 20

    enum Event {
        /// Waiting for more bytes.
        case needMore
        /// The head is complete (returned once): screen it before reading the body.
        case head(HTTPHead)
        /// The whole request is in.
        case request(HTTPRequest)
        /// Malformed or over a limit: send this and close.
        case reject(HTTPResponse)
    }

    private enum State { case head, body(HTTPHead, Int), done }
    private var state = State.head
    private var buffer = Data()

    mutating func append(_ data: Data) {
        if case .done = state { return }
        buffer.append(data)
    }

    /// The next thing that happened; call it again after `.head` (the body may already be here).
    mutating func next() -> Event {
        switch state {
        case .done:
            return .needMore
        case .head:
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeadBytes { return finish(.reject(Self.plain(431))) }
                return .needMore
            }
            if end.lowerBound > Self.maxHeadBytes { return finish(.reject(Self.plain(431))) }
            switch Self.parseHead(buffer[buffer.startIndex..<end.lowerBound]) {
            case .failure(let response):
                return finish(.reject(response))
            case .success(let (head, length)):
                buffer = Data(buffer[end.upperBound...])
                state = .body(head, length)
                return .head(head)
            }
        case .body(let head, let length):
            guard buffer.count >= length else { return .needMore }
            // Anything after the body (a pipelined request) is ignored: the connection closes.
            let body = Data(buffer.prefix(length))
            return finish(.request(HTTPRequest(head: head, body: body)))
        }
    }

    private mutating func finish(_ e: Event) -> Event {
        state = .done
        buffer = Data()
        return e
    }

    static func plain(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data((HTTPResponse.reason(status) + "\n").utf8))
    }

    private static let tokenChars = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)

    static func isToken(_ s: Substring) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { tokenChars.contains($0) }
    }

    /// Parses the request line and headers; the Int is the body length.
    static func parseHead(_ bytes: Data) -> Result<(HTTPHead, Int), HTTPResponse> {
        // Visible ASCII, spaces, tabs and line breaks only: no obs-text, no NULs.
        guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii) else { return .failure(plain(400)) }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(parts[0]), parts[1].hasPrefix("/") || parts[1] == "*",
              !parts[1].contains(where: { $0 == "\t" }) else { return .failure(plain(400)) }
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(version.hasPrefix("HTTP/") ? plain(505) : plain(400))
        }
        guard lines.count <= maxHeaderCount else { return .failure(plain(431)) }
        var headers: [(String, String)] = []
        for line in lines {
            // Folded lines, bare CR/LF and empty names are all malformed.
            guard let colon = line.firstIndex(of: ":"), !line.contains("\r"), !line.contains("\n") else { return .failure(plain(400)) }
            let name = line[..<colon]
            guard isToken(name) else { return .failure(plain(400)) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((String(name), value))
        }
        let head = HTTPHead(method: String(parts[0]), target: String(parts[1]), version: version, headers: headers)
        // Ambiguity is how requests get smuggled: these may appear at most once.
        for name in ["Host", "Content-Length", "Authorization", "Origin", "Content-Type", "MCP-Protocol-Version", "Mcp-Method", "Mcp-Name"]
            where head.count(name) > 1 {
            return .failure(plain(400))
        }
        if head.header("Transfer-Encoding") != nil { return .failure(plain(501)) }
        var length = 0
        if let raw = head.header("Content-Length") {
            guard !raw.isEmpty, raw.count <= 10, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let n = Int(raw) else {
                return .failure(plain(400))
            }
            guard n <= maxBodyBytes else { return .failure(plain(413)) }
            length = n
        } else if head.method == "POST" {
            return .failure(plain(411))
        }
        return .success((head, length))
    }
}

// MARK: - Who may talk to the server

/// The checks every request passes before its body is even read: loopback Host only, no
/// foreign Origin (DNS rebinding), and the bearer token.
struct ControlGate: Sendable {
    let port: Int
    let token: ControlTokenBox

    /// nil when the request may proceed; otherwise the reply to send.
    func screen(_ head: HTTPHead) -> HTTPResponse? {
        guard head.count("Host") == 1, let host = head.header("Host"), allowedHost(host) else {
            return Self.refuse(403, "Forbidden: this server only answers requests addressed to 127.0.0.1:\(port)")
        }
        if head.count("Origin") > 0 {
            guard let origin = head.header("Origin"), Self.allowedOrigin(origin) else {
                return Self.refuse(403, "Forbidden: requests from web pages are not accepted")
            }
        }
        guard let auth = head.header("Authorization"), let presented = Self.bearer(auth), token.matches(presented) else {
            var r = Self.refuse(401, "Unauthorized: send the token from Halfstop's Settings as \"Authorization: Bearer <token>\"")
            r.headers["WWW-Authenticate"] = "Bearer realm=\"Halfstop\""
            return r
        }
        let path = head.target
        guard path == "/mcp" else { return Self.refuse(404, "Not found: the MCP endpoint is /mcp") }
        guard head.method == "POST" else {
            // No server-sent event stream and no sessions to end: POST is the only method.
            var r = Self.refuse(405, "Method not allowed: use POST")
            r.headers["Allow"] = "POST"
            return r
        }
        guard let type = head.header("Content-Type"),
              type.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return Self.refuse(415, "Unsupported media type: send application/json")
        }
        if let accept = head.header("Accept")?.lowercased() {
            let types = accept.split(separator: ",").map { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "" }
            guard types.contains(where: { $0 == "application/json" || $0 == "application/*" || $0 == "*/*" }) else {
                return Self.refuse(406, "Not acceptable: this server answers with application/json")
            }
        }
        return nil
    }

    func allowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1:\(port)" || h == "localhost:\(port)"
    }

    /// Absent (checked by the caller) or a page served from this Mac itself.
    static func allowedOrigin(_ origin: String) -> Bool {
        guard let c = URLComponents(string: origin), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), host == "localhost" || host == "127.0.0.1",
              c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return false }
        return true
    }

    static func bearer(_ value: String) -> String? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let t = parts[1].trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// A refusal with a JSON-RPC error body that has no id (as the MCP transport allows).
    static func refuse(_ status: Int, _ message: String) -> HTTPResponse {
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "error": .object(["code": .int(-32600), "message": .string(message)])])
        return .json(status, body.encoded())
    }
}

/// The current token, shared between the settings (which can regenerate it) and the server.
final class ControlTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    init(_ token: String? = nil) { value = token.map { Data($0.utf8) } }

    func set(_ token: String?) {
        lock.lock(); value = token.map { Data($0.utf8) }; lock.unlock()
    }

    /// Constant time in the token's contents (and never true without a token).
    func matches(_ presented: String) -> Bool {
        lock.lock(); let expected = value; lock.unlock()
        guard let expected, !expected.isEmpty else { return false }
        return Self.constantTimeEqual(Data(presented.utf8), expected)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        // Walk the expected length whatever was presented, so timing says nothing about it.
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let aa = [UInt8](a), bb = [UInt8](b)
        for i in 0..<bb.count {
            diff |= (i < aa.count ? aa[i] : 0) ^ bb[i]
        }
        return diff == 0
    }
}
