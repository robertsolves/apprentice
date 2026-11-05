import AppKit
import Darwin
import SwiftUI

/// A terminal tab's pty: the user's login shell (`$SHELL -l`) in a folder, optionally with a start command
/// such as `claude`. It is a child of the app's process, never of the daemon, so a stuck terminal cannot
/// take a pending approval down with it.
final class Pty {
    /// Every use of `fd` (read, write, resize) runs on `queue`, and only the read source's cancel handler
    /// closes it, so a write can never land on a closed or reused descriptor.
    private var fd: Int32 = -1
    private(set) var pid: pid_t = 0
    /// The process group the terminal is running in front: the shell's own while it waits at a prompt.
    var foreground: pid_t { queue.sync { fd >= 0 ? tcgetpgrp(fd) : -1 } }
    private let queue = DispatchQueue(label: "apprentice.pty")
    private var source: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var args: [UnsafeMutablePointer<CChar>?] = []
    private var envp: [UnsafeMutablePointer<CChar>?] = []
    let onData: (Data) -> Void
    let onExit: (Int32) -> Void

    init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
         args argvRaw: [String] = ["-l"], dir: URL, env extra: [String: String] = [:],
         cols: Int = 100, rows: Int = 30,
         onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) {
        self.onData = onData
        self.onExit = onExit
        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { onExit(127); return }
        guard let name = ttyname(slave).map({ String(cString: $0) }) else {
            close(master); close(slave); onExit(127); return
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // macOS does not make a terminal controlling just by opening it after `setsid`, and posix_spawn has no action
        // for the ioctl that does, so the child starts as `apprentice __pty` (top of main.swift), which takes it and
        // becomes the shell. That is what lets ctrl+C reach the foreground job, a resize send it SIGWINCH, closing the
        // tab hang up its children, and the tab tell what is running in it.
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, dir.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        // The tab's shell answers for itself: an agent in it never borrows the app's Accessibility grant to
        // click the app's own Allow (`responsibility_spawnattrs_setdisclaim`, as Terminal does).
        Own.disclaim(&attr)

        var env = ProcessInfo.processInfo.environment
        // The tab knows which project and VM it belongs to, so an agent started here needs no setup.
        if let project = Project.find(from: dir.path) { env["APPRENTICE_PROJECT"] = project.path }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "apprentice"
        for (k, v) in extra { env[k] = v }
        envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let starter = Wire.binaryPath()
        args = ([starter, "__pty", shell] + argvRaw).map { strdup($0) } + [nil]

        var child: pid_t = 0
        let spawn = posix_spawn(&child, starter, &actions, &attr, args, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(slave)
        // A tab whose shell or folder cannot start says so instead of staying blank.
        guard spawn == 0 else { close(master); onExit(127); return }
        fd = master
        pid = child
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [weak self, master] in
            close(master)
            self?.fd = -1
        }
        src.resume()
        source = src
        // The child is reaped when it exits, whether it ends by itself or the tab is closed. The handler holds
        // the Pty until then, so a closed tab never leaves a zombie.
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            drain()
            source?.cancel()
            source = nil
            exitSource?.cancel()
            exitSource = nil
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            onExit(code)
        }
        exit.resume()
        exitSource = exit
    }

    /// Reads what is there now; end of file is left to the exit handler, which reaps the child.
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                onData(Data(buffer[0..<n]))
                if n < buffer.count { return }
            } else {
                if n == 0 || (errno != EAGAIN && errno != EINTR) { source?.cancel(); source = nil }
                return
            }
        }
    }

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(self.fd, base.advanced(by: sent), raw.count - sent)
                    if n < 0, errno == EAGAIN || errno == EINTR { usleep(2000); continue }
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
    }

    func write(_ text: String) { write(Data(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            // The kernel sends SIGWINCH to the foreground job of the controlling terminal.
            var size = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.fd, TIOCSWINSZ, &size)
        }
    }

    func terminate() {
        let pid = pid
        queue.async { [weak self] in
            // The shell leads its own session and process group: the hangup reaches its jobs too.
            if pid > 0 { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
            self?.source?.cancel()
            self?.source = nil
        }
    }

    deinit {
        args.forEach { free($0) }
        envp.forEach { free($0) }
    }
}

/// One character cell: the text (a grapheme, so combining marks and emoji stay whole), its colour and its
/// emphasis. A wide character leaves the cell beside it empty.
struct TermCell {
    var text = " "
    var fg: Int32?      // 0…255 palette, or 0x1000000 | rgb
    var bg: Int32?
    var bold = false
    var italic = false
    var underline = false
    var inverse = false
    var wide = false
}

/// A line of cells; `dirty` lets the view redraw only what changed.
struct TermLine {
    var cells: [TermCell]
    var dirty = true
}

/// A small xterm: the control sequences Claude Code, Codex and a shell actually use (alternate screen, 256
/// colours and truecolor, cursor addressing, erase, scroll regions, insert/delete), rendered as text. It is
/// deliberately not a VT100 emulator for every mode: mouse reporting and bracketed paste are accepted and
/// ignored, so nothing is broken by them.
final class TermScreen {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [TermLine]
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    /// DECCKM: a full-screen program asked for `ESC O A` arrow keys instead of `ESC [ A`.
    private(set) var appCursorKeys = false
    /// The program asked for mouse reports (1000, 1002, 1003): the wheel goes to it, not to the scrollback.
    private(set) var mouseTracking = false
    /// Mouse reports in the SGR form (1006), `ESC [ < b ; x ; y M`.
    private(set) var sgrMouse = false
    /// Pasted text is wrapped in `ESC [ 200~ … ESC [ 201~` (2004), so a multi-line paste is not run line by line.
    private(set) var bracketedPaste = false
    /// The program wants `ESC [ I` and `ESC [ O` when the tab gains and loses the keyboard (1004).
    private(set) var focusEvents = false
    private(set) var title = ""
    var scrollback: [[TermCell]] = []
    let maxScrollback = 3000

    private var attr = TermCell()
    private var saved: (x: Int, y: Int, attr: TermCell)?
    private var scrollTop = 0
    private var scrollBottom: Int
    private(set) var alt = false
    private var altSaved: ([TermLine], Int, Int)?
    private var wrapPending = false
    private var state = 0   // 0 ground, 1 after ESC, 2 in CSI, 3 in OSC, 4 in OSC after ESC, 5 ESC intermediate
    private var csi = ""
    private var osc = ""
    private var pending = Data()
    /// Answers to the program's queries (cursor position, device attributes), written back to the pty.
    var reply: ((String) -> Void)?

    init(cols: Int = 100, rows: Int = 30) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        grid = (0..<rows).map { _ in TermLine(cells: Array(repeating: TermCell(), count: cols)) }
    }

    func blank() -> TermCell {
        var c = TermCell()
        c.fg = attr.fg
        c.bg = attr.bg
        return c
    }

    func feed(_ data: Data) {
        pending.append(data)
        // A multi-byte character can be split across reads: its start waits for the next read. Anything
        // else that is not UTF-8 (a binary on `cat`) draws as U+FFFD instead of stopping the screen.
        let keep = TermScreen.incompleteTail(pending)
        let ready = pending.prefix(pending.count - keep)
        pending = Data(pending.suffix(keep))
        for ch in String(decoding: ready, as: UTF8.self) { step(ch) }
    }

    /// How many bytes at the end start a UTF-8 character that is not complete yet (0…3).
    static func incompleteTail(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for back in 1...max(1, bytes.count) where back <= bytes.count {
            let b = bytes[bytes.count - back]
            if b & 0xC0 == 0x80 { continue }   // a continuation byte: look further back
            let need = b & 0xE0 == 0xC0 ? 2 : b & 0xF0 == 0xE0 ? 3 : b & 0xF8 == 0xF0 ? 4 : 1
            return need > back ? back : 0
        }
        return 0
    }

    private func step(_ ch: Character) {
        switch state {
        case 0:
            if ch == "\u{1b}" { state = 1; return }
            control(ch) ? () : put(String(ch))
        case 1:
            state = 0
            switch ch {
            case "[": state = 2; csi = ""
            case "]": state = 3; osc = ""
            case "7": saved = (cursorX, cursorY, attr)
            case "8": if let s = saved { (cursorX, cursorY, attr) = (s.x, s.y, s.attr) }
            case "M":
                // Reverse index: at the top margin the region moves down, as `less` does scrolling back.
                if cursorY == scrollTop { scrollDown(1) } else { cursorY = max(0, cursorY - 1) }
            case "D":
                lineFeed()
            case "E":
                cursorX = 0; lineFeed()
            case "c": reset()
            // ESC ( B and the like choose a character set: the byte after it is part of the sequence.
            case " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/": state = 5
            default: break   // keypad modes change nothing here
            }
        case 2:
            if ch.isLetter || ch == "@" || ch == "`" || ch == "~" || ch == "{" || ch == "|" || ch == "}" {
                state = 0
                csiApply(csi, ch)
            } else {
                csi.append(ch)
            }
        case 3:
            if ch == "\u{07}" { state = 0; oscApply() }
            else if ch == "\u{1b}" { state = 4 }
            else { osc.append(ch) }
        case 4:
            state = 0
            if ch == "\\" { oscApply() }
        default:
            state = 0
        }
    }

    /// True when `ch` was a control character (and so is not printed).
    private func control(_ ch: Character) -> Bool {
        switch ch {
        // Swift reads CRLF as one Character (it is one grapheme), and most TUIs emit it.
        case "\r\n": cursorX = 0; lineFeed()
        case "\r": cursorX = 0; wrapPending = false
        case "\n", "\u{0B}", "\u{0C}": lineFeed()
        case "\u{07}": break
        case "\u{08}": cursorX = max(0, cursorX - 1); wrapPending = false
        case "\t": cursorX = min(cols - 1, (cursorX / 8 + 1) * 8); wrapPending = false
        case "\u{0E}", "\u{0F}": break
        default:
            if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7f { return true }
            return false
        }
        return true
    }

    private func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom { scrollUp(1) } else if cursorY < rows - 1 { cursorY += 1 }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<n {
            if !alt, scrollTop == 0 {
                scrollback.append(grid[0].cells)
                if scrollback.count > maxScrollback { scrollback.removeFirst(scrollback.count - maxScrollback) }
            }
            grid.remove(at: scrollTop)
            grid.insert(TermLine(cells: Array(repeating: blank(), count: cols)), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<n {
            grid.remove(at: scrollBottom)
            grid.insert(TermLine(cells: Array(repeating: blank(), count: cols)), at: scrollTop)
        }
    }

    private func put(_ text: String) {
        let width = TermScreen.width(text)
        guard width > 0 else {
            if cursorX > 0 { grid[cursorY].cells[cursorX - 1].text += text }
            return
        }
        if wrapPending, cursorX + width > cols { cursorX = 0; lineFeed() }
        wrapPending = false
        if cursorX + width > cols {
            cursorX = max(0, cols - width)
        }
        var cell = attr
        cell.text = text
        cell.wide = width == 2
        // Writing over half of a wide character blanks its other half, so the line keeps its columns.
        let line = grid[cursorY].cells
        if line[cursorX].wide, line[cursorX].text.isEmpty, cursorX > 0 { grid[cursorY].cells[cursorX - 1] = blank() }
        let end = cursorX + width
        if end < cols, line[end].wide, line[end].text.isEmpty { grid[cursorY].cells[end] = blank() }
        grid[cursorY].cells[cursorX] = cell
        if width == 2, cursorX + 1 < cols {
            var filler = cell
            filler.text = ""
            filler.wide = true
            grid[cursorY].cells[cursorX + 1] = filler
        }
        grid[cursorY].dirty = true
        cursorX += width
        if cursorX >= cols { cursorX = cols - 1; wrapPending = true }
    }

    /// 1 or 2 columns; enough for CJK, Hangul, emoji and the box-drawing characters a TUI uses in one.
    static func width(_ s: String) -> Int {
        guard let scalar = s.unicodeScalars.first else { return 1 }
        let v = scalar.value
        if v < 0x20 { return 0 }
        if (0x300...0x36F).contains(v) { return 0 }        // combining marks
        if v == 0x200B || v == 0x200D || v == 0xFEFF { return 0 }
        let wide: [(UInt32, UInt32)] = [(0x1100, 0x115F), (0x2E80, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
                                        (0xFE30, 0xFE6F), (0xFF00, 0xFF60), (0xFFE0, 0xFFE6), (0x1F300, 0x1FAFF),
                                        (0x1F900, 0x1F9FF), (0x20000, 0x3FFFD)]
        return wide.contains { v >= $0.0 && v <= $0.1 } ? 2 : 1
    }

    private func reset() {
        attr = TermCell()
        (cursorX, cursorY) = (0, 0)
        scrollTop = 0
        scrollBottom = rows - 1
        grid = (0..<rows).map { _ in TermLine(cells: Array(repeating: TermCell(), count: cols)) }
        scrollback.removeAll()
        alt = false
        altSaved = nil
        (appCursorKeys, mouseTracking, sgrMouse, bracketedPaste, focusEvents) = (false, false, false, false, false)
    }

    private func oscApply() {
        // OSC 0 and 2 set the title; 8 and 52 (link, clipboard) are deliberately ignored.
        let parts = osc.split(separator: ";", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" { title = parts[1] }
        osc = ""
    }

    private func csiApply(_ raw: String, _ final: Character) {
        // A leading ? is a private mode (alternate screen, cursor visibility, paste, wrapping). `>`, `<` and
        // `=` belong to other protocols (modifyOtherKeys, the kitty keyboard), and an intermediate byte such as
        // the space in `CSI 2 SP q` (cursor shape) names another command: none of them may run as the plain one.
        var body = raw
        var priv = false
        if body.hasPrefix("?") { priv = true; body.removeFirst() }
        if body.hasPrefix(">") {
            if final == "c" { reply?("\u{1b}[>0;10;1c") }   // secondary device attributes
            return
        }
        if body.hasPrefix("<") || body.hasPrefix("=") { return }
        guard body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";" || $0 == ":") }) else { return }
        // Colon subparameters (`4:3`, `38:2::r:g:b`) stay with their parameter.
        let groups = body.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 } }
        let params = groups.map { $0.first ?? 0 }
        func p(_ i: Int, _ fallback: Int = 1) -> Int { i < params.count && params[i] != 0 ? params[i] : fallback }
        switch final {
        case "A": cursorY = max(scrollTop, cursorY - p(0)); wrapPending = false
        case "B": cursorY = min(scrollBottom, cursorY + p(0)); wrapPending = false
        case "C": cursorX = min(cols - 1, cursorX + p(0)); wrapPending = false
        case "D": cursorX = max(0, cursorX - p(0)); wrapPending = false
        case "E": cursorY = min(scrollBottom, cursorY + p(0)); cursorX = 0
        case "F": cursorY = max(scrollTop, cursorY - p(0)); cursorX = 0
        case "G", "`": cursorX = min(cols - 1, max(0, p(0) - 1))
        case "d": cursorY = min(rows - 1, max(0, p(0) - 1))
        case "H", "f":
            cursorY = min(rows - 1, max(0, p(0) - 1))
            cursorX = min(cols - 1, max(0, p(1) - 1))
            wrapPending = false
        case "J":
            let mode = params.first ?? 0
            if mode == 2 || mode == 3 {
                grid = (0..<rows).map { _ in TermLine(cells: Array(repeating: blank(), count: cols)) }
            } else if mode == 0 {
                eraseLine(0)
                for y in (cursorY + 1)..<rows { grid[y] = TermLine(cells: Array(repeating: blank(), count: cols)) }
            } else {
                for y in 0..<cursorY { grid[y] = TermLine(cells: Array(repeating: blank(), count: cols)) }
                eraseLine(1)
            }
        case "K": eraseLine(params.first ?? 0)
        case "X":
            for x in cursorX..<min(cols, cursorX + p(0)) { grid[cursorY].cells[x] = blank() }
            grid[cursorY].dirty = true
        case "@":
            let n = p(0)
            for _ in 0..<n { grid[cursorY].cells.insert(blank(), at: cursorX); grid[cursorY].cells.removeLast() }
            grid[cursorY].dirty = true
        case "P":
            let n = p(0)
            for _ in 0..<n { grid[cursorY].cells.remove(at: cursorX); grid[cursorY].cells.append(blank()) }
            grid[cursorY].dirty = true
        case "L", "M":
            // Outside the scroll region, insert and delete line do nothing (as in xterm).
            guard (scrollTop...scrollBottom).contains(cursorY) else { break }
            let n = min(p(0), scrollBottom - cursorY + 1)
            for _ in 0..<n {
                if final == "L" {
                    grid.insert(TermLine(cells: Array(repeating: blank(), count: cols)), at: cursorY)
                    grid.remove(at: scrollBottom + 1)
                } else {
                    grid.remove(at: cursorY)
                    grid.insert(TermLine(cells: Array(repeating: blank(), count: cols)), at: scrollBottom)
                }
            }
            for y in cursorY...scrollBottom { grid[y].dirty = true }
        case "S": scrollUp(p(0))
        case "T": scrollDown(p(0))
        case "r":
            let top = max(0, p(0) - 1)
            let bottom = min(rows - 1, (params.count > 1 ? p(1, rows) : rows) - 1)
            if top < bottom { scrollTop = top; scrollBottom = bottom; (cursorX, cursorY) = (0, top) }
        case "m": sgr(TermScreen.flatten(groups))
        case "h", "l":
            let on = final == "h"
            if priv {
                for value in params {
                    switch value {
                    case 1049, 47, 1047: setAlt(on)
                    case 25: cursorVisible = on
                    case 1: appCursorKeys = on
                    case 1000, 1002, 1003: mouseTracking = on
                    case 1006: sgrMouse = on
                    case 2004: bracketedPaste = on
                    case 1004: focusEvents = on
                    default: break
                    }
                }
            }
        // `CSI ? u` is the kitty keyboard query and `CSI ? … s` saves private modes: neither touches the
        // cursor. Read as a restore, the query sent Claude Code's redraws to the top rows, so a menu's
        // selection never moved on screen.
        case "s": if !priv { saved = (cursorX, cursorY, attr) }
        case "u": if !priv, let s = saved { (cursorX, cursorY, attr) = (s.x, s.y, s.attr) }
        case "n":
            // Device status: 5 asks "are you there", 6 asks where the cursor is.
            if !priv, params.first == 5 { reply?("\u{1b}[0n") }
            if !priv, params.first == 6 { reply?("\u{1b}[\(cursorY + 1);\(cursorX + 1)R") }
        case "c":
            if !priv, (params.first ?? 0) == 0 { reply?("\u{1b}[?62;22c") }   // primary device attributes
        default: break
        }
    }

    /// SGR parameters with colon groups written the way `sgr` reads them: `38:2::r:g:b` as 38;2;r;g;b,
    /// `38:5:n` as 38;5;n, an underline style `4:n` as on or off, anything else as its first number.
    static func flatten(_ groups: [[Int]]) -> [Int] {
        groups.flatMap { g -> [Int] in
            guard g.count > 1 else { return g }
            switch g[0] {
            case 38, 48, 58:
                if g.count >= 3, g[1] == 5 { return [g[0], 5, g[2]] }
                if g.count >= 5, g[1] == 2 { return [g[0], 2] + Array(g.suffix(3)) }
                return []
            case 4: return [g[1] == 0 ? 24 : 4]
            default: return [g[0]]
            }
        }
    }

    private func setAlt(_ on: Bool) {
        if on, !alt {
            altSaved = (grid, cursorX, cursorY)
            grid = (0..<rows).map { _ in TermLine(cells: Array(repeating: blank(), count: cols)) }
            alt = true
            (cursorX, cursorY) = (0, 0)
        } else if !on, alt {
            if let saved = altSaved {
                grid = saved.0
                (cursorX, cursorY) = (saved.1, saved.2)
            }
            alt = false
            altSaved = nil
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0:
            for x in cursorX..<cols { grid[cursorY].cells[x] = blank() }
        case 1:
            for x in 0...min(cursorX, cols - 1) { grid[cursorY].cells[x] = blank() }
        default:
            grid[cursorY].cells = Array(repeating: blank(), count: cols)
        }
        grid[cursorY].dirty = true
    }

    private func sgr(_ params: [Int]) {
        if params.isEmpty { attr = TermCell(); return }
        var i = 0
        while i < params.count {
            let v = params[i]
            switch v {
            case 0: attr = TermCell()
            case 1: attr.bold = true
            case 2: attr.bold = false
            case 3: attr.italic = true
            case 4: attr.underline = true
            case 7: attr.inverse = true
            case 22: attr.bold = false
            case 23: attr.italic = false
            case 24: attr.underline = false
            case 27: attr.inverse = false
            case 30...37: attr.fg = Int32(v - 30)
            case 39: attr.fg = nil
            case 40...47: attr.bg = Int32(v - 40)
            case 49: attr.bg = nil
            case 90...97: attr.fg = Int32(v - 90 + 8)
            case 100...107: attr.bg = Int32(v - 100 + 8)
            case 58:
                // Underline colour is not drawn; its arguments are skipped, not read as attributes.
                if i + 1 < params.count { i += params[i + 1] == 5 ? 2 : params[i + 1] == 2 ? 4 : 0 }
            case 38, 48:
                let index = v == 38 ? \TermCell.fg : \TermCell.bg
                if i + 2 < params.count, params[i + 1] == 5 {
                    let n = Int32(max(0, min(255, params[i + 2])))
                    attr[keyPath: index] = n
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    let r = Int32(max(0, min(255, params[i + 2])))
                    let g = Int32(max(0, min(255, params[i + 3])))
                    let b = Int32(max(0, min(255, params[i + 4])))
                    attr[keyPath: index] = 0x1000000 + (r << 16) + (g << 8) + b
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    /// One line as text, for the self-test and for copying a line.
    func rowText(_ y: Int) -> String {
        guard grid.indices.contains(y) else { return "" }
        return grid[y].cells.map { $0.text.isEmpty ? " " : $0.text }.joined()
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != cols || newRows != rows else { return }
        grid = TermScreen.fit(grid, cols: newCols, rows: newRows)
        // The screen saved under the alternate one, and the saved cursors, take the new size too: quitting vim
        // after a resize must not bring back a grid of the old height.
        if let a = altSaved {
            altSaved = (TermScreen.fit(a.0, cols: newCols, rows: newRows), min(a.1, newCols - 1), min(a.2, newRows - 1))
        }
        if let s = saved { saved = (min(s.x, newCols - 1), min(s.y, newRows - 1), s.attr) }
        cols = newCols
        rows = newRows
        cursorX = min(cursorX, max(0, cols - 1))
        cursorY = min(cursorY, max(0, rows - 1))
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
    }

    /// Lines cut or padded to `cols`, and to `rows` lines.
    static func fit(_ lines: [TermLine], cols: Int, rows: Int) -> [TermLine] {
        (0..<rows).map { y in
            var cells = y < lines.count ? lines[y].cells : []
            if cells.count > cols { cells.removeLast(cells.count - cols) }
            if cells.count < cols { cells.append(contentsOf: Array(repeating: TermCell(), count: cols - cells.count)) }
            return TermLine(cells: cells)
        }
    }
}

/// A tab's terminal: the pty, the screen it feeds and the view's natural size.
final class TermSession: ObservableObject, Identifiable {
    let id: String
    @Published var title: String
    @Published var subtitle: String = ""
    @Published var revision = 0
    @Published var exited: Int32?
    @Published var hasApproval = false
    /// The project folder this tab belongs to: the window shows each project's tabs on its own screen.
    let project: String?
    let screen: TermScreen
    private(set) var pty: Pty?
    private var cols = 100
    private var rows: Int
    private var pendingRender = false

    init(id: String = String(UUID().uuidString.prefix(8)), title: String, dir: URL, command: String?, env: [String: String], vm: String? = nil, project: String? = nil) {
        self.id = id
        self.title = title
        self.project = project
        self.screen = TermScreen(cols: cols, rows: 30)
        self.rows = 30
        self.runsCommand = command?.isEmpty == false
        var environment = env
        environment["APPRENTICE_TAB"] = id
        if let vm { environment["APPRENTICE_VM"] = vm }
        // Its counts, caps and skills are the project's, wherever the agent `cd`s to.
        if let project { environment["APPRENTICE_PROJECT"] = project }
        var shellArgs = ["-l"]
        if let command, !command.isEmpty { shellArgs = ["-l", "-c", command] }
        let pty = Pty(args: shellArgs, dir: dir, env: environment, cols: cols, rows: rows, onData: { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.screen.feed(data)
                self.scheduleRender()
            }
        }, onExit: { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exited = code
                self.subtitle = "exited \(code)"
                self.revision += 1
            }
        })
        self.pty = pty
        screen.reply = { [weak pty] answer in pty?.write(answer) }
    }

    private func scheduleRender() {
        if pendingRender { return }
        pendingRender = true
        // Coalesce a burst of output into one redraw, so a fast build does not redraw per chunk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.pendingRender = false
            self.revision += 1
            if !self.screen.title.isEmpty, self.screen.title != self.title, self.subtitle.isEmpty {
                self.title = self.screen.title
            }
        }
    }

    func send(_ text: String) { pty?.write(text) }

    func send(_ event: NSEvent) -> Bool {
        guard let pty else { return false }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        // Copy, paste, find and select-all belong to the view; everything else goes to the shell.
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c", "a", "f", "k": return false
            case "v":
                paste()
                return true
            default: return false
            }
        }
        switch event.keyCode {
        case 36, 76: pty.write("\r"); return true
        case 48: pty.write(flags.contains(.shift) ? "\u{1b}[Z" : "\t"); return true
        case 53: pty.write("\u{1b}"); return true
        case 51: pty.write("\u{7f}"); return true
        case 117: pty.write("\u{1b}[3~"); return true
        case 115: pty.write("\u{1b}[H"); return true
        case 119: pty.write("\u{1b}[F"); return true
        case 116: pty.write("\u{1b}[5~"); return true
        case 121: pty.write("\u{1b}[6~"); return true
        // Arrow keys: `ESC O A` once a program asked for application cursor keys (DECCKM), else `ESC [ A`.
        case 123: pty.write(screen.appCursorKeys ? "\u{1b}OD" : "\u{1b}[D"); return true
        case 124: pty.write(screen.appCursorKeys ? "\u{1b}OC" : "\u{1b}[C"); return true
        case 125: pty.write(screen.appCursorKeys ? "\u{1b}OB" : "\u{1b}[B"); return true
        case 126: pty.write(screen.appCursorKeys ? "\u{1b}OA" : "\u{1b}[A"); return true
        default: break
        }
        if flags.contains(.control), let chars = event.charactersIgnoringModifiers, let first = chars.utf8.first {
            // ctrl+letter is the letter's low five bits, as a terminal sends it.
            let code = first >= 0x61 && first <= 0x7a ? first - 0x60 : first >= 0x40 && first <= 0x5f ? first - 0x40 : 0
            if code > 0 { pty.write(Data([code])); return true }
        }
        if let chars = event.characters, !chars.isEmpty {
            pty.write(chars)
            return true
        }
        return false
    }

    /// The clipboard as typed text. A program that asked for bracketed paste (Claude Code, zsh) gets it
    /// wrapped, so a pasted block with newlines arrives as one paste instead of running line by line; an end
    /// marker inside the clipboard is dropped so it cannot close the paste early.
    func paste() {
        guard let pty, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if screen.bracketedPaste {
            let clean = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
            pty.write("\u{1b}[200~" + clean + "\u{1b}[201~")
        } else {
            pty.write(text)
        }
    }

    /// A click at cell (`col`, `row`), both from 1. A program that asked for the mouse gets press and release
    /// reports, as in any terminal. Otherwise a press on a numbered option of a menu on screen (`❯ 1. Yes`)
    /// types the option's number, which is how Claude Code's menus and most others choose one. False when the
    /// click is the view's own: selecting text.
    func click(col: Int, row: Int, up: Bool) -> Bool {
        guard let pty else { return false }
        let x = max(1, min(col, cols)), y = max(1, min(row, rows))
        if screen.mouseTracking {
            pty.write(screen.sgrMouse ? "\u{1b}[<0;\(x);\(y)\(up ? "m" : "M")"
                : "\u{1b}[M" + String(UnicodeScalar(UInt8(up ? 35 : 32))) + String(UnicodeScalar(UInt8(min(32 + x, 255))))
                    + String(UnicodeScalar(UInt8(min(32 + y, 255)))))
            return true
        }
        guard !up, let choice = Self.menuChoice((0..<screen.rows).map(screen.rowText), row: y - 1) else { return false }
        pty.write(choice)
        return true
    }

    /// The number to type for a click on line `row`: the line is a numbered option (`2. No`, `❯ 1. Yes`) and a
    /// line near it is the menu's chosen one, marked with a pointer, so a numbered list in plain output is
    /// never clicked into a prompt.
    static func menuChoice(_ lines: [String], row: Int) -> String? {
        func option(_ line: String) -> (marked: Bool, number: String)? {
            var rest = Substring(line.drop { $0 == " " || $0 == "│" || $0 == "┃" })
            var marked = false
            if let first = rest.first, "❯›>▸→➜".contains(first) {
                marked = true
                rest = rest.dropFirst().drop { $0 == " " }
            }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...2).contains(digits.count), let after = rest.dropFirst(digits.count).first, after == "." || after == ")",
                  rest.dropFirst(digits.count + 1).first == " " else { return nil }
            return (marked, String(digits))
        }
        guard lines.indices.contains(row), let hit = option(lines[row]) else { return nil }
        let near = lines.indices.filter { abs($0 - row) <= 12 }
        return near.contains { option(lines[$0])?.marked == true } ? hit.number : nil
    }

    /// Scroll lines the wheel moved over the program's screen at cell (`col`, `row`), both from 1: mouse wheel
    /// reports when it asked for the mouse, arrow keys in a full-screen program that did not (as Terminal's
    /// alternate scroll), and false when the view should scroll its own scrollback.
    func wheel(lines: Int, col: Int, row: Int) -> Bool {
        guard let pty, lines != 0 else { return screen.mouseTracking || screen.alt }
        let count = min(abs(lines), 10)
        if screen.mouseTracking {
            let button = lines > 0 ? 64 : 65
            let x = max(1, min(col, cols)), y = max(1, min(row, rows))
            let one = screen.sgrMouse ? "\u{1b}[<\(button);\(x);\(y)M"
                : "\u{1b}[M" + String(UnicodeScalar(UInt8(32 + button))) + String(UnicodeScalar(UInt8(min(32 + x, 255))))
                    + String(UnicodeScalar(UInt8(min(32 + y, 255))))
            pty.write(String(repeating: one, count: count))
            return true
        }
        if screen.alt {
            let up = lines > 0
            let key = screen.appCursorKeys ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
            pty.write(String(repeating: key, count: count))
            return true
        }
        return false
    }

    /// The tab gained or lost the keyboard, for a program that asked to know (1004).
    func focus(_ on: Bool) {
        guard screen.focusEvents else { return }
        pty?.write(on ? "\u{1b}[I" : "\u{1b}[O")
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        screen.resize(cols: cols, rows: rows)
        pty?.resize(cols: cols, rows: rows)
        revision += 1
    }

    func close() {
        pty?.terminate()
        pty = nil
    }

    /// Started with a command (an agent, a pipeline) rather than as a plain shell.
    private let runsCommand: Bool

    /// A program is still working in the tab, so closing it (or quitting) would stop it. A plain shell counts as
    /// busy while something other than the shell holds the terminal; a tab started with a command, while that
    /// command (or what the shell started for it) still runs.
    var busy: Bool {
        guard exited == nil, let pty, pty.pid > 0 else { return false }
        if !runsCommand {
            let front = pty.foreground
            return front > 0 && front != pty.pid
        }
        var path = [CChar](repeating: 0, count: 4096)
        let name = proc_pidpath(pty.pid, &path, UInt32(path.count)) > 0 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : ""
        if !["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh"].contains(name) { return true }
        var kids = [pid_t](repeating: 0, count: 64)
        return proc_listchildpids(pty.pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size)) > 0
    }
}

/// The terminal's view: an `NSTextView` showing the screen and its scrollback, with the pty on the other
/// side of every keystroke. A read-only text view brings selection, copy and VoiceOver for free.
struct TerminalPane: NSViewRepresentable {
    @ObservedObject var term: TermSession
    var font: NSFont
    /// While a ⚠ banner for this tab is open, keys go nowhere: Allow takes a click, not a key.
    var locked = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.locked = locked
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 6)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.onKey = { event in term.send(event) }
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.watch(scroll)
        view.term = term
        context.coordinator.draw(term, font: font)
        // The keyboard belongs to the shell as soon as the tab shows: without this the sidebar list keeps
        // the focus, and an arrow key moves its selection (or scrolls) instead of reaching a prompt.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TerminalTextView else { return }
        view.onKey = { event in term.send(event) }
        view.term = term
        view.locked = locked
        context.coordinator.draw(term, font: font)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: TerminalTextView?
        private var lastRevision = -1
        private var observer: NSObjectProtocol?

        /// Whether the person scrolled away from the bottom: only their own scrolling (the wheel, the scroller)
        /// changes it, never a redraw, so a program redrawing its menu under an arrow key cannot leave the view
        /// stranded part way up, which looked like the arrow scrolling the pane instead of moving a selection.
        func watch(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                              queue: .main) { [weak self] _ in
                guard let view = self?.view, !view.scrollingItself else { return }
                view.follow = view.atBottom
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func draw(_ term: TermSession, font: NSFont) {
            guard let view, term.revision != lastRevision else { return }
            lastRevision = term.revision
            let text = Renderer.attributed(term.screen, font: font)
            view.scrollingItself = true
            view.textStorage?.setAttributedString(text)
            if view.follow { view.toBottom() }
            view.scrollingItself = false
        }
    }
}

/// Draws a `TermScreen` as an attributed string: colours from the theme, the cursor as a block.
enum Renderer {
    static func attributed(_ screen: TermScreen, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byClipping
        para.minimumLineHeight = font.pointSize * 1.22
        para.maximumLineHeight = font.pointSize * 1.22
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                   .foregroundColor: NSColor.textColor]
        var lines: [[TermCell]] = []
        // Only the tail of the scrollback is drawn: enough to scroll back through, not the whole day. A
        // full-screen program (the alternate screen) owns the whole view, so it shows alone.
        let back = scrollbackShown(screen)
        if back > 0 { lines.append(contentsOf: screen.scrollback.suffix(back)) }
        lines.append(contentsOf: screen.grid.map { $0.cells })
        // The cursor: a block over the character it sits on, found by its UTF-16 offset while the text is built.
        let cursorRow = lines.count - screen.grid.count + screen.cursorY
        var cursorAt: Int?
        for (index, cells) in lines.enumerated() {
            var run: [TermCell] = []
            func flush() {
                guard !run.isEmpty else { return }
                let string = run.map(\.text).joined()
                out.append(NSAttributedString(string: string, attributes: attributes(run[0], base: base)))
                run.removeAll()
            }
            var runStart = out.length
            for (x, cell) in cells.enumerated() {
                if index == cursorRow, x == screen.cursorX {
                    cursorAt = runStart + run.reduce(0) { $0 + ($1.text as NSString).length }
                }
                // The second half of a wide character is drawn by the first.
                if cell.wide, cell.text.isEmpty { continue }
                if run.isEmpty || (run[0].fg == cell.fg && run[0].bg == cell.bg && run[0].bold == cell.bold
                    && run[0].italic == cell.italic && run[0].underline == cell.underline && run[0].inverse == cell.inverse) {
                    run.append(cell)
                } else {
                    flush()
                    runStart = out.length
                    run.append(cell)
                }
            }
            flush()
            if index < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        let string = out.string as NSString
        if let at = cursorAt, at < string.length, screen.cursorVisible {
            let existing = out.attributes(at: at, effectiveRange: nil)
            var block = existing
            block[.backgroundColor] = (block[.foregroundColor] as? NSColor) ?? .textColor
            block[.foregroundColor] = NSColor.textBackgroundColor
            out.addAttributes(block, range: NSRange(location: at, length: 1))
        }
        return out
    }

    /// How many scrollback lines are drawn above the screen.
    static func scrollbackShown(_ screen: TermScreen) -> Int { screen.alt ? 0 : min(screen.scrollback.count, 400) }

    private static func attributes(_ cell: TermCell, base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = base
        if let fg = cell.fg { a[.foregroundColor] = color(fg) }
        if let bg = cell.bg { a[.backgroundColor] = color(bg) }
        if cell.bold {
            a[.font] = NSFont.monospacedSystemFont(ofSize: (a[.font] as? NSFont)?.pointSize ?? 12, weight: .semibold)
        }
        if cell.italic { a[.obliqueness] = 0.18 }
        if cell.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if cell.inverse {
            let fg = a[.foregroundColor] as? NSColor ?? .textColor
            let bg = a[.backgroundColor] as? NSColor ?? .textBackgroundColor
            a[.foregroundColor] = bg
            a[.backgroundColor] = fg
        }
        return a
    }

    /// The xterm 16 plus the 6×6×6 cube and greys, so 256 colours and truecolor both draw.
    static func color(_ value: Int32) -> NSColor {
        if value >= 0x1000000 {
            let rgb = value - 0x1000000
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                           green: CGFloat((rgb >> 8) & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.12, 0.12, 0.13), (0.80, 0.25, 0.25), (0.30, 0.68, 0.35), (0.85, 0.65, 0.25),
            (0.30, 0.50, 0.85), (0.70, 0.40, 0.75), (0.30, 0.70, 0.72), (0.80, 0.80, 0.80),
            (0.45, 0.45, 0.48), (0.95, 0.42, 0.42), (0.45, 0.85, 0.50), (0.98, 0.80, 0.40),
            (0.45, 0.65, 0.98), (0.85, 0.55, 0.90), (0.45, 0.85, 0.87), (0.98, 0.98, 0.98),
        ]
        if value < 16 { let c = palette[Int(value)]; return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1) }
        if value < 232 {
            let n = Int(value) - 16
            let r = CGFloat(n / 36) / 5, g = CGFloat((n / 6) % 6) / 5, b = CGFloat(n % 6) / 5
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let grey = CGFloat(Int(value) - 232) / 23
        return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
    }
}

/// While a terminal tab is on screen, the keyboard is the terminal's: a key pressed while something else in
/// the window holds the focus (a sidebar row, a tab, a button after a click, a menu that just closed) goes to
/// the terminal, so arrow keys answer an agent's question instead of moving a list or scrolling. Text boxes,
/// ⌘ shortcuts, sheets and a ⚠ banner keep their keys. Each take-back is noted in `app.log` (the control's
/// type, never the key), so whatever keeps taking the focus can be found and fixed.
enum TerminalKeys {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let term = TerminalTextView.shown, let window = term.window, event.window === window,
                  window.attachedSheet == nil, window.firstResponder !== term, !term.locked,
                  !event.modifierFlags.contains(.command) else { return event }
            if let text = window.firstResponder as? NSText, text.isEditable || text.isFieldEditor { return event }
            let from = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
            window.makeFirstResponder(term)
            AppLog.note("keyboard back to the terminal from \(from)")
            return event
        }
        // With the terminal holding the focus, its keys go straight to it: AppKit offers arrow, page and function
        // keys to every view as key equivalents first, where a scroll view or a SwiftUI control could take them.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let term = TerminalTextView.shown, let window = term.window, event.window === window,
                  window.attachedSheet == nil, window.firstResponder === term, !term.locked,
                  !event.modifierFlags.contains(.command), event.modifierFlags.contains(.function) else { return event }
            term.keyDown(with: event)
            return nil
        }
    }
}

/// A short log of the window's own events, for finding a bug the user describes: `~/.apprentice/app.log`,
/// the last 200 lines. Never what was typed.
enum AppLog {
    static func note(_ line: String) {
        let url = Store.dir.appendingPathComponent("app.log")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(Schedules.stamp(Date())) \(line)")
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The text view that hands every keystroke to the pty, unless the command key makes it the view's own.
final class TerminalTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?
    weak var term: TermSession?
    var locked = false
    /// The view keeps to the newest line until the person scrolls up, and again as soon as they type.
    var follow = true
    /// True while a redraw moves the view, so `Coordinator.watch` tells the person's scrolling from ours.
    var scrollingItself = false

    var atBottom: Bool {
        guard let scroll = enclosingScrollView else { return true }
        let line = (font?.pointSize ?? 12) * 1.22
        return scroll.contentView.bounds.maxY >= bounds.height - line
    }

    /// Lays the text out first: scrolling to an end that is not laid out yet stops short of it.
    func toBottom() {
        if let container = textContainer { layoutManager?.ensureLayout(for: container) }
        let was = scrollingItself
        scrollingItself = true
        scrollToEndOfDocument(nil)
        scrollingItself = was
        follow = true
    }

    override func keyDown(with event: NSEvent) {
        // An agent in one tab must not be able to approve its own step in another: a banner's Allow
        // button takes a click, and the terminal ignores keys while it is open.
        if locked { NSSound.beep(); return }
        if onKey?(event) == true {
            // A key for the program brings the view back to its prompt, as in Terminal.
            if !follow || !atBottom { toBottom() }
            return
        }
        // Arrows, page keys, home and end belong to the program; with no program (the tab ended) they do nothing,
        // never the text view's own line scrolling.
        if [123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every view in the window: ⌘V is the terminal's only while it has
        // the focus, and never while a banner is open.
        guard !locked, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "c", selectedRange().length > 0 { return super.performKeyEquivalent(with: event) }
            if chars == "v", onKey?(event) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Pasting from the Edit menu goes to the shell, as ⌘V does.
    override func paste(_ sender: Any?) {
        if locked { NSSound.beep(); return }
        term?.paste()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { term?.focus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { term?.focus(false) }
        return ok
    }

    private var wheelRest: CGFloat = 0

    /// Over a full-screen program the wheel and trackpad go to the program (Claude Code scrolls its own
    /// conversation), counted in lines; over a shell they scroll the scrollback as usual.
    override func scrollWheel(with event: NSEvent) {
        guard let term, let font, term.screen.mouseTracking || term.screen.alt else {
            super.scrollWheel(with: event)
            return
        }
        let lineHeight = font.pointSize * 1.22
        wheelRest += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        let lines = Int(wheelRest.rounded(.towardZero))
        guard lines != 0 else { return }
        wheelRest -= CGFloat(lines)
        guard let (col, row) = cell(event) else { return }
        _ = term.wheel(lines: lines, col: col, row: row)
    }

    /// The program's screen cell under the pointer, both from 1.
    private func cell(_ event: NSEvent) -> (Int, Int)? {
        guard let term, let font else { return nil }
        let lineHeight = font.pointSize * 1.22
        let charWidth = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        let point = convert(event.locationInWindow, from: nil)
        let col = Int((point.x - textContainerInset.width) / charWidth) + 1
        let row = Int((point.y - textContainerInset.height) / lineHeight) + 1 - Renderer.scrollbackShown(term.screen)
        return (col, row)
    }

    private var pressed = false

    /// A click goes to the program when it takes clicks (see `TermSession.click`); otherwise it selects text.
    /// Shift or option keeps it a selection, as in Terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.intersection([.shift, .option]).isEmpty, let term, let (col, row) = cell(event), row >= 1,
           term.click(col: col, row: row, up: false) {
            pressed = term.screen.mouseTracking
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pressed, let term, let (col, row) = cell(event) {
            pressed = false
            _ = term.click(col: col, row: row, up: true)
            return
        }
        super.mouseUp(with: event)
    }

    /// The terminal on screen (only the chosen tab's is in the window), for `TerminalKeys`.
    static weak var shown: TerminalTextView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TerminalTextView.shown = self
            DispatchQueue.main.async { [weak self] in if let self { self.window?.makeFirstResponder(self) } }
        } else if TerminalTextView.shown === self {
            TerminalTextView.shown = nil
        }
    }

    override func layout() {
        super.layout()
        // A resized window gives the pty its new size, so a TUI reflows instead of wrapping at 100.
        guard let scroll = enclosingScrollView, let font = font else { return }
        let charWidth = max(("M" as NSString).size(withAttributes: [.font: font]).width, 1)
        let cols = max(20, Int(scroll.contentSize.width / charWidth) - 1)
        let rows = max(4, Int(scroll.contentSize.height / (font.pointSize * 1.22)) - 1)
        term?.resize(cols: cols, rows: rows)
    }
}
