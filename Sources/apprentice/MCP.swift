import Foundation

enum MCP {
    /// A tool's description comes from `agent/commands.toml`, like every other word about a command.
    static func tool(_ name: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": Help.mcpDescription(name),
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("session", ["app": ["type": "string"], "on": ["type": "string"], "new_window": ["type": "boolean"], "allow": ["type": "string"]]),
        tool("read", ["max": ["type": "integer"], "filter": ["type": "string"]]),
        tool("click", ["id": ["type": "integer"], "on": ["type": "string"], "at": ["type": "string"], "right": ["type": "boolean"], "double": ["type": "boolean"]]),
        tool("type", ["id": ["type": "integer"], "text": ["type": "string"], "enter": ["type": "boolean"], "pace": ["type": "string"],
              "secret": ["type": "string"], "code": ["type": "string"]], ["id"]),
        tool("key", ["combo": ["type": "string"]], ["combo"]),
        tool("menu", ["path": ["type": "string"]], ["path"]),
        tool("scroll", ["direction": ["type": "string"], "count": ["type": "integer"], "in": ["type": "integer"], "at": ["type": "string"]], ["direction"]),
        tool("browse", ["seconds": ["type": "integer"], "in": ["type": "integer"]], []),
        tool("hover", ["id": ["type": "integer"]], ["id"]),
        tool("open", ["url": ["type": "string"]], ["url"]),
        tool("wait_for", ["text": ["type": "string"], "timeout": ["type": "number"]], ["text"]),
        tool("shot", ["crop": ["type": "string"], "marks": ["type": "boolean"]]),
        tool("ocr", ["crop": ["type": "string"]]),
        tool("route", ["task": ["type": "string"]], ["task"]),
        tool("schedule", ["action": ["type": "string"], "name": ["type": "string"], "id": ["type": "string"],
              "at": ["type": "string"], "every": ["type": "string"], "daily": ["type": "string"],
              "weekly": ["type": "string"], "cron": ["type": "string"], "prompt": ["type": "string"],
              "run": ["type": "string"], "do": ["type": "string"], "sh": ["type": "string"],
              "dir": ["type": "string"], "vm": ["type": "string"], "model": ["type": "string"],
              "agent": ["type": "string"], "jitter": ["type": "string"], "site": ["type": "string"]], ["action"]),
        tool("done", ["summary": ["type": "string"]], []),
        tool("focus", ["app": ["type": "string"], "on": ["type": "string"]], ["app"]),
        tool("drag", ["from": ["type": "integer"], "to": ["type": "integer"], "by": ["type": "string"], "in": ["type": "integer"], "at": ["type": "string"]], []),
        tool("upload", ["id": ["type": "integer"], "path": ["type": "string"]], ["id", "path"]),
        tool("download", ["id": ["type": "integer"], "path": ["type": "string"]], ["id", "path"]),
        tool("log", ["tail": ["type": "integer"], "session": ["type": "string"]]),
        tool("sessions", ["limit": ["type": "integer"]]),
        tool("prefs", ["query": ["type": "string"]]),
        tool("remember", ["key": ["type": "string"], "value": ["type": "string"], "from": ["type": "string"]], ["key", "value", "from"]),
        tool("pending", [:]),
        tool("resume", [:]),
        tool("playbooks", ["query": ["type": "string"]]),
        tool("learn", ["task": ["type": "string"], "name": ["type": "string"]], ["task"]),
        tool("show", ["what": ["type": "string"]], ["what"]),
        tool("away", ["state": ["type": "string"]], ["state"]),
        tool("phone", ["state": ["type": "string"]]),
        tool("policy", ["domain": ["type": "string"]]),
        tool("budget", ["domain": ["type": "string"]]),
        tool("pace", ["site": ["type": "string"], "style": ["type": "string", "enum": ["fastest", "fast", "steady", "careful", "default"]]]),
        tool("choose", ["path": ["type": "string"]], ["path"]),
        tool("do", ["flow": ["type": "string"], "vars": ["type": "object"], "explain": ["type": "string"]]),
        tool("ask", ["question": ["type": "string"], "choices": ["type": "array", "items": ["type": "string"]], "multi": ["type": "boolean"], "text": ["type": "boolean"],
              "optional": ["type": "boolean"], "assume": ["type": "string"]], ["question"]),
        tool("pref", ["key": ["type": "string"], "for": ["type": "string"], "choices": ["type": "array", "items": ["type": "string"]], "multi": ["type": "boolean"],
              "assume": ["type": "string"], "question": ["type": "string"]], ["key"]),
        tool("voice", [:]),
        tool("confirm", ["token": ["type": "string"], "why": ["type": "string"]], ["token"]),
        tool("approve", ["token": ["type": "string"], "text": ["type": "string"]], ["token"]),
        tool("deny", ["token": ["type": "string"]], ["token"]),
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
                // An app with no shell (Claude desktop, Cursor) names itself here when nothing else did.
                if Request.callerModel == nil, let client = ((msg["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String {
                    Request.callerModel = client
                    Store.model = client
                }
                reply(id, "result", [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "apprentice", "version": version],
                ])
            case "tools/list":
                reply(id, "result", ["tools": tools])
            case "ping":
                // A liveness check gets an empty result, not "method not found" (B25).
                reply(id, "result", [:])
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text: String
                let isError: Bool
                do {
                    // These run in this process, like the CLI does them.
                    if let local = try runLocally(name, arguments) {
                        reply(id, "result", ["content": [["type": "text", "text": local]], "isError": false])
                        continue
                    }
                    let response = try Wire.send(try map(name, arguments))
                    // Exit 8 is a proposal waiting for approve or deny, not a failure. The exit code is part of
                    // the agent contract (stale, stop, ask in the chat…), so a tool call names it as the CLI does.
                    let code = response.code == 0 ? "" : "\n(exit \(response.code))"
                    (text, isError) = (response.out + code, response.code != 0 && response.code != 8)
                } catch {
                    (text, isError) = ("\(error)", true)
                }
                reply(id, "result", ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                reply(id, "error", ["code": -32601, "message": "method not found"])
            }
        }
    }

    static func runLocally(_ name: String, _ args: [String: Any]) throws -> String? {
        switch name {
        case "playbooks", "notes": return Playbooks.search(args["query"] as? String ?? "")
        case "learn":
            var a = [args["task"] as? String ?? ""]
            if let n = args["name"] as? String { a += ["--name", n] }
            return try Playbooks.learn(Args.parse(a))
        case "sessions": return Sessions.list(Args.parse((args["limit"] as? Int).map { ["--limit", "\($0)"] } ?? []))
        case "prefs": return Prefs.list(Args.parse([args["query"] as? String ?? ""]))
        case "remember":
            return try Prefs.remember(Args.parse([args["key"] as? String ?? "", args["value"] as? String ?? "", "--from", args["from"] as? String ?? ""]))
        case "policy": return (args["domain"] as? String).map(Policies.describe) ?? Config.policyLine
        case "budget": return Budgets.report(args["domain"] as? String)
        case "pace": return try PaceStyles.run(Args.parse([args["site"] as? String, args["style"] as? String].compactMap { $0 }))
        default: return nil
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
            if let on = s("on") { a += ["--on", on] }
            if b("new_window") { a.append("--new-window") }
            if let allow = s("allow") { a += ["--allow", allow] }
            return Request(cmd: "session", args: a)
        case "read":
            var a: [String] = []
            if let max = s("max") { a += ["--max", max] }
            if let filter = s("filter") { a += ["--filter", filter] }
            return Request(cmd: "read", args: a)
        case "click":
            var a = s("on").map { ["--on", $0] } ?? s("at").map { ["--at=\($0)"] } ?? [s("id") ?? ""]
            if b("right") { a.append("--right") }
            if b("double") { a.append("--double") }
            return Request(cmd: "click", args: a)
        case "type":
            var a = [s("id") ?? ""] + (s("text").map { [$0] } ?? [])
            if let secret = s("secret") { a += ["--secret", secret] }
            if let code = s("code") { a += ["--code", code] }
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
            if let at = s("at") { a += ["--at", at] }
            return Request(cmd: "scroll", args: a)
        case "hover":
            return Request(cmd: "hover", args: [s("id") ?? ""])
        case "browse":
            var a: [String] = []
            if let seconds = s("seconds") { a.append(seconds) }
            if let inside = s("in") { a += ["--in", inside] }
            return Request(cmd: "browse", args: a)
        case "open":
            return Request(cmd: "open", args: [s("url") ?? ""])
        case "wait_for":
            var a = [s("text") ?? ""]
            if let timeout = s("timeout") { a += ["--timeout", timeout] }
            return Request(cmd: "wait-for", args: a)
        case "shot", "ocr":
            var a: [String] = []
            if let crop = s("crop") { a += ["--crop", crop] }
            if name == "shot", args["marks"] as? Bool == true { a.append("--marks") }
            return Request(cmd: name, args: a)
        case "route":
            return Request(cmd: "route", args: [s("task") ?? ""])
        case "schedule":
            var a = [s("action") ?? "list"]
            if let name = s("name") { a.append(name) }
            if let id = s("id") { a += ["--id", id] }
            for key in ["at", "every", "daily", "weekly", "cron", "prompt", "run", "do", "sh", "dir", "vm", "model", "agent", "jitter", "site"] {
                if let value = s(key) { a += ["--\(key)", value] }
            }
            return Request(cmd: "schedule", args: a)
        case "done":
            return Request(cmd: "done", args: s("summary").map { [$0] } ?? [])
        case "focus":
            return Request(cmd: "focus", args: [s("app") ?? ""] + (s("on").map { ["--on", $0] } ?? []))
        case "drag":
            if let by = s("by") {
                var a = ["--by=\(by)"]
                if let inside = s("in") { a += ["--in", inside] }
                if let at = s("at") { a += ["--at=\(at)"] }
                return Request(cmd: "drag", args: a)
            }
            return Request(cmd: "drag", args: [s("from") ?? "", s("to") ?? ""])
        case "upload", "download":
            return Request(cmd: name, args: [s("id") ?? "", s("path") ?? ""])
        case "log":
            return Request(cmd: "log", args: (s("tail").map { ["--tail", $0] } ?? []) + (s("session").map { ["--session", $0] } ?? []))
        case "pending":
            return Request(cmd: "pending")
        case "resume":
            return Request(cmd: "resume")
        case "show":
            return Request(cmd: "show", args: [s("what") ?? ""])
        case "away":
            return Request(cmd: "away", args: [s("state") ?? "status"])
        case "phone":
            return Request(cmd: "phone", args: [s("state") ?? "on"])
        case "choose":
            return Request(cmd: "choose", args: [s("path") ?? ""])
        case "do":
            if let task = s("explain") { return Request(cmd: "do", args: ["--explain", task]) }
            var a = [s("flow") ?? ""]
            for (k, v) in (args["vars"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { a += ["--\(k)", "\(v)"] }
            return Request(cmd: "do", args: a)
        case "ask":
            var a = [s("question") ?? ""]
            if let choices = args["choices"] as? [String], !choices.isEmpty { a += ["--choices", choices.joined(separator: "|")] }
            if b("multi") { a.append("--multi") }
            if b("text") { a.append("--text") }
            if b("optional") { a.append("--optional") }
            if let assume = s("assume") { a += ["--assume", assume] }
            return Request(cmd: "ask", args: a)
        case "pref":
            var a = [s("key") ?? ""]
            if let scope = s("for") { a += ["--for", scope] }
            if let choices = args["choices"] as? [String], !choices.isEmpty { a += ["--choices", choices.joined(separator: "|")] }
            if b("multi") { a.append("--multi") }
            if let assume = s("assume") { a += ["--assume", assume] }
            if let question = s("question") { a += ["--question", question] }
            return Request(cmd: "pref", args: a)
        case "voice":
            return Request(cmd: "voice")
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
