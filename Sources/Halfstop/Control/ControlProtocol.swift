import Foundation

/// The MCP side of local AI control: JSON-RPC 2.0 over Streamable HTTP, answered with one JSON
/// reply per request (no event streams, no sessions). Written against MCP revision 2026-07-28,
/// which is stateless (every request carries its version in `_meta`), and also serving the
/// handshake-based revisions 2025-03-26 to 2025-11-25 that most clients still speak
/// (`initialize` first), as the 2026-07-28 "dual-era" rules allow.
enum MCP {
    /// The stateless revision: version, client info and capabilities travel with each request.
    static let modernVersion = "2026-07-28"
    /// Handshake revisions, newest first. An `initialize` asking for anything else gets the newest.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static var supportedVersions: [String] { [modernVersion] + legacyVersions }

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    // JSON-RPC and MCP error codes.
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let headerMismatch = -32020
    static let unsupportedVersion = -32022

    static var serverInfo: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return ["name": "halfstop", "title": "Halfstop", "version": .string(version)]
    }

    static let instructions = """
    Halfstop is a photo editor on this Mac. These tools read and edit the photo the user has open in \
    Halfstop's editor, and nothing else: no files, no other photos. Start with get_photo and \
    get_adjustments (and get_preview to look at it). Each change you make is one undoable step in the \
    photo's history, which the user sees and can step back through; prefer small, explained changes \
    and give set_adjustments a short label. Edits never modify the photo file itself.
    """
}

/// What a tool call produced.
struct ToolResult: Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case text(String)
        case image(Data, mimeType: String)
    }
    var content: [Content]
    var structured: JSONValue?
    var isError = false

    static func error(_ message: String) -> ToolResult { ToolResult(content: [.text(message)], isError: true) }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "content": .array(content.map {
                switch $0 {
                case .text(let t): ["type": "text", "text": .string(t)]
                case .image(let d, let mime): ["type": "image", "data": .string(d.base64EncodedString()), "mimeType": .string(mime)]
                }
            }),
            "isError": .bool(isError),
        ]
        if let structured { o["structuredContent"] = structured }
        return .object(o)
    }
}

/// Runs the tools (on the photo open in the editor). The self-test can swap in its own.
protocol ControlToolRunner: Sendable {
    /// Tool definitions in a fixed order.
    var tools: [JSONValue] { get }
    func knows(_ name: String) -> Bool
    func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult
}

/// Turns one HTTP request into one HTTP reply.
struct MCPEndpoint: Sendable {
    let gate: ControlGate
    let runner: ControlToolRunner

    /// Bytes in, reply out: for the self-test (the server feeds the parser itself).
    func respond(raw: Data) async -> HTTPResponse {
        var parser = HTTPRequestParser()
        parser.append(raw)
        while true {
            switch parser.next() {
            case .needMore: return HTTPRequestParser.plain(400)   // the test gave an incomplete request
            case .reject(let r): return r
            case .head(let h): if let r = gate.screen(h) { return r }
            case .request(let req): return await respond(req)
            }
        }
    }

    func respond(_ request: HTTPRequest) async -> HTTPResponse {
        if let refusal = gate.screen(request.head) { return refusal }
        let message: JSONValue
        switch JSONValue.parse(request.body) {
        case .failure(.tooDeep): return Self.error(400, id: nil, MCP.invalidRequest, "JSON nested too deeply")
        case .failure: return Self.error(400, id: nil, MCP.parseError, "Parse error: the body isn't valid JSON")
        case .success(let v): message = v
        }
        guard case .object(let m) = message else {
            return Self.error(400, id: nil, MCP.invalidRequest,
                              message.arrayValue != nil ? "Batches aren't supported: send one message per request" : "Expected a JSON-RPC object")
        }
        guard m["jsonrpc"] == "2.0" else { return Self.error(400, id: nil, MCP.invalidRequest, "Expected \"jsonrpc\": \"2.0\"") }
        // A reply to a server request: this server never asks the client anything, so accept and drop it.
        if m["method"] == nil, m["id"] != nil, m["result"] != nil || m["error"] != nil { return HTTPResponse(status: 202) }
        guard case .string(let method) = m["method"], !method.isEmpty, method.count <= 128 else {
            return Self.error(400, id: nil, MCP.invalidRequest, "Expected a method name")
        }
        var id: JSONValue?
        if let raw = m["id"] {
            switch raw {
            case .string(let s) where s.count <= 256: id = raw
            case .int: id = raw
            default: return Self.error(400, id: nil, MCP.invalidRequest, "The id must be a string or an integer")
            }
        }
        let params: [String: JSONValue]
        switch m["params"] {
        case nil: params = [:]
        case .object(let p)?: params = p
        default: return Self.error(400, id: id, MCP.invalidParams, "params must be an object")
        }
        // Notifications (initialized, cancelled…) need no reply.
        guard let id else { return HTTPResponse(status: 202) }

        if let meta = params["_meta"]?.objectValue, let version = meta[MCP.versionKey] {
            return await modern(request.head, id: id, method: method, params: params, meta: meta, version: version)
        }
        return await legacy(request.head, id: id, method: method, params: params)
    }

    // MARK: Stateless revision (2026-07-28)

    private func modern(_ head: HTTPHead, id: JSONValue, method: String, params: [String: JSONValue],
                        meta: [String: JSONValue], version: JSONValue) async -> HTTPResponse {
        guard case .string(let v) = version else {
            return Self.error(400, id: id, MCP.invalidParams, "\(MCP.versionKey) must be a string")
        }
        guard let header = head.header("MCP-Protocol-Version") else {
            return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: the MCP-Protocol-Version header is missing")
        }
        guard header == v else {
            return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: MCP-Protocol-Version header '\(header)' doesn't match the request's '\(v)'")
        }
        guard v == MCP.modernVersion else {
            return Self.error(400, id: id, MCP.unsupportedVersion, "Unsupported protocol version",
                              data: ["supported": .array(MCP.supportedVersions.map { .string($0) }), "requested": .string(v)])
        }
        guard meta[MCP.capabilitiesKey]?.objectValue != nil else {
            return Self.error(400, id: id, MCP.invalidParams, "Invalid params: _meta must include \(MCP.capabilitiesKey)")
        }
        guard let mcpMethod = head.header("Mcp-Method") else {
            return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: the Mcp-Method header is missing")
        }
        guard mcpMethod == method else {
            return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: Mcp-Method header '\(mcpMethod)' doesn't match the body's '\(method)'")
        }
        switch method {
        case "server/discover":
            return Self.result(id: id, modern: true, [
                "supportedVersions": .array(MCP.supportedVersions.map { .string($0) }),
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": .string(MCP.instructions),
                "ttlMs": 300_000, "cacheScope": "public",
            ])
        case "tools/list":
            return Self.result(id: id, modern: true, ["tools": .array(runner.tools), "ttlMs": 300_000, "cacheScope": "public"])
        case "tools/call":
            if let name = params["name"]?.stringValue {
                guard let sent = head.header("Mcp-Name") else {
                    return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: the Mcp-Name header is missing")
                }
                guard Self.decodeHeaderValue(sent) == name else {
                    return Self.error(400, id: id, MCP.headerMismatch, "Header mismatch: Mcp-Name header doesn't match the tool name in the body")
                }
            }
            return await callTool(id: id, params: params, modern: true)
        default:
            return Self.error(404, id: id, MCP.methodNotFound, "Method not found: \(method)")
        }
    }

    /// `=?base64?…?=` header values carry names that aren't plain ASCII.
    static func decodeHeaderValue(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="), value.count >= 11 else { return value }
        let inner = String(value.dropFirst(9).dropLast(2))
        guard let data = Data(base64Encoded: inner) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Handshake revisions (2025-03-26 to 2025-11-25)

    private func legacy(_ head: HTTPHead, id: JSONValue, method: String, params: [String: JSONValue]) async -> HTTPResponse {
        if let header = head.header("MCP-Protocol-Version"), method != "initialize" {
            if header == MCP.modernVersion {
                return Self.error(400, id: id, MCP.invalidParams, "Invalid params: requests for \(MCP.modernVersion) must carry _meta.\(MCP.versionKey)")
            }
            guard MCP.legacyVersions.contains(header) else {
                return Self.error(400, id: id, MCP.unsupportedVersion, "Unsupported protocol version",
                                  data: ["supported": .array(MCP.supportedVersions.map { .string($0) }), "requested": .string(header)])
            }
        }
        switch method {
        case "initialize":
            guard case .string(let asked)? = params["protocolVersion"] else {
                return Self.error(200, id: id, MCP.invalidParams, "Invalid params: initialize needs protocolVersion")
            }
            let version = MCP.legacyVersions.contains(asked) ? asked : MCP.legacyVersions[0]
            return Self.result(id: id, modern: false, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": MCP.serverInfo,
                "instructions": .string(MCP.instructions),
            ])
        case "ping":
            return Self.result(id: id, modern: false, [:])
        case "tools/list":
            return Self.result(id: id, modern: false, ["tools": .array(runner.tools)])
        case "tools/call":
            return await callTool(id: id, params: params, modern: false)
        default:
            // Not 404 here: to a handshake-era client, 404 means "your session is gone".
            return Self.error(200, id: id, MCP.methodNotFound, "Method not found: \(method)")
        }
    }

    // MARK: Tools

    private func callTool(id: JSONValue, params: [String: JSONValue], modern: Bool) async -> HTTPResponse {
        guard case .string(let name)? = params["name"] else {
            return Self.error(modern ? 400 : 200, id: id, MCP.invalidParams, "Invalid params: tools/call needs a tool name")
        }
        guard runner.knows(name) else {
            return Self.error(200, id: id, MCP.invalidParams, "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let a)?: arguments = a
        default: return Self.error(200, id: id, MCP.invalidParams, "Invalid params: arguments must be an object")
        }
        let result = await runner.call(name, arguments: arguments)
        guard case .object(let o) = result.json else { return Self.error(500, id: id, MCP.internalError, "Internal error") }
        return Self.result(id: id, modern: modern, o)
    }

    // MARK: Replies

    static func result(id: JSONValue, modern: Bool, _ fields: [String: JSONValue]) -> HTTPResponse {
        var r = fields
        if modern {
            r["resultType"] = "complete"
            r["_meta"] = .object([MCP.serverInfoKey: MCP.serverInfo])
        }
        return .json(200, JSONValue.object(["jsonrpc": "2.0", "id": id, "result": .object(r)]).encoded())
    }

    static func error(_ status: Int, id: JSONValue?, _ code: Int, _ message: String, data: JSONValue? = nil) -> HTTPResponse {
        var e: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { e["data"] = data }
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "error": .object(e)]
        if let id { o["id"] = id }
        return .json(status, JSONValue.object(o).encoded())
    }
}
