import Foundation
import Network

/// Lets AI agents (Claude, ChatGPT's Codex) edit in Editroom using the Model Context Protocol.
///
/// A small HTTP server on this Mac only (127.0.0.1), speaking MCP's Streamable HTTP transport with
/// plain JSON replies. Claude Code connects to it directly; Claude Desktop and Codex start
/// `Editroom --mcp`, which passes their messages through (see MCPBridge).
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()
    nonisolated static let port: UInt16 = 47920
    nonisolated static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    struct Client: Identifiable {
        let id: String
        var name: String
        var lastSeen: Date
    }

    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var clients: [String: Client] = [:]
    @Published var enabled = UserDefaults.standard.object(forKey: "agentsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "agentsEnabled")
            enabled ? start() : stop()
        }
    }

    private var listener: NWListener?
    private(set) weak var model: EditorModel?
    /// The port this copy is listening on: the usual one, or (when another copy of Editroom has it)
    /// any free one, for this copy's own Magic runs.
    private(set) var listeningPort: UInt16?
    /// Where this copy's own Magic runs reach it.
    var localEndpoint: String? { listeningPort.map { "http://127.0.0.1:\($0)/mcp" } }

    func attach(_ model: EditorModel) {
        self.model = model
        if enabled { start() }
    }

    func start() { listen(on: Self.port) }

    private func listen(on number: UInt16) {
        guard listener == nil, let port = number == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: number) else { return }
        let params = NWParameters.tcp
        // This Mac only: never reachable from the network.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { conn in
                Task { @MainActor in MCPServer.shared.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        let s = MCPServer.shared
                        s.running = true
                        s.listeningPort = s.listener?.port?.rawValue
                        s.problem = number == 0 ? "Another copy of Editroom is answering AI apps; this one only runs its own Magic." : nil
                    case .failed(let e):
                        let s = MCPServer.shared
                        s.running = false
                        s.listener?.cancel()
                        s.listener = nil
                        s.listeningPort = nil
                        if number != 0, case .posix(let code) = e, code == .EADDRINUSE {
                            // Someone else (another copy of Editroom) has the usual port.
                            s.listen(on: 0)
                        } else {
                            s.problem = "Couldn't listen on port \(Self.port): \(e.localizedDescription)"
                        }
                    case .cancelled:
                        MCPServer.shared.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        running = false
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            Task { @MainActor in
                var buf = buffer
                if let data { buf.append(data) }
                if let request = HTTPRequest(buf) {
                    await self.respond(conn, request)
                } else if complete || error != nil || buf.count > 32 << 20 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) async {
        func send(_ status: String, _ body: Data = Data(), headers: [String: String] = [:]) {
            var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
        // Only local callers by name, and no web pages: a page in a browser can't reach in.
        let host = req.headers["host"] ?? ""
        let hostName = host.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(hostName) else { return send("403 Forbidden") }
        if let origin = req.headers["origin"], !origin.isEmpty {
            guard let u = URL(string: origin), ["127.0.0.1", "localhost"].contains(u.host ?? "") else { return send("403 Forbidden") }
        }
        guard req.path.hasPrefix("/mcp") else { return send("404 Not Found") }
        // A Magic run's agent works on a hidden draft, named in its address.
        let draftToken = URLComponents(string: req.path)?.queryItems?.first { $0.name == "draft" }?.value
        // With AI Agents off, the connection is only open for this copy's own Magic runs.
        guard enabled || draftToken.map({ MCPDraft.find($0) != nil }) == true else {
            return send("403 Forbidden")
        }
        switch req.method {
        case "POST": break
        case "DELETE":
            if let s = req.headers["mcp-session-id"] { clients[s] = nil }
            return send("200 OK")
        default:
            return send("405 Method Not Allowed", headers: ["Allow": "POST, DELETE"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            let err = Self.error(nil, -32700, "Parse error")
            return send("400 Bad Request", (try? JSONSerialization.data(withJSONObject: err)) ?? Data(), headers: ["Content-Type": "application/json"])
        }
        // The Claude app, disconnected in Editroom's Settings: say so instead of working.
        if req.headers["x-editroom-from"] == "claude-app", AgentConnect.shared.claudeAppOff {
            guard json["id"] != nil else { return send("202 Accepted") }
            let err = Self.error(json["id"], -32001, "Editroom is disconnected from Claude. To use it again, connect Claude in Editroom > Settings > Magic.")
            return send("200 OK", (try? JSONSerialization.data(withJSONObject: err)) ?? Data(), headers: ["Content-Type": "application/json"])
        }
        var session = req.headers["mcp-session-id"]
        let method = json["method"] as? String ?? ""
        if method == "initialize" {
            session = UUID().uuidString
            let info = (json["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
            // Magic's own agent isn't listed as a connected app.
            if draftToken == nil {
                clients[session!] = Client(id: session!, name: Self.displayName(info?["name"] as? String ?? "Agent"), lastSeen: Date())
            }
        } else if draftToken == nil, let s = session {
            if clients[s] == nil { clients[s] = Client(id: s, name: "Agent", lastSeen: Date()) }
            clients[s]?.lastSeen = Date()
        }
        // Notifications get no reply.
        guard json["id"] != nil else { return send("202 Accepted") }
        let reply = await MCPHandler.handle(json, client: session.flatMap { clients[$0] }, draft: draftToken)
        let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        var headers = ["Content-Type": "application/json"]
        if let session { headers["Mcp-Session-Id"] = session }
        send("200 OK", body, headers: headers)
    }

    /// What to call an agent on its cursor.
    static func displayName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("claude") { return "Claude" }
        if s.contains("codex") { return "Codex" }
        if s.contains("chatgpt") || s.contains("openai") { return "ChatGPT" }
        let words = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

/// Just enough HTTP/1.1 to read one request with a body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Nil until the whole request (headers and body) has arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        headers = h
        body = data[bodyStart..<(bodyStart + length)]
    }
}

/// JSON-RPC methods: the MCP handshake, listing tools and calling them.
@MainActor
enum MCPHandler {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The handshake, ping and the tool list: needing nothing from the editor, so the bridge answers them
    /// the same way while Editroom is closed (and doesn't open it just for an agent saying hello).
    static func handshake(_ req: [String: Any]) -> [String: Any]? {
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result] }
        switch req["method"] as? String ?? "" {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? versions[0]
            return ok([
                "protocolVersion": versions.contains(asked) ? asked : versions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "editroom", "title": "Editroom", "version": "1.0"],
                "instructions": MCPTools.instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": MCPTools.definitions])
        // Asked by some agents as they start (Codex): Editroom has neither, and saying so mustn't open it.
        case "resources/list":
            return ok(["resources": [Any]()])
        case "resources/templates/list":
            return ok(["resourceTemplates": [Any]()])
        case "prompts/list":
            return ok(["prompts": [Any]()])
        default:
            return nil
        }
    }

    /// Whether a request needs Editroom itself, and opens it when it's closed: only using a tool does. Everything
    /// else an agent sends (its hello, pings, asking what there is, as it starts up or now and then) is answered
    /// without it, so an AI app starting or idling never opens Editroom.
    nonisolated static func opensEditroom(_ method: String) -> Bool { method == "tools/call" }

    static func handle(_ req: [String: Any], client: MCPServer.Client?, draft token: String? = nil) async -> [String: Any] {
        if let reply = handshake(req) { return reply }
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result] }
        switch req["method"] as? String ?? "" {
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            if CommandLine.arguments.contains("--magic-ai") {
                FileHandle.standardError.write("MCP CALL \(name) \(token == nil ? "live" : "draft") from \(client?.name ?? "?")\n".data(using: .utf8)!)
            }
            var draft: MCPDraft?
            if let token {
                draft = MCPDraft.find(token)
                guard draft != nil else { return ok(MCPTools.failure("This Magic edit was stopped or has finished. Stop now.")) }
            }
            guard let model = draft?.model ?? MCPServer.shared.model else {
                return ok(MCPTools.failure("Editroom isn't ready yet."))
            }
            // A Magic run's tool calls drive its thinking show.
            if let draft, let show = MagicThinking.current {
                switch name {
                case "look_at_media", "analyze_media":
                    if let id = (args["asset_id"] as? String).flatMap(UUID.init(uuidString:)) { show.focus(asset: id) }
                case "list_media", "get_project", "list_looks": show.look()
                case "get_frame": show.think()
                default: _ = draft
                }
            }
            let activity = draft != nil && MagicThinking.current != nil
                ? MagicState.shared.begin(activity: describe(name, args, in: model.project)) : nil
            defer {
                if let activity { MagicState.shared.finish(activity: activity) }
                let edits: Set<String> = ["add_clip", "add_title", "move_clip", "trim_clip", "split_clip", "delete_clips", "set_speed", "set_speed_ramp", "set_captions",
                                          "set_grade", "set_audio", "set_transition", "set_sequence", "add_track", "history", "download_media",
                                          "set_marker", "delete_markers", "set_in_out", "set_transform", "set_title_style", "freeze_frame",
                                          "reverse_clip", "detach_audio", "duplicate_clip", "set_track", "add_solid", "set_solid_color"]
                if let draft, edits.contains(name) { MagicThinking.current?.plan(draft.project) }
            }
            do {
                let content = try await MCPTools.call(name, args, model: model, client: client, draft: draft)
                return ok(["content": content, "isError": false])
            } catch {
                return ok(MCPTools.failure((error as? MCPToolError)?.message ?? error.localizedDescription))
            }
        default:
            return MCPServer.error(id, -32601, "Method not found")
        }
    }

    /// What a Magic run's tool call is doing, as the button says it after "Claude is" (nil keeps the
    /// stage word).
    static func describe(_ name: String, _ args: [String: Any], in p: Project) -> String? {
        func short(_ s: String) -> String {
            let base = (s as NSString).deletingPathExtension
            return base.count > 24 ? String(base.prefix(23)) + "…" : base
        }
        func asset(_ key: String = "asset_id") -> String? {
            guard let id = (args[key] as? String).flatMap(UUID.init(uuidString:)),
                  let a = p.assets.first(where: { $0.id == id }) else { return nil }
            return short(a.name)
        }
        func clip() -> String? {
            guard let id = (args["clip_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let c = p.clips.first(where: { $0.id == id }) else { return nil }
            return short(p.name(of: c))
        }
        func quoted(_ key: String) -> String? {
            guard let t = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return "“" + (t.count > 22 ? String(t.prefix(21)) + "…" : t) + "”"
        }
        func on(_ verb: String, _ what: String?) -> String { what.map { "\(verb) \($0)" } ?? verb }
        switch name {
        case "list_media": return "going through the media"
        case "get_project": return "reading the timeline"
        case "list_looks": return "browsing looks"
        case "look_at_media": return on("looking at", asset())
        case "note_media": return on("taking notes on", asset())
        case "analyze_media": return on("studying", asset())
        case "get_transcript": return on("reading what’s said in", asset())
        case "get_frame": return asset().map { "checking a frame of \($0)" } ?? "checking a frame"
        case "search_media":
            if let q = quoted("said") { return "searching for \(q)" }
            return on("searching for", quoted("shows") ?? "a shot")
        case "add_clip": return on("placing", asset())
        case "add_title": return on("adding the title", quoted("text"))
        case "add_solid": return "adding a solid"
        case "move_clip": return on("moving", clip())
        case "trim_clip": return on("trimming", clip())
        case "split_clip": return on("splitting", clip())
        case "delete_clips": return "removing clips"
        case "duplicate_clip": return on("duplicating", clip())
        case "set_speed", "set_speed_ramp": return on("changing the speed of", clip())
        case "reverse_clip": return on("reversing", clip())
        case "freeze_frame": return on("freezing a frame of", clip())
        case "set_grade": return on("grading", clip())
        case "set_audio": return on("mixing", clip())
        case "detach_audio": return on("detaching the sound of", clip())
        case "set_transition": return "adding a transition"
        case "set_transform": return on("framing", clip())
        case "set_title_style": return "styling the title"
        case "set_sequence": return "setting up the sequence"
        case "add_track", "set_track": return "arranging tracks"
        case "set_marker", "delete_markers": return "marking moments"
        case "set_in_out": return "setting the in and out"
        case "download_media": return on("downloading", quoted("name"))
        case "history": return "undoing a step"
        default: return nil
        }
    }
}
