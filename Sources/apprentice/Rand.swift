import Foundation
import os

/// The one random source behind every pause, path, landing point and fidget: xoshiro256**, seeded
/// once from the system generator, a few nanoseconds a draw. Each cursor stroke takes hundreds of
/// draws, so it has to be cheap. The lock lets question windows on other queues draw safely.
/// Secrets (VM passwords, approval tokens) keep the system generator; this one is for timing only.
enum Rand {
    struct Xoshiro: RandomNumberGenerator {
        private var s0: UInt64, s1: UInt64, s2: UInt64, s3: UInt64

        /// splitmix64 spreads one seed over the four words, so no seed gives an all-zero state.
        init(seed: UInt64) {
            var x = seed
            func mix() -> UInt64 {
                x &+= 0x9E37_79B9_7F4A_7C15
                var z = x
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            s0 = mix(); s1 = mix(); s2 = mix(); s3 = mix()
        }

        mutating func next() -> UInt64 {
            let out = ((s1 &* 5) << 7 | (s1 &* 5) >> 57) &* 9
            let t = s1 << 17
            s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3
            s2 ^= t
            s3 = s3 << 45 | s3 >> 19
            return out
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Xoshiro(seed: UInt64.random(in: .min ... .max)))

    /// A fixed sequence, for `selftest`.
    static func seed(_ value: UInt64) { state.withLock { $0 = Xoshiro(seed: value) } }

    static func next() -> UInt64 { state.withLock { $0.next() } }

    /// Uniform in [0, 1), 53 bits.
    static func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    static func uniform<T: BinaryFloatingPoint>(_ r: ClosedRange<T>) -> T {
        r.lowerBound + (r.upperBound - r.lowerBound) * T(unit())
    }

    static func uniform<T: BinaryFloatingPoint>(_ r: Range<T>) -> T {
        r.lowerBound + (r.upperBound - r.lowerBound) * T(unit())
    }

    static func uniform(_ r: ClosedRange<Int>) -> Int {
        let span = UInt64(r.upperBound - r.lowerBound) &+ 1
        return span == 0 ? Int(bitPattern: UInt(next())) : r.lowerBound + Int(next().multipliedFullWidth(by: span).high)
    }

    static func uniform(_ r: Range<Int>) -> Int {
        r.isEmpty ? r.lowerBound : uniform(r.lowerBound...(r.upperBound - 1))
    }

    static func chance(_ p: Double) -> Bool { unit() < p }


    /// Standard normal, Box–Muller.
    static func gaussian() -> Double {
        let u1 = uniform(1e-12..<1.0), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    /// Log-normal around `median`: most draws close, a few long, never negative.
    static func logNormal(median: Double, sigma: Double) -> Double { median * exp(sigma * gaussian()) }

    static func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[uniform(0..<items.count)] }

    /// One of `items`, in proportion to its weight.
    static func weighted<T>(_ items: [(T, Double)]) -> T {
        var left = unit() * items.reduce(0) { $0 + max($1.1, 0) }
        for (item, w) in items where w > 0 {
            left -= w
            if left < 0 { return item }
        }
        return items[items.count - 1].0
    }
}
