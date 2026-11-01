import Foundation

enum MCP {
    static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("session", "Attach to one app window", ["app": ["type": "string"], "new_window": ["type": "boolean"], "allow": ["type": "string"]]),
        tool("read", "Numbered element list for the session window", ["max": ["type": "integer"], "filter": ["type": "string"]]),
        tool("click", "Press an element by number", ["id": ["type": "integer"], "right": ["type": "boolean"], "double": ["type": "boolean"]], ["id"]),
        tool("type", "Type text into an element", ["id": ["type": "integer"], "text": ["type": "string"], "enter": ["type": "boolean"], "pace": ["type": "string"]], ["id", "text"]),
        tool("key", "Send a keyboard shortcut", ["combo": ["type": "string"]], ["combo"]),
        tool("menu", "Pick a menu-bar item, e.g. File > New Folder", ["path": ["type": "string"]], ["path"]),
        tool("scroll", "Scroll the window or an element", ["direction": ["type": "string"], "count": ["type": "integer"], "in": ["type": "integer"]], ["direction"]),
        tool("hover", "Move the pointer over an element", ["id": ["type": "integer"]], ["id"]),
        tool("open", "Navigate the session browser window", ["url": ["type": "string"]], ["url"]),
        tool("wait_for", "Wait for text to appear without reloading", ["text": ["type": "string"], "timeout": ["type": "number"]], ["text"]),
        tool("shot", "Save a PNG of the window or a crop", ["crop": ["type": "string"]]),
        tool("ocr", "OCR the window into numbered lines", ["crop": ["type": "string"]]),
        tool("route", "Check for a faster API, CLI or connector route", ["task": ["type": "string"]], ["task"]),
        tool("choose", "In an open or save dialog, go to a path: picks a file or fills in a new name", ["path": ["type": "string"]], ["path"]),
        tool("do", "Run a flow from notes/flows with one approval. vars: {\"name\": \"value\"} fills {name}", ["flow": ["type": "string"], "vars": ["type": "object"]], ["flow"]),
        tool("ask", "When stuck or deciding, show Robert a little window: free text, or choices (multi for checkboxes, text to add a reply field). Returns his reply",
             ["question": ["type": "string"], "choices": ["type": "array", "items": ["type": "string"]], "multi": ["type": "boolean"], "text": ["type": "boolean"]], ["question"]),
        tool("confirm", "Show Robert a pending step with Approve and Deny; runs it if he approves. Use for ⚠ steps", ["token": ["type": "string"], "why": ["type": "string"]], ["token"]),
        tool("approve", "Run a proposed action. Optional text replaces the text of a proposed type", ["token": ["type": "string"], "text": ["type": "string"]], ["token"]),
        tool("deny", "Drop a proposed action", ["token": ["type": "string"]], ["token"]),
    ]

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let method = msg["method"] as? String else { continue }
            guard let id = msg["id"] else { continue }
            switch method {
            case "initialize":
                reply(id, "result", [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "apprentice", "version": version],
                ])
            case "tools/list":
                reply(id, "result", ["tools": tools])
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text: String
                let isError: Bool
                do {
                    let response = try Wire.send(try map(name, arguments))
                    // Exit 8 is a proposal waiting for approve or deny, not a failure.
                    (text, isError) = (response.out, response.code != 0 && response.code != 8)
                } catch {
                    (text, isError) = ("\(error)", true)
                }
                reply(id, "result", ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                reply(id, "error", ["code": -32601, "message": "method not found"])
            }
        }
    }

    static func map(_ name: String, _ args: [String: Any]) throws -> Request {
        func s(_ key: String, _ fallback: String? = nil) -> String? {
            if let v = args[key] as? String { return v }
            if let n = args[key] as? NSNumber { return n.stringValue }
            return fallback
        }
        func b(_ key: String) -> Bool { args[key] as? Bool ?? false }
        switch name {
        case "session":
            var a: [String] = []
            if let app = s("app") { a += ["--app", app] }
            if b("new_window") { a.append("--new-window") }
            if let allow = s("allow") { a += ["--allow", allow] }
            return Request(cmd: "session", args: a)
        case "read":
            var a: [String] = []
            if let max = s("max") { a += ["--max", max] }
            if let filter = s("filter") { a += ["--filter", filter] }
            return Request(cmd: "read", args: a)
        case "click":
            var a = [s("id") ?? ""]
            if b("right") { a.append("--right") }
            if b("double") { a.append("--double") }
            return Request(cmd: "click", args: a)
        case "type":
            var a = [s("id") ?? "", s("text") ?? ""]
            if b("enter") { a.append("--enter") }
            if let pace = s("pace") { a += ["--pace", pace] }
            return Request(cmd: "type", args: a)
        case "key":
            return Request(cmd: "key", args: [s("combo") ?? ""])
        case "menu":
            return Request(cmd: "menu", args: [s("path") ?? ""])
        case "scroll":
            var a = [s("direction") ?? "down"]
            if let count = s("count") { a.append(count) }
            if let inside = s("in") { a += ["--in", inside] }
            return Request(cmd: "scroll", args: a)
        case "hover":
            return Request(cmd: "hover", args: [s("id") ?? ""])
        case "open":
            return Request(cmd: "open", args: [s("url") ?? ""])
        case "wait_for":
            var a = [s("text") ?? ""]
            if let timeout = s("timeout") { a += ["--timeout", timeout] }
            return Request(cmd: "wait-for", args: a)
        case "shot", "ocr":
            var a: [String] = []
            if let crop = s("crop") { a += ["--crop", crop] }
            return Request(cmd: name, args: a)
        case "route":
            return Request(cmd: "route", args: [s("task") ?? ""])
        case "choose":
            return Request(cmd: "choose", args: [s("path") ?? ""])
        case "do":
            var a = [s("flow") ?? ""]
            for (k, v) in (args["vars"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { a += ["--\(k)", "\(v)"] }
            return Request(cmd: "do", args: a)
        case "ask":
            var a = [s("question") ?? ""]
            if let choices = args["choices"] as? [String], !choices.isEmpty { a += ["--choices", choices.joined(separator: "|")] }
            if b("multi") { a.append("--multi") }
            if b("text") { a.append("--text") }
            return Request(cmd: "ask", args: a)
        case "confirm":
            var a = [s("token") ?? ""]
            if let why = s("why") { a += ["--why", why] }
            return Request(cmd: "confirm", args: a)
        case "approve":
            var a = [s("token") ?? ""]
            if let text = s("text") { a += ["--text", text] }
            return Request(cmd: "approve", args: a)
        case "deny":
            return Request(cmd: "deny", args: [s("token") ?? ""])
        default:
            throw Fail(5, "unknown tool \(name)")
        }
    }

    /// `kind` is "result" or "error".
    static func reply(_ id: Any, _ kind: String, _ body: [String: Any]) {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, kind: body]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
