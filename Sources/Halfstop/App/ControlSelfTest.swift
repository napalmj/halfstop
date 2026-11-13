import Foundation
import ImageIO
import Darwin
import Security

// MARK: - Local AI control (MCP)

extension LibraryTest {
    /// The MCP server: HTTP parsing and limits, the token / Host / Origin gate, JSON-RPC for both
    /// protocol eras, the tools against a real store, and one loopback round trip. Leaves the user's
    /// settings and Keychain alone (in-memory token, no defaults; the Keychain check uses its own
    /// item and deletes it).
    @MainActor
    static func controlChecks(store: LibraryStore, check: (String, Bool, String) -> Void) async {
        // Tokens
        let token = ControlToken.generate() ?? ""
        let urlSafe = token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        check("control: token is 256 random bits, base64url", token.count == 43 && urlSafe && ControlToken.generate() != token, token.isEmpty ? "none" : "")
        let box = ControlTokenBox(token)
        check("control: token comparison", box.matches(token) && !box.matches(token + "x") && !box.matches(String(token.dropLast()))
              && !box.matches("") && !ControlTokenBox().matches("") && !ControlTokenBox().matches(token), "")

        let tricky: JSONValue = ["s": "quote \" back \\ nl \n tab \t ctl \u{1} ls \u{2028} é 😀", "n": 0.1, "i": -3, "d": 1e-7, "a": [true, .null, 5.0]]
        let roundTrip = try? JSONValue.parse(tricky.encoded()).get()
        check("control: JSON encodes losslessly and compactly", roundTrip?["s"] == tricky["s"] && roundTrip?["n"] == 0.1 && roundTrip?["i"] == -3
              && roundTrip?["d"] == 1e-7 && JSONValue.double(0.1).text == "0.1" && JSONValue.number(-0.1, places: 2).text == "-0.1", tricky.text)

        // HTTP parsing: pieces of any size, and the limits.
        let port = 47615
        let gate = ControlGate(port: port, token: box)
        let endpoint = MCPEndpoint(gate: gate, runner: StoreToolRunner(store: store))
        func raw(method: String = "POST", path: String = "/mcp", host: String? = "127.0.0.1:\(port)", auth: String? = nil,
                 contentType: String? = "application/json", headers: [String] = [], body: String) -> Data {
            var lines = ["\(method) \(path) HTTP/1.1"]
            if let host { lines.append("Host: \(host)") }
            lines.append("Authorization: " + (auth ?? "Bearer \(token)"))
            if let contentType { lines.append("Content-Type: \(contentType)") }
            lines += ["Accept: application/json, text/event-stream", "Content-Length: \(body.utf8.count)"] + headers
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        var parser = HTTPRequestParser()
        var heads = 0
        var got: HTTPRequest?
        for byte in raw(body: ping) {
            parser.append(Data([byte]))
            loop: while true {
                switch parser.next() {
                case .needMore: break loop
                case .head: heads += 1
                case .request(let r): got = r; break loop
                case .reject: break loop
                }
            }
        }
        check("control: a request read one byte at a time", heads == 1 && got?.body == Data(ping.utf8) && got?.head.header("host") == "127.0.0.1:\(port)", "")
        func status(_ data: Data) async -> Int { await endpoint.respond(raw: data).status }
        func statuses(_ list: [Data]) async -> [Int] {
            var out: [Int] = []
            for d in list { out.append(await status(d)) }
            return out
        }
        let big = String(repeating: "a", count: HTTPRequestParser.maxBodyBytes + 1)
        let bigHead = HTTPRequestParser.parseHead(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: \(big.count)".utf8)).failureStatus
        let bigStatus = await status(raw(body: big))
        check("control: oversize body refused before reading it", bigHead == 413 && bigStatus == 413, "\(String(describing: bigHead)) \(bigStatus)")
        let longHead = "POST /mcp HTTP/1.1\r\nX-Pad: " + String(repeating: "p", count: HTTPRequestParser.maxHeadBytes) + "\r\n\r\n"
        let longStatus = await status(Data(longHead.utf8))
        check("control: oversize headers refused", longStatus == 431, "\(longStatus)")
        let malformed = await statuses([
            Data("POST /mcp\r\n\r\n".utf8),
            Data("POST /mcp HTTP/2.0\r\nHost: x\r\n\r\n".utf8),
            raw(headers: ["Content-Length: 5"], body: ping),
            raw(headers: ["Transfer-Encoding: chunked"], body: ping),
            Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\n\r\n".utf8),
            Data("POST /mcp HTTP/1.1\r\n Folded: yes\r\nContent-Length: 0\r\n\r\n".utf8),
        ])
        check("control: malformed HTTP refused", malformed == [400, 505, 400, 501, 411, 400], "\(malformed)")

        // The gate: token, Host, Origin, path, method, media type.
        let good = await status(raw(body: ping))
        check("control: a good request passes", good == 200, "\(good)")
        let noToken = await endpoint.respond(raw: raw(auth: "Bearer wrong", body: ping))
        let badAuth = await statuses([raw(auth: "Basic \(token)", body: ping), raw(auth: "Bearer", body: ping), raw(auth: "", body: ping)])
        check("control: bad or missing token refused", noToken.status == 401 && noToken.headers["WWW-Authenticate"] != nil
              && badAuth == [401, 401, 401], "\(noToken.status) \(badAuth)")
        let badHosts = await statuses(["evil.example:\(port)", "127.0.0.1:\(port + 1)", "127.0.0.1", "192.168.1.2:\(port)", "localhost.evil.example:\(port)"]
            .map { raw(host: $0, body: ping) } + [raw(host: nil, body: ping)])
        let localhost = await status(raw(host: "LOCALHOST:\(port)", body: ping))
        check("control: foreign Host refused (DNS rebinding)", badHosts.allSatisfy { $0 == 403 } && localhost == 200, "\(badHosts) \(localhost)")
        let badOrigins = await statuses(["https://evil.example", "null", "http://127.0.0.1.evil.example", "http://localhost@evil.example", "file://",
                                         "http://192.168.1.2:\(port)"].map { raw(headers: ["Origin: \($0)"], body: ping) })
        let goodOrigins = await statuses(["http://localhost:3000", "http://127.0.0.1:\(port)"].map { raw(headers: ["Origin: \($0)"], body: ping) })
        check("control: foreign Origin refused", badOrigins.allSatisfy { $0 == 403 } && goodOrigins == [200, 200], "\(badOrigins) \(goodOrigins)")
        let get = await endpoint.respond(raw: raw(method: "GET", body: ""))
        let others = await statuses([raw(method: "DELETE", body: ""), raw(path: "/other", body: ping), raw(path: "/mcp?x=1", body: ping),
                                     raw(contentType: "text/plain", body: ping), raw(contentType: nil, body: ping)])
        check("control: only POST /mcp with JSON", get.status == 405 && get.headers["Allow"] == "POST" && others == [405, 404, 404, 415, 415],
              "\(get.status) \(others)")

        // JSON-RPC, handshake era.
        func send(_ body: JSONValue, headers: [String] = []) async -> (Int, JSONValue?) {
            let r = await endpoint.respond(raw: raw(headers: headers, body: body.text))
            return (r.status, r.body.isEmpty ? nil : try? JSONValue.parse(r.body).get())
        }
        func rpc(_ method: String, _ params: JSONValue? = nil, id: JSONValue = 1, headers: [String] = []) async -> (Int, JSONValue?) {
            var m: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
            if let params { m["params"] = params }
            return await send(.object(m), headers: headers)
        }
        let (initStatus, initReply) = await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        check("control: initialize", initStatus == 200 && initReply?["id"] == 1 && initReply?["result"]?["protocolVersion"] == "2025-06-18"
              && initReply?["result"]?["capabilities"]?["tools"] != nil && initReply?["result"]?["serverInfo"]?["name"] == "halfstop", initReply?.text ?? "")
        let (_, oldInit) = await rpc("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:]])
        check("control: initialize offers its newest handshake version", oldInit?["result"]?["protocolVersion"] == .string(MCP.legacyVersions[0]), oldInit?.text ?? "")
        let note = await endpoint.respond(raw: raw(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        check("control: notifications get 202 and no body", note.status == 202 && note.body.isEmpty, "\(note.status)")
        let (listStatus, list) = await rpc("tools/list", headers: ["MCP-Protocol-Version: 2025-06-18"])
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        check("control: tools/list", listStatus == 200 && names == ControlTools.names
              && (list?["result"]?["tools"]?.arrayValue ?? []).allSatisfy { $0["inputSchema"]?["type"] == "object" && ($0["description"]?.stringValue?.count ?? 0) > 40 },
              names.joined(separator: ","))
        let (_, unknown) = await rpc("resources/list")
        let (badHeader, _) = await rpc("tools/list", headers: ["MCP-Protocol-Version: 1999-01-01"])
        let (_, idString) = await rpc("ping", id: "abc")
        check("control: JSON-RPC errors", unknown?["error"]?["code"] == .int(MCP.methodNotFound) && badHeader == 400
              && idString?["id"] == "abc" && idString?["result"] != nil, unknown?.text ?? "")
        let parseError = await endpoint.respond(raw: raw(body: "{nope"))
        let batch = await endpoint.respond(raw: raw(body: "[\(ping)]"))
        let nullID = await endpoint.respond(raw: raw(body: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        let deep = await endpoint.respond(raw: raw(body: String(repeating: "[", count: 200) + String(repeating: "]", count: 200)))
        let fractionalID = await rpc("ping", id: .double(1.5)).0
        check("control: malformed JSON-RPC refused", parseError.status == 400 && (try? JSONValue.parse(parseError.body).get())?["error"]?["code"] == .int(MCP.parseError)
              && batch.status == 400 && nullID.status == 400 && deep.status == 400 && fractionalID == 400,
              "\(parseError.status) \(batch.status) \(nullID.status) \(deep.status) \(fractionalID)")

        // JSON-RPC, stateless era (2026-07-28).
        let meta: JSONValue = [MCP.versionKey: .string(MCP.modernVersion), MCP.capabilitiesKey: [:], "io.modelcontextprotocol/clientInfo": ["name": "selftest", "version": "1"]]
        func modern(_ method: String, _ params: [String: JSONValue] = [:], meta m: JSONValue = meta, headers: [String]? = nil) async -> (Int, JSONValue?) {
            var p = params
            p["_meta"] = m
            var h = headers ?? ["MCP-Protocol-Version: \(MCP.modernVersion)", "Mcp-Method: \(method)"]
            if headers == nil, let name = params["name"]?.stringValue { h.append("Mcp-Name: \(name)") }
            return await rpc(method, .object(p), headers: h)
        }
        let (dStatus, discover) = await modern("server/discover")
        check("control: server/discover", dStatus == 200 && discover?["result"]?["resultType"] == "complete"
              && discover?["result"]?["supportedVersions"]?.arrayValue?.contains(.string(MCP.modernVersion)) == true
              && discover?["result"]?["capabilities"]?["tools"] != nil && discover?["result"]?["ttlMs"]?.intValue != nil, discover?.text ?? "")
        let (mlStatus, mlist) = await modern("tools/list")
        check("control: stateless tools/list", mlStatus == 200 && mlist?["result"]?["tools"]?.arrayValue?.count == ControlTools.names.count
              && mlist?["result"]?["cacheScope"] == "public" && mlist?["result"]?["_meta"]?[MCP.serverInfoKey] != nil, "")
        let (mismatch, mm) = await modern("tools/list", headers: ["MCP-Protocol-Version: 2025-11-25", "Mcp-Method: tools/list"])
        let (noMethod, _) = await modern("tools/list", headers: ["MCP-Protocol-Version: \(MCP.modernVersion)"])
        let (wrongName, _) = await modern("tools/call", ["name": "get_photo", "arguments": [:]],
                                          headers: ["MCP-Protocol-Version: \(MCP.modernVersion)", "Mcp-Method: tools/call", "Mcp-Name: undo"])
        let (encodedName, en) = await modern("tools/call", ["name": "get_adjustments", "arguments": [:]],
                                             headers: ["MCP-Protocol-Version: \(MCP.modernVersion)", "Mcp-Method: tools/call",
                                                       "Mcp-Name: =?base64?\(Data("get_adjustments".utf8).base64EncodedString())?="])
        check("control: stateless header checks", mismatch == 400 && mm?["error"]?["code"] == .int(MCP.headerMismatch) && noMethod == 400
              && wrongName == 400 && encodedName == 200 && en?["result"]?["resultType"] == "complete", "\(mismatch) \(noMethod) \(wrongName) \(encodedName)")
        let old: JSONValue = [MCP.versionKey: "1900-01-01", MCP.capabilitiesKey: [:]]
        let (unsupported, us) = await modern("tools/list", meta: old, headers: ["MCP-Protocol-Version: 1900-01-01", "Mcp-Method: tools/list"])
        let (noCaps, nc) = await modern("tools/list", meta: [MCP.versionKey: .string(MCP.modernVersion)])
        let (unknownModern, um) = await modern("prompts/list")
        check("control: stateless version and method errors", unsupported == 400 && us?["error"]?["code"] == .int(MCP.unsupportedVersion)
              && us?["error"]?["data"]?["supported"]?.arrayValue?.contains(.string(MCP.modernVersion)) == true
              && noCaps == 400 && nc?["error"]?["code"] == .int(MCP.invalidParams)
              && unknownModern == 404 && um?["error"]?["code"] == .int(MCP.methodNotFound), "")

        // Tools, on the store's photo.
        guard let photo = store.photos.first else { return check("control: a photo for the tool checks", false, "") }
        func tool(_ name: String, _ args: JSONValue = [:]) async -> JSONValue? {
            await rpc("tools/call", ["name": .string(name), "arguments": args]).1?["result"]
        }
        func text(_ r: JSONValue?) -> String { r?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: " ") ?? "" }
        store.mode = .library
        let closed = await tool("get_photo")
        check("control: no open photo is a clear tool error", closed?["isError"] == true && text(closed).contains("No photo is open"), text(closed))
        let (_, unknownTool) = await rpc("tools/call", ["name": "delete_everything", "arguments": [:]])
        check("control: unknown tool is a protocol error", unknownTool?["error"]?["code"] == .int(MCP.invalidParams), unknownTool?.text ?? "")

        store.mode = .edit
        store.select(photo)
        store.resetAdjustments()
        store.commitPending(photo)
        let info = await tool("get_photo")
        check("control: get_photo", info?["isError"] == false && info?["structuredContent"]?["file_name"] == .string(photo.name)
              && info?["structuredContent"]?["width"] == 600 && info?["structuredContent"]?["height"] == 400
              && info?["structuredContent"]?["analysis"]?["luminance_percentiles"]?["p50"]?.numberValue != nil
              && !(info.map { $0.text.contains(photo.url.deletingLastPathComponent().path) } ?? true), text(info).prefix(160).description)
        let current = await tool("get_adjustments")
        check("control: get_adjustments", current?["structuredContent"]?["values"]?["exposure"]?.numberValue == 0
              && current?["structuredContent"]?["values"]?.objectValue?.count == ControlTools.fields.count
              && current?["structuredContent"]?["history"]?["steps"] == .int(photo.history.count), text(current).prefix(120).description)

        // Steps up to and including the current one (later, struck-out steps are trimmed by the next edit).
        let steps = photo.historyIndex + 1
        let edit = await tool("set_adjustments", ["values": ["exposure": 9, "vignette": -20.4], "deltas": ["contrast": 10], "label": "  Brighter\n\u{202E}look  "])
        check("control: set_adjustments is one step, clamped and labelled", edit?["isError"] == false && photo.historyIndex == steps && photo.history.count == steps + 1
              && photo.history.last?.label == "Brighter look" && photo.adjustments.exposure == 5 && photo.adjustments.contrast == 10
              && photo.adjustments.vignette == -20 && edit?["structuredContent"]?["clamped_to_range"] == ["exposure"],
              "\(photo.history.last?.label ?? "") \(text(edit).prefix(160))")
        let same = await tool("set_adjustments", ["values": ["exposure": 5]])
        check("control: no change, no step", same?["structuredContent"]?["applied"] == false && photo.history.count == steps + 1, text(same))
        var refused = 0
        for bad: JSONValue in [["values": ["curve": 1]], ["values": ["exposure": "1"]], ["values": ["exposure": true]],
                               ["values": ["exposure": 1], "deltas": ["exposure": 1]], [:], ["foo": 1], ["values": ["exposure": 1], "label": 3],
                               ["values": 2], ["values": ["masks": 0]]] {
            let r = await tool("set_adjustments", bad)
            if r?["isError"] == true { refused += 1 }
        }
        check("control: set_adjustments validates strictly", refused == 9 && photo.history.count == steps + 1 && photo.adjustments.exposure == 5, "\(refused) of 9")
        _ = await tool("set_adjustments", ["deltas": ["exposure": -1.234], "label": .string(String(repeating: "x", count: 300))])
        check("control: deltas, rounding, default and capped labels", photo.adjustments.exposure == 3.77
              && photo.history.last?.label.count == ControlTools.maxLabelLength && ControlTools.cleanLabel(" \n\t ") == ControlTools.defaultLabel,
              "\(photo.adjustments.exposure) \(photo.history.last?.label.count ?? 0)")
        let undone = await tool("undo")
        check("control: undo steps back once", undone?["structuredContent"]?["undone_step"] != nil && photo.adjustments.exposure == 5
              && photo.historyIndex == steps && photo.history.count == steps + 2, text(undone))

        let preview = await tool("get_preview", ["max_size": 128])
        let image = preview?["content"]?.arrayValue?.first { $0["type"] == "image" }
        var previewOK = false, detail = ""
        if let b64 = image?["data"]?.stringValue, let data = Data(base64Encoded: b64), image?["mimeType"] == "image/jpeg",
           let src = CGImageSourceCreateWithData(data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let meta = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
            let segments = ControlTools.stripMetadata(data) == data   // nothing left to strip
            previewOK = max(w, h) == 128 && meta.allSatisfy { props[$0] == nil } && segments
                && CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
            detail = "\(w)×\(h) \(props.keys.map { $0 as String }.sorted())"
        }
        check("control: get_preview is a small JPEG without metadata", previewOK, detail)
        let tooBig = await tool("get_preview", ["max_size": 4000])
        check("control: get_preview refuses a large size", tooBig?["isError"] == true, text(tooBig))

        store.resetAdjustments()
        store.commitPending(photo)
        let beforeAuto = photo.history.count
        let auto = await tool("auto")
        let outcome = auto?["structuredContent"]?["outcome"]?.stringValue
        check("control: auto is one step labelled Auto", auto?["isError"] == false
              && ((outcome == "applied" && photo.history.count == beforeAuto + 1 && photo.history.last?.label == "Auto")
                  || (outcome == "unchanged" && photo.history.count == beforeAuto)), text(auto).prefix(200).description)
        store.resetAdjustments()
        store.commitPending(photo)
        AutoVision.shared.install(horizon: .init(angle: -3.04, confidence: 0.9), for: photo.url)
        AutoEngine.shared.clear()
        let level = await tool("auto_straighten")
        check("control: auto_straighten", level?["structuredContent"]?["outcome"] == "applied" && photo.adjustments.crop.angle == -3
              && photo.history.last?.label == "Auto straighten", text(level))
        AutoVision.shared.removeOverrides(for: photo.url)
        AutoEngine.shared.clear()
        let extra = await tool("get_photo", ["x": 1])
        check("control: argument-free tools refuse arguments", extra?["isError"] == true, text(extra))
        store.resetAdjustments()
        store.mode = .library

        await socketChecks(store: store, check: check)
        keychainCheck(check: check)
    }

    /// A real round trip over loopback, and proof the server isn't reachable any other way.
    @MainActor
    private static func socketChecks(store: LibraryStore, check: (String, Bool, String) -> Void) async {
        guard let port = freeLoopbackPort() else { return check("control: a free port for the socket test", false, "") }
        let tokens = MemoryTokenStore()
        let control = LocalControl(runner: StoreToolRunner(store: store), tokenStore: tokens, defaults: nil)
        check("control: off by default, no token yet", control.status == .off && control.token == nil, "")
        control.port = port
        control.enabled = true
        for _ in 0..<60 where control.runningPort == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let token = control.token, control.runningPort == port else {
            control.enabled = false
            return check("control: server starts on loopback", false, "\(control.status)")
        }
        check("control: token made on first enable and kept in the store", (try? tokens.load()) == token, "")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        func post(_ body: String, token t: String) async -> (Int, Data) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.httpBody = Data(body.utf8)
            guard let (data, response) = try? await session.data(for: req), let http = response as? HTTPURLResponse else { return (-1, Data()) }
            return (http.statusCode, data)
        }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"selftest","version":"1"}}}"#
        let (ok, data) = await post(initialize, token: token)
        let reply = try? JSONValue.parse(data).get()
        check("control: loopback round trip", ok == 200 && reply?["result"]?["serverInfo"]?["name"] == "halfstop", "\(ok) \(String(decoding: data.prefix(120), as: UTF8.self))")
        let (bad, _) = await post(initialize, token: "not-the-token")
        check("control: loopback refuses a bad token", bad == 401, "\(bad)")
        let old = token
        control.regenerateToken()
        for _ in 0..<40 where control.token == old { try? await Task.sleep(for: .milliseconds(50)) }
        let (stale, _) = await post(initialize, token: old)
        let (fresh, _) = await post(initialize, token: control.token ?? "")
        check("control: regenerate takes effect at once", stale == 401 && fresh == 200 && control.token != old, "\(stale) \(fresh)")
        if let lan = nonLoopbackIPv4() {
            check("control: not reachable on \(lan) (bound to 127.0.0.1 only)", !canConnect(lan, port), "")
        } else {
            print("SKIP  control: no network interface to check the loopback-only bind against")
        }
        check("control: reachable on 127.0.0.1 while on", canConnect("127.0.0.1", port), "")
        // Another listener can't take over the port (and so can't collect tokens sent to it).
        let rival = LocalControl(runner: StoreToolRunner(store: store), tokenStore: MemoryTokenStore(), defaults: nil)
        rival.port = port
        rival.enabled = true
        for _ in 0..<60 where rival.status == .starting { try? await Task.sleep(for: .milliseconds(50)) }
        check("control: a port in use is reported, not shared", rival.status == .portInUse(port: port), "\(rival.status)")
        rival.enabled = false
        let (still, _) = await post(initialize, token: control.token ?? "")
        check("control: the first server keeps answering", still == 200, "\(still)")
        control.enabled = false
        check("control: turning it off stops the server at once", control.status == .off && !canConnect("127.0.0.1", port), "\(control.status)")
        // Back on right away, on the same port, after connections were served and closed.
        control.enabled = true
        for _ in 0..<60 where control.status == .starting { try? await Task.sleep(for: .milliseconds(50)) }
        let (again, _) = await post(initialize, token: control.token ?? "")
        check("control: restarts on the same port at once", control.runningPort == port && again == 200, "\(control.status) \(again)")
        control.enabled = false
        // A Regenerate that can't save its new token still revokes the old one: the server stops
        // and says why, rather than keep accepting a token the user wanted gone. Retrying works.
        let flakyStore = FlakyTokenStore()
        let flaky = LocalControl(runner: StoreToolRunner(store: store), tokenStore: flakyStore, defaults: nil)
        flaky.port = port
        flaky.enabled = true
        for _ in 0..<60 where flaky.runningPort == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let flakyOld = flaky.token ?? ""
        flakyStore.failSaves = true
        flaky.regenerateToken()
        for _ in 0..<60 where flaky.token != nil { try? await Task.sleep(for: .milliseconds(50)) }
        var failedStatus = false
        if case .failed = flaky.status { failedStatus = true }
        let (revoked, _) = await post(initialize, token: flakyOld)
        check("control: a failed regenerate revokes the old token and stops", !flakyOld.isEmpty && failedStatus && flaky.token == nil
              && revoked != 200 && !flaky.tokenBox.matches(flakyOld) && !canConnect("127.0.0.1", port), "\(flaky.status) \(revoked)")
        flakyStore.failSaves = false
        flaky.regenerateToken()
        for _ in 0..<60 where flaky.runningPort == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let (retried, _) = await post(initialize, token: flaky.token ?? "")
        check("control: regenerating again starts it with the new token", retried == 200 && flaky.token != flakyOld, "\(flaky.status) \(retried)")
        flaky.enabled = false
        session.invalidateAndCancel()
    }

    /// The real Keychain store, on its own test item (deleted again). Skipped when there's no
    /// usable keychain, as in a headless session.
    private static func keychainCheck(check: (String, Bool, String) -> Void) {
        let store = KeychainTokenStore(service: KeychainTokenStore.appService + ".selftest")
        store.delete()
        defer { store.delete() }
        do {
            try store.save("first-value")
            try store.save("second-value")
            let loaded = try store.load()
            store.delete()
            let gone = try store.load()
            check("control: Keychain token store (test item)", loaded == "second-value" && gone == nil, "\(loaded ?? "nil")")
        } catch {
            print("SKIP  control: Keychain token store (\(error.localizedDescription))")
        }
    }

    static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// A TCP connect, refused or not (the target is this Mac, so it answers at once).
    private static func canConnect(_ ip: String, _ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(ip)
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// This Mac's first non-loopback IPv4 address, if it has one.
    private static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

private extension Result where Success == (HTTPHead, Int), Failure == HTTPResponse {
    var failureStatus: Int? { if case .failure(let r) = self { return r.status }; return nil }
}

/// A token store whose saves can be made to fail, like a Keychain that refuses the write.
private final class FlakyTokenStore: ControlTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var _failSaves = false
    var failSaves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failSaves }
        set { lock.lock(); _failSaves = newValue; lock.unlock() }
    }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func save(_ t: String) throws {
        lock.lock(); defer { lock.unlock() }
        if _failSaves { throw KeychainError(status: errSecWrPerm) }
        token = t
    }
    func delete() { lock.lock(); token = nil; lock.unlock() }
}

/// `--serve-control <dir> [--port N] [--seconds N]`: the local AI control server on a throwaway
/// library of sample photos (in `<dir>`), with a one-off token printed here, for trying an MCP
/// client or curl against it. Never touches the real library, settings or Keychain.
enum ControlDemo {
    @MainActor
    static func run(dir: URL, port: Int, seconds: Int) async {
        let photos = dir.appendingPathComponent("photos", isDirectory: true)
        SelfTest.makeSamples(in: photos)
        let store = LibraryStore(catalogURL: dir.appendingPathComponent("catalog.json"), watch: false)
        let scan = await store.scanForImport(photos, includeSubfolders: false)
        _ = await store.performImport(scan, options: ImportOptions())
        guard let first = store.photos.first else { return print("--serve-control: no sample photos") }
        store.open(first)
        let control = LocalControl(runner: StoreToolRunner(store: store), tokenStore: MemoryTokenStore(), defaults: nil)
        control.port = port
        control.enabled = true
        for _ in 0..<100 where control.status == .starting { try? await Task.sleep(for: .milliseconds(50)) }
        guard control.runningPort != nil, let token = control.token else { return print("--serve-control: \(control.status)") }
        print("Serving \(first.name) (open in the editor) at \(control.url) for \(seconds) s")
        print("TOKEN \(token)")
        print(control.addCommand(token: token))
        fflush(stdout)
        try? await Task.sleep(for: .seconds(seconds))
        control.enabled = false
        store.flushSaves()
    }
}
