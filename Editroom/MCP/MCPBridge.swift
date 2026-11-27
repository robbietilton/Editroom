import AppKit
import Foundation

/// `Editroom --mcp`: for agents that start their tools as a program and talk over stdin and stdout
/// (Claude Desktop, Codex). Each line in is passed to the running app's MCP server and its reply is
/// written back. While Editroom is closed, everything but using a tool is answered here, so an agent
/// starting up or idling (a new chat, the app opening, its checks now and then) doesn't open Editroom;
/// the first tool it uses opens it. Nothing else is ever written to stdout.
enum MCPBridge {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let endpoint = URL(string: MCPServer.endpoint)!
        var session: String?
        var launched = false
        // Which app started this (from its launcher), so Editroom can turn away a disconnected one.
        let args = CommandLine.arguments
        let from = args.firstIndex(of: "--from").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

        func post(_ line: Data) -> (Data?, Int) {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.httpBody = line
            req.timeoutInterval = 600
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            if let from { req.setValue(from, forHTTPHeaderField: "X-Editroom-From") }
            let done = DispatchSemaphore(value: 0)
            var body: Data?, status = 0
            URLSession.shared.dataTask(with: req) { data, response, _ in
                if let http = response as? HTTPURLResponse {
                    status = http.statusCode
                    if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
                }
                body = data
                done.signal()
            }.resume()
            done.wait()
            return (body, status)
        }

        /// The agent's hello, answered here while Editroom was closed: given to Editroom once it's open, so
        /// it knows which agent this is (its name on the cursor).
        var heldHello: Data?

        func launchApp() {
            guard !launched else { return }
            launched = true
            // The .app this program lives in; opened without taking focus.
            let bundle = Bundle.main.bundleURL
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            let opened = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in opened.signal() }
            _ = opened.wait(timeout: .now() + 10)
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let data = Data(line.utf8)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let id = json?["id"]
            let method = json?["method"] as? String ?? ""
            var reply: Data?
            // Anything but using a tool: Editroom's own answer if it's open; with it closed, answered here (what
            // it would say, or that it doesn't do that), and Editroom isn't opened.
            if let json, !MCPHandler.opensEditroom(method) {
                let (body, status) = post(data)
                if status == 200 || status == 202 {
                    reply = status == 200 ? body : nil
                } else if status == 0 {
                    if method == "initialize" { heldHello = data }
                    // A reply to something asked of the agent (no method) or a notification needs no answer.
                    if !method.isEmpty, id != nil {
                        let answer = MainActor.assumeIsolated { MCPHandler.handshake(json) }
                            ?? ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "Method not found: \(method)"]]
                        reply = try? JSONSerialization.data(withJSONObject: answer)
                    }
                } else {
                    reply = body
                }
                if let reply, id != nil, var out = String(data: reply, encoding: .utf8) {
                    out = out.replacingOccurrences(of: "\n", with: " ")
                    FileHandle.standardOutput.write(Data((out + "\n").utf8))
                }
                continue
            }
            // Up to about 20 seconds for the app to start and begin listening.
            for attempt in 0..<80 {
                // Editroom opened for this: it hears the agent's hello first.
                if let hello = heldHello {
                    let (_, status) = post(hello)
                    if status == 0 {
                        launchApp()
                        Thread.sleep(forTimeInterval: 0.25)
                        continue
                    }
                    heldHello = nil
                }
                let (body, status) = post(data)
                if status == 200 || status == 202 { reply = status == 200 ? body : nil; launched = false; break }
                if status == 0 {
                    launchApp()
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                // The server answered with an error: report it rather than retrying.
                reply = body
                _ = attempt
                break
            }
            if reply == nil, id != nil {
                let err: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                                          "error": ["code": -32000, "message": "Editroom isn't answering. Open Editroom and turn on AI Agents (Editroom menu > AI Agents…)."]]
                reply = try? JSONSerialization.data(withJSONObject: err)
            }
            if let reply, id != nil, var out = String(data: reply, encoding: .utf8) {
                out = out.replacingOccurrences(of: "\n", with: " ")
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
        exit(0)
    }
}
