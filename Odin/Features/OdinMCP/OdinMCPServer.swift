#if os(macOS)
import Foundation
import Network

/// Identifies the Odin Claude tab that originated the current MCP request.
/// Set per-request from the X-Session-Id header so tool handlers can route
/// completions back to the right session.
enum CurrentMCPRequest {
    @TaskLocal static var sessionId: String?
}

/// Local-only HTTP MCP server. Listens on 127.0.0.1 with an ephemeral port and
/// speaks JSON-RPC 2.0 at POST /mcp. Spawned Claude sessions reach it via the
/// per-session .mcp.json that LocalTerminalViewModel writes at launch.
@MainActor
final class OdinMCPServer {
    static let shared = OdinMCPServer()

    private var listener: NWListener?
    private(set) var port: UInt16?

    var mcpURL: String? {
        guard let port else { return nil }
        return "http://127.0.0.1:\(port)/mcp"
    }

    private init() {}

    func start() throws {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in
                self?.handle(connection: conn)
            }
        }
        listener.stateUpdateHandler = { [weak listener] state in
            guard case .ready = state, let port = listener?.port?.rawValue else { return }
            Task { @MainActor in
                OdinMCPServer.shared.port = port
                NSLog("[OdinMCP] listening on http://127.0.0.1:\(port)/mcp")
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        // Defense in depth: reject any connection that isn't from loopback.
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let v4) where v4 == .loopback:
                break
            case .ipv6(let v6) where v6 == .loopback:
                break
            default:
                connection.cancel()
                return
            }
        }
        let parser = HTTPRequestParser()
        connection.start(queue: .main)
        receive(connection: connection, parser: parser)
    }

    private func receive(connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                parser.feed(data)
                if let request = parser.complete() {
                    Task { @MainActor [weak self] in
                        await self?.process(request: request, on: connection)
                    }
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            Task { @MainActor [weak self] in
                self?.receive(connection: connection, parser: parser)
            }
        }
    }

    private func process(request: HTTPRequestParser.Request, on connection: NWConnection) async {
        guard request.method == "POST", request.path == "/mcp" else {
            sendEmpty(on: connection, status: 404)
            return
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed])
        } catch {
            sendError(id: nil, code: -32700, message: "Parse error: \(error)", on: connection)
            return
        }
        guard let json = raw as? [String: Any] else {
            sendError(id: nil, code: -32600, message: "Invalid Request", on: connection)
            return
        }
        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]
        let sessionId = request.headers["x-session-id"]
        await CurrentMCPRequest.$sessionId.withValue(sessionId) {
            await self.dispatch(method: method, params: params, id: id, on: connection)
        }
    }

    private func dispatch(method: String, params: [String: Any], id: Any?, on connection: NWConnection) async {
        switch method {
        case "initialize":
            send(result: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "odin-mcp", "version": "0.1.0"]
            ], id: id, on: connection)
        case "notifications/initialized":
            sendEmpty(on: connection, status: 202)
        case "tools/list":
            send(result: ["tools": OdinMCPTools.descriptors], id: id, on: connection)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await OdinMCPTools.call(name: name, args: args)
                send(result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ], id: id, on: connection)
            } catch {
                send(result: [
                    "content": [["type": "text", "text": "\(error)"]],
                    "isError": true
                ], id: id, on: connection)
            }
        case "ping":
            send(result: [String: Any](), id: id, on: connection)
        default:
            if id == nil {
                sendEmpty(on: connection, status: 202)
            } else {
                sendError(id: id, code: -32601, message: "Method not found: \(method)", on: connection)
            }
        }
    }

    // MARK: - HTTP responses

    private func send(result: Any, id: Any?, on connection: NWConnection) {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { resp["id"] = id }
        sendJSON(resp, on: connection, status: 200)
    }

    private func sendError(id: Any?, code: Int, message: String, on connection: NWConnection) {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { resp["id"] = id }
        sendJSON(resp, on: connection, status: 200)
    }

    private func sendJSON(_ obj: Any, on connection: NWConnection, status: Int) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = """
        HTTP/1.1 \(status) \(statusText(status))\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var packet = Data(head.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendEmpty(on connection: NWConnection, status: Int) {
        let head = """
        HTTP/1.1 \(status) \(statusText(status))\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "OK"
        }
    }
}

// MARK: - HTTP request parser

/// Accessed only from the main queue (NWListener is started on `.main`),
/// so unchecked Sendable is safe.
final class HTTPRequestParser: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct ParsedHead {
        let method: String
        let path: String
        let contentLength: Int
        let headers: [String: String]
        let bodyStart: Int
    }

    private var buffer = Data()
    private var head: ParsedHead?

    func feed(_ data: Data) {
        buffer.append(data)
    }

    func complete() -> Request? {
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 2 else { return nil }

            var headers: [String: String] = [:]
            var contentLength = 0
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = String(line[..<colon])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let v = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[k] = v
                if k == "content-length" {
                    contentLength = Int(v) ?? 0
                }
            }
            head = ParsedHead(
                method: parts[0],
                path: parts[1],
                contentLength: contentLength,
                headers: headers,
                bodyStart: range.upperBound
            )
        }
        guard let head else { return nil }
        let needed = head.bodyStart + head.contentLength
        if buffer.count >= needed {
            let body = buffer.subdata(in: head.bodyStart..<needed)
            return Request(
                method: head.method,
                path: head.path,
                headers: head.headers,
                body: body
            )
        }
        return nil
    }
}
#endif
