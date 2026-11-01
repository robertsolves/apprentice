import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

let version = "0.1.0"

func usage() {
    print("""
    apprentice \(version) · text-first control of one Mac app or browser window

    usage:
      apprentice session [--app Safari] [--new-window] [--allow a.com,b.com] [--no-options]
      apprentice open <url>
      apprentice focus <app>
      apprentice read [--max 80] [--filter text]
      apprentice click <id> | --at x,y [--double|--right]
      apprentice type <id|focused> "text" [--enter] [--pace fast] [--tier 3]
      apprentice key <combo> [--tier 3]
      apprentice menu "File > New Folder" [--tier 3]
      apprentice scroll up|down [n] [--in id]
      apprentice hover <id>
      apprentice drag <id> <id>
      apprentice upload <id> <path> [--tier 3]
      apprentice choose <path>                  drive the open or save dialog on the window
      apprentice do <flow> [--key value ...]    run a flow from notes/flows with one approval
      apprentice download <id> <path>
      apprentice approve <token> [--text "edited text"] | deny <token> | pending
      apprentice wait-for "text" [--timeout 10]
      apprentice ocr [--crop id|x,y,w,h]
      apprentice shot [--crop id|x,y,w,h]
      apprentice ask "question" [--choices "A|B|C" [--multi] [--text]]   a little window for Robert; prints his reply
      apprentice show "what"                    Robert points the cursor at it; prints the element there
      apprentice confirm <token> [--why "…"]    Robert approves or denies a pending step in the little window
      apprentice bug "summary" [--repro …] [--cause …] [--fix …]   file a field report in the repo's bugs.md
      apprentice policy                         may the LLM use shell commands for macOS tasks? ([agent] ui_only)
      apprentice awake on|off|status            keep the Mac from idle sleep and locking while tasks run
      apprentice away on|off|status             Robert is away: questions come back as exit 9 for the chat
      apprentice grow [--days 14]               improvement digest: repeated errors, questions asked, open bug reports
      apprentice log [--tail n]
      apprentice route "task"
      apprentice notes ["words"]                      learned app, site and flow notes
      apprentice learn "task" [--name slug] [--force]  draft a flow from this session's steps
      apprentice run "task" --model <name> [--base-url url] [--screen-anyway] [--save name]
      apprentice replay <name> [--from n] [--approve]
      apprentice mcp
      apprentice serve [--background] | stop

    output is compact text for an agent. add --json for the raw reply.
    open, click, type, key, menu, drag, upload, download, choose and do only propose: they exit 8 with a token,
    and act once you run `apprentice approve <token>`.
    exit codes: 0 ok · 2 stale, re-read · 3 Robert denied · 4 blocked or rate limited ·
                5 not found or timeout · 6 interrupted · 7 permission missing · 8 approval needed, nothing done yet ·
                9 ask Robert in the chat (he is away or did not answer the window)
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
