import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

let version = "0.1.0"

func usage() {
    print("""
    deskkontrol \(version) · text-first control of one Mac app or browser window

    usage:
      deskkontrol session [--app Safari] [--new-window] [--allow a.com,b.com] [--no-options]
      deskkontrol open <url>
      deskkontrol focus <app>
      deskkontrol read [--max 80] [--filter text]
      deskkontrol click <id> | --at x,y [--double|--right]
      deskkontrol type <id|focused> "text" [--enter] [--pace fast] [--tier 3]
      deskkontrol key <combo> [--tier 3]
      deskkontrol menu "File > New Folder" [--tier 3]
      deskkontrol scroll up|down [n] [--in id]
      deskkontrol hover <id>
      deskkontrol drag <id> <id>
      deskkontrol upload <id> <path> [--tier 3]
      deskkontrol choose <path>                  drive the open or save dialog on the window
      deskkontrol do <flow> [--key value ...]    run a flow from notes/flows with one approval
      deskkontrol download <id> <path>
      deskkontrol approve <token> [--text "edited text"] | deny <token> | pending
      deskkontrol wait-for "text" [--timeout 10]
      deskkontrol ocr [--crop id|x,y,w,h]
      deskkontrol shot [--crop id|x,y,w,h]
      deskkontrol ask "question" [--choices "A|B|C" [--multi] [--text]]   a little window for Robert; prints his reply
      deskkontrol show "what"                    Robert points the cursor at it; prints the element there
      deskkontrol confirm <token> [--why "…"]    Robert approves or denies a pending step in the little window
      deskkontrol bug "summary" [--repro …] [--cause …] [--fix …]   file a field report in the repo's bugs.md
      deskkontrol policy                         may the LLM use shell commands for macOS tasks? ([agent] ui_only)
      deskkontrol grow [--days 14]               improvement digest: repeated errors, questions asked, open bug reports
      deskkontrol log [--tail n]
      deskkontrol route "task"
      deskkontrol notes ["words"]                      learned app, site and flow notes
      deskkontrol learn "task" [--name slug] [--force]  draft a flow from this session's steps
      deskkontrol run "task" --model <name> [--base-url url] [--screen-anyway] [--save name]
      deskkontrol replay <name> [--from n] [--approve]
      deskkontrol mcp
      deskkontrol serve [--background] | stop

    output is compact text for an agent. add --json for the raw reply.
    open, click, type, key, menu, drag, upload, download, choose and do only propose: they exit 8 with a token,
    and act once you run `deskkontrol approve <token>`.
    exit codes: 0 ok · 2 stale, re-read · 3 Robert denied · 4 blocked or rate limited ·
                5 not found or timeout · 6 interrupted · 7 permission missing · 8 approval needed, nothing done yet
    """)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    usage()
    exit(0)
}
let rest = Array(argv.dropFirst())

func fail(_ error: Error) -> Never {
    if let f = error as? Fail {
        FileHandle.standardError.write(Data((f.message + "\n").utf8))
        exit(f.code)
    }
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    exit(5)
}

func attempt(_ body: () throws -> Void) -> Never {
    do { try body() } catch { fail(error) }
    exit(0)
}

switch command {
case "help", "--help", "-h":
    usage()
    exit(0)
case "version", "--version", "-v":
    print(version)
    exit(0)
case "serve":
    attempt { try Daemon.start(background: rest.contains("--background")) }
case "stop":
    Wire.stopDaemon()
    print("stopped")
    exit(0)
case "route":
    print(Routes.answer(rest.joined(separator: " ")))
    exit(0)
case "notes":
    print(Notes.search(rest.joined(separator: " ")))
    exit(0)
case "learn":
    attempt { print(try Notes.learn(Args.parse(rest))) }
case "bug":
    attempt { print(try Notes.fileBug(Args.parse(rest))) }
case "policy":
    print(Config.policyLine)
    exit(0)
case "grow":
    print(Grow.digest(days: Args.parse(rest).int("days", 14)))
    exit(0)
case "run":
    attempt { try AgentLoop.run(Args.parse(rest)) }
case "replay":
    let a = Args.parse(rest)
    attempt { try Replay.run(a.pos.first ?? "", from: max(a.int("from", 1), 1), approve: a.has("approve")) }
case "mcp":
    MCP.run()
    exit(0)
default:
    do {
        let response = try Wire.send(Request(cmd: command, args: rest))
        if rest.contains("--json") {
            print(String(data: Wire.json(response), encoding: .utf8) ?? "{}")
        } else if !response.out.isEmpty {
            print(response.out)
        }
        exit(response.code)
    } catch {
        fail(error)
    }
}
