import Foundation
import Network

/// Hark's abilities as an MCP server, so Claude Code calls them like any other tool: it runs its own loop, and its
/// other MCP servers sit right next to these. Streamable HTTP on 127.0.0.1 only, with a per-launch secret.
public final class MCPServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public let token = UUID().uuidString
    /// Tool descriptors for tools/list (MCP shape: name, description, inputSchema).
    public var tools: () async -> [[String: Any]] = { [] }
    /// Runs a tool; returns MCP content blocks (text and images).
    public var call: (String, [String: Any]) async -> (content: [[String: Any]], isError: Bool) = { _, _ in ([], true) }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.hark.mcp")

    public init() {}

    /// Starts listening on a free loopback port; returns once the port is known.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue ?? 0
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        Log.info("Hark tools listening for Claude Code on 127.0.0.1:\(port)")
    }

    /// `--mcp-config` JSON that points Claude Code at this server. Built once with sorted keys: it must be the exact same
    /// text every time, or Hark thinks the session's setup changed and starts a cold one.
    public var configJSON: String {
        if let cachedConfig, cachedPort == port { return cachedConfig }
        let config: [String: Any] = ["mcpServers": ["hark": ["type": "http", "url": "http://127.0.0.1:\(port)/mcp",
                                                             "headers": ["Authorization": "Bearer \(token)"]]]]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        cachedConfig = json
        cachedPort = port
        return json
    }
    private var cachedConfig: String?
    private var cachedPort: UInt16 = 0

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if complete || error != nil || buffer.count > 32 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return send(connection, status: "401 Unauthorized", body: Data())
        }
        guard request.method == "POST" else {
            // No server-initiated stream: every answer comes back on the POST itself.
            return send(connection, status: request.method == "DELETE" ? "200 OK" : "405 Method Not Allowed", body: Data())
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return send(connection, status: "400 Bad Request", body: Data())
        }
        if let batch = message as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for item in batch { if let reply = await handle(item) { replies.append(reply) } }
            return replies.isEmpty ? send(connection, status: "202 Accepted", body: Data()) : sendJSON(connection, replies)
        }
        guard let single = message as? [String: Any] else { return send(connection, status: "400 Bad Request", body: Data()) }
        if let reply = await handle(single) { sendJSON(connection, reply) } else { send(connection, status: "202 Accepted", body: Data()) }
    }

    /// One JSON-RPC message; nil for notifications (no reply).
    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            return result(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "hark", "version": "1.0"],
                           "instructions": "Hark controls this Mac: see the screen, click, type, open apps and sites, and more."])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": await tools()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (content, isError) = await call(name, arguments)
            return result(["content": content, "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    private func sendJSON(_ connection: NWConnection, _ value: Any) {
        send(connection, status: "200 OK", body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), type: "application/json")
    }

    private func send(_ connection: NWConnection, status: String, body: Data, type: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private final class OnceBox: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}

/// Just enough HTTP/1.1 to read one request: method, headers, and a Content-Length body.
struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " "), let method = first.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        self.method = String(method)
        self.headers = headers
        self.body = Data(data[bodyStart..<(bodyStart + length)])
    }
}
