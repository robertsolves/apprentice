import AppKit

/// The moments apprentice makes a sound for. Each is a few soft notes, so a state change is heard, not noticed.
enum Cue: String {
    case handOff, back, paused, resumed, stopped, approval, done, agentStopped, fail

    /// Semitones above the system's root note, and how long each note rings (ms).
    var notes: [Beep.Note] {
        switch self {
        case .handOff: return [.init(7, 70), .init(0, 110)]
        case .back: return [.init(0, 70), .init(7, 110)]
        case .paused: return [.init(-5, 150)]
        case .resumed: return [.init(0, 55), .init(4, 55), .init(7, 90)]
        case .stopped: return [.init(-5, 110), .init(-12, 180)]
        case .approval: return [.init(0, 60), .init(4, 60), .init(7, 60), .init(12, 160)]
        case .done: return [.init(0, 70), .init(4, 70), .init(7, 70), .init(12, 260)]
        case .agentStopped: return [.init(7, 90), .init(4, 90), .init(0, 90), .init(-5, 220)]
        case .fail: return [.init(-12, 80), .init(-12, 140)]
        }
    }
}

/// Short synthesized tones: a sine with a touch of its octave, a soft attack and a quick decay, quiet enough to
/// sit under music. Every system has its own root note (This Mac is A, each VM another step of a pentatonic scale),
/// so several running together make a chord of small beeps and each can still be told apart.
enum Beep {
    struct Note {
        var semis: Double
        var ms: Double
        init(_ semis: Double, _ ms: Double) { (self.semis, self.ms) = (semis, ms) }
    }

    private static let rate = 22050.0
    /// Peak level before the volume: low on purpose.
    private static let level = 0.16

    /// The root note for a system. Stable across processes (a daemon per VM), so no `hashValue`.
    static func root(for key: String) -> Double {
        guard key != "mac" else { return 440 }
        var h: UInt32 = 5381
        for b in key.utf8 { h = h &* 33 &+ UInt32(b) }
        let steps: [Double] = [2, 4, 7, 9, 12, 14, 16]
        return 440 * pow(2, steps[Int(h % UInt32(steps.count))] / 12)
    }

    static func wav(_ notes: [Note], root: Double) -> Data {
        var pcm = [Int16]()
        for n in notes {
            let f = root * pow(2, n.semis / 12)
            let dur = n.ms / 1000
            for i in 0..<Int(rate * dur) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let fade = min(1, (dur - t) / 0.01)
                let decay = exp(-t / (dur * 0.5))
                let s = (sin(2 * .pi * f * t) + 0.18 * sin(4 * .pi * f * t)) * attack * fade * decay * level
                pcm.append(Int16(max(-1, min(1, s)) * 32767))
            }
            pcm.append(contentsOf: repeatElement(0, count: Int(rate * 0.015)))
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let bytes = pcm.count * 2
        var d = Data("RIFF".utf8)
        d += le(UInt32(36 + bytes)); d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)); d += le(UInt16(1)); d += le(UInt16(1))
        d += le(UInt32(rate)); d += le(UInt32(rate) * 2); d += le(UInt16(2)); d += le(UInt16(16))
        d += Data("data".utf8); d += le(UInt32(bytes))
        for s in pcm { d += le(s) }
        return d
    }
}
