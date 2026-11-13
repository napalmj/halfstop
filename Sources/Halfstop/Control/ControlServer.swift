import Foundation
import Network
import Security
import AppKit
import Observation

// MARK: - Listener

/// The socket side: a Network.framework listener bound to 127.0.0.1 only, one request per
/// connection, with limits on time, size, connections and request rate.
final class ControlServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case ready(port: Int)
        case portInUse
        case failed(String)
        case stopped
    }

    /// Whole request (head and body) must arrive within this.
    static let readTimeout: TimeInterval = 10
    /// Including the tool's work (Auto measures in well under a second).
    static let connectionTimeout: TimeInterval = 60
    static let maxConnections = 16
    /// Requests per second, with bursts up to `burst`.
    static let rate = 20.0, burst = 40.0

    let endpoint: MCPEndpoint
    private let queue = DispatchQueue(label: "halfstop.control", qos: .userInitiated)
    // Touched only on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var allowance = ControlServer.burst
    private var lastRefill = Date()
    private var onState: (@Sendable (State) -> Void)?

    init(endpoint: MCPEndpoint) { self.endpoint = endpoint }

    /// Starts listening on 127.0.0.1:`port`.
    func start(port: Int, onState: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            stopLocked()
            self.onState = onState
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return onState(.failed("Invalid port")) }
            let params = NWParameters.tcp
            // Loopback only: the socket is bound to 127.0.0.1 itself, never to all interfaces.
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
            params.requiredInterfaceType = .loopback
            params.acceptLocalOnly = true
            params.includePeerToPeer = false
            params.allowLocalEndpointReuse = true
            let l: NWListener
            do { l = try NWListener(using: params) } catch {
                return onState(Self.state(for: error))
            }
            listener = l
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready: self.onState?(.ready(port: Int(l.port?.rawValue ?? 0)))
                case .failed(let e):
                    self.onState?(Self.state(for: e))
                    self.stopLocked(report: false)
                case .waiting(let e):
                    // Typically the port is taken: report it rather than wait for it to free up.
                    self.onState?(Self.state(for: e))
                    self.stopLocked(report: false)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
        }
    }

    /// Stops listening and drops every open connection, right away.
    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked(report: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        let wasRunning = listener != nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for c in connections.values { c.close() }
        connections = [:]
        if report && wasRunning { onState?(.stopped) }
    }

    private static func state(for error: Error) -> State {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse }
        return .failed((error as NSError).localizedDescription)
    }

    private func accept(_ nw: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Belt and braces: the listener is loopback-only, so anything else is a bug.
        if case .hostPort(let host, _) = nw.endpoint, !Self.isLoopback(host) { nw.cancel(); return }
        let now = Date()
        allowance = min(Self.burst, allowance + now.timeIntervalSince(lastRefill) * Self.rate)
        lastRefill = now
        guard connections.count < Self.maxConnections, allowance >= 1 else {
            let busy = connections.count >= Self.maxConnections ? 503 : 429
            nw.start(queue: queue)
            nw.send(content: HTTPRequestParser.plain(busy).serialized(), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in nw.cancel() })
            return
        }
        allowance -= 1
        let c = Connection(nw, server: self)
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): a == .loopback
        case .ipv6(let a): a == .loopback || a == IPv6Address("::ffff:127.0.0.1")
        case .name(let n, _): n == "localhost" || n == "127.0.0.1"
        @unknown default: false
        }
    }

    fileprivate func finished(_ c: Connection) {
        dispatchPrecondition(condition: .onQueue(queue))
        connections[ObjectIdentifier(c)] = nil
    }

    fileprivate var connectionQueue: DispatchQueue { queue }

    /// One request and its reply.
    fileprivate final class Connection: @unchecked Sendable {   // touched only on the server queue
        private let nw: NWConnection
        private weak var server: ControlServer?
        private var parser = HTTPRequestParser()
        private var replied = false
        private var closed = false
        private var haveRequest = false

        init(_ nw: NWConnection, server: ControlServer) { self.nw = nw; self.server = server }

        func start() {
            guard let queue = server?.connectionQueue else { return }
            nw.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            nw.start(queue: queue)
            queue.asyncAfter(deadline: .now() + ControlServer.readTimeout) { [weak self] in
                guard let self, !self.haveRequest else { return }
                self.reply(HTTPRequestParser.plain(408))
            }
            queue.asyncAfter(deadline: .now() + ControlServer.connectionTimeout) { [weak self] in self?.close() }
            receive()
        }

        private func receive() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.replied else { return }
                if let data, !data.isEmpty { self.parser.append(data) }
                guard self.process() else { return }
                if error != nil || isComplete { self.close() } else { self.receive() }
            }
        }

        /// Handles what the parser has; false once there's nothing more to read.
        private func process() -> Bool {
            guard let server else { close(); return false }
            while true {
                switch parser.next() {
                case .needMore:
                    return true
                case .reject(let r):
                    reply(r)
                    return false
                case .head(let head):
                    // Refuse before reading the body: a stranger's megabyte is never read.
                    if let r = server.endpoint.gate.screen(head) { reply(r); return false }
                    if head.expectsContinue { nw.send(content: HTTPResponse.continueLine, completion: .idempotent) }
                case .request(let request):
                    haveRequest = true
                    let endpoint = server.endpoint
                    let queue = server.connectionQueue
                    Task {
                        let response = await endpoint.respond(request)
                        queue.async { [weak self] in self?.reply(response) }
                    }
                    return false
                }
            }
        }

        private func reply(_ response: HTTPResponse) {
            guard !replied, !closed else { return }
            replied = true
            haveRequest = true
            nw.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [weak self] _ in self?.close() })
        }

        func close() {
            guard !closed else { return }
            closed = true
            nw.stateUpdateHandler = nil
            nw.cancel()
            server?.finished(self)
        }
    }
}

// MARK: - Token

enum ControlToken {
    /// 256 random bits from the system's secure generator, base64url without padding (43 characters).
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Where the token is kept. The app uses the Keychain; the self-test an in-memory store.
protocol ControlTokenStore: Sendable {
    /// nil when there's none yet; throws when it can't be read.
    func load() throws -> String?
    func save(_ token: String) throws
    func delete()
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// A generic password item in the login keychain.
struct KeychainTokenStore: ControlTokenStore {
    static let appService = "dev.halfstop.app.local-ai-control"
    let service: String
    let account = "mcp-bearer-token"

    init(service: String = KeychainTokenStore.appService) { self.service = service }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func load() throws -> String? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return s
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        // An item this build may not change (made by an earlier build, access denied): replace it.
        if update != errSecItemNotFound { SecItemDelete(query as CFDictionary) }
        var add = query
        add[kSecValueData] = data
        add[kSecAttrLabel] = "Halfstop local AI control token"
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

final class MemoryTokenStore: ControlTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String? = nil) { self.token = token }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func save(_ t: String) throws { lock.lock(); token = t; lock.unlock() }
    func delete() { lock.lock(); token = nil; lock.unlock() }
}

// MARK: - The setting

/// Settings ▸ Local AI control (MCP): an opt-in MCP server so AI apps on this Mac can edit the open
/// photo. Off by default; runs only while switched on.
@MainActor
@Observable
final class LocalControl {
    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case portInUse(port: Int)
        case failed(String)
    }

    nonisolated static let enabledKey = "localControlEnabled"
    nonisolated static let portKey = "localControlPort"
    nonisolated static let defaultPort = 47615
    static let portRange = 1024...65535

    /// Off by default. Turning it on starts the server (making a token the first time); off stops it at once.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults?.set(enabled, forKey: Self.enabledKey)
            apply()
        }
    }

    /// Restarts a running server on the new port. Out-of-range values are refused.
    var port: Int {
        didSet {
            guard port != oldValue else { return }
            if !Self.portRange.contains(port) { port = oldValue; return }
            defaults?.set(port, forKey: Self.portKey)
            if enabled { apply() }
        }
    }

    private(set) var status = Status.off
    /// nil until first switched on (or when the Keychain can't be read).
    private(set) var token: String?

    @ObservationIgnored private let tokenStore: ControlTokenStore
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let tokenBox = ControlTokenBox()
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private let runner: ControlToolRunner
    /// Bumped on every start/stop, so late state reports from an old listener are ignored.
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - defaults: where the switch and port are remembered; nil remembers nothing (self-test).
    init(runner: ControlToolRunner, tokenStore: ControlTokenStore = KeychainTokenStore(), defaults: UserDefaults? = .standard) {
        self.runner = runner
        self.tokenStore = tokenStore
        self.defaults = defaults
        enabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? false
        let saved = defaults?.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
        port = Self.portRange.contains(saved) ? saved : Self.defaultPort
        if enabled { apply() }
    }

    private func apply() {
        generation += 1
        server?.stop()
        server = nil
        guard enabled else {
            status = .off
            return
        }
        status = .starting
        let gen = generation
        if token != nil { return startServer(gen) }
        // The Keychain can stop to ask the user (an app rebuilt from source has a new signature),
        // so it's never read or written on the main thread.
        let store = tokenStore
        Task.detached(priority: .userInitiated) {
            let outcome = Self.loadOrCreate(store)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let t):
                    self.setToken(t)
                    if self.generation == gen { self.startServer(gen) }
                case .failure(let e):
                    if self.generation == gen { self.status = .failed(e.message) }
                }
            }
        }
    }

    private func startServer(_ gen: Int) {
        let gate = ControlGate(port: port, token: tokenBox)
        let s = ControlServer(endpoint: MCPEndpoint(gate: gate, runner: runner))
        server = s
        let wanted = port
        s.start(port: port) { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch state {
                case .ready(let p): self.status = .running(port: p)
                case .portInUse: self.status = .portInUse(port: wanted); self.server = nil
                case .failed(let why): self.status = .failed(why); self.server = nil
                case .stopped: break
                }
            }
        }
    }

    /// The port the server is actually listening on.
    var runningPort: Int? {
        if case .running(let p) = status { return p }
        return nil
    }

    /// The stored token, or a new one saved for next time. Off the main thread.
    nonisolated private static func loadOrCreate(_ store: ControlTokenStore) -> Result<String, ToolError> {
        do {
            if let t = try store.load(), t.count >= 32 { return .success(t) }
        } catch {
            return .failure(ToolError("Couldn’t read the token from the Keychain (\(error.localizedDescription)). Regenerate it to make a new one."))
        }
        return makeAndSave(store)
    }

    nonisolated private static func makeAndSave(_ store: ControlTokenStore) -> Result<String, ToolError> {
        guard let t = ControlToken.generate() else { return .failure(ToolError("Couldn’t generate a token")) }
        do {
            try store.save(t)
        } catch {
            return .failure(ToolError("Couldn’t save the token in the Keychain (\(error.localizedDescription))"))
        }
        return .success(t)
    }

    /// Settings ▸ Regenerate: a new token, effective as soon as it's saved (clients need the new one).
    func regenerateToken() {
        let store = tokenStore
        Task.detached(priority: .userInitiated) {
            let outcome = Self.makeAndSave(store)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let t):
                    self.setToken(t)
                    // A server that couldn't start for want of a token can start now.
                    if self.enabled, self.server == nil { self.apply() }
                case .failure(let e):
                    self.status = .failed(e.message)
                }
            }
        }
    }

    private func setToken(_ t: String) {
        token = t
        tokenBox.set(t)
    }

    // MARK: Setting up a client

    var url: String { "http://127.0.0.1:\(runningPort ?? port)/mcp" }

    /// An `mcpServers` entry for MCP clients that read a JSON config.
    func configJSON(token: String) -> String {
        """
        {
          "mcpServers": {
            "halfstop": {
              "type": "http",
              "url": "\(url)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }

    /// The Claude Code command line that adds the server.
    func addCommand(token: String) -> String {
        "claude mcp add --transport http halfstop \(url) --header \"Authorization: Bearer \(token)\""
    }

    /// The token as shown on screen: enough to recognize it, not enough to use it.
    static func masked(_ token: String) -> String {
        String(repeating: "•", count: 12) + token.suffix(4)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
