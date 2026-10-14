//
//  ParserFuzzTests.swift
//
//  Seeded, deterministic fuzzing of the strings a program can make the
//  terminal hold or decode: DCS (sixel on and off, DECRQSS, unknown) and OSC.
//  Every input is random bytes biased towards the bytes these sequences are
//  made of, or a structured sequence with hostile numbers, lengths and
//  terminators, fed in random chunks. The test asserts nothing traps (the
//  process would die) and that what the parser and its handlers hold, and
//  every image made, stays within the caps. The caps are lowered so that
//  the inputs reach them quickly.
//
import Foundation
import Testing

@testable import SwiftTerm

final class ParserFuzzTests {
    /// SplitMix64: small, fast, and the same sequence for a seed everywhere.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let sixelCap = 4096
    static let oscCap = 256

    /// Bytes the sequences under test are made of, plus every C0/C1
    /// terminator and introducer the parser treats specially.
    static let alphabet: [UInt8] = Array("PqP$q]_\\!#;\"-$~?@0123456789".utf8)
        + [0x1b, 0x1b, 0x07, 0x18, 0x1a, 0x90, 0x9c, 0x9d, 0x9f, 0x98, 0x9b, 0x0a, 0x0d, 0x7f, 0xc2, 0xa0]

    var rng = SeededGenerator(seed: 0)
    /// Images already checked by `checkHoldings`.
    var checkedImages = 0

    func makeTerminal(sixel: Bool) -> (Terminal, SixelHardeningTests.Delegate) {
        let delegate = SixelHardeningTests.Delegate()
        delegate.keepsBytes = false  // sizes only: images can be 64 MiB each
        let options = TerminalOptions(cols: 40, rows: 10, kittyGraphicsEnabled: false,
                                      sixelEnabled: sixel, maximumOscBytes: Self.oscCap)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.sixelMaxSequenceBytes = Self.sixelCap
        return (terminal, delegate)
    }

    // MARK: Input generators

    func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }

    func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }

    /// A number as a program might send it: small, at a boundary, or many
    /// digits long (far past Int.max).
    func number() -> String {
        switch int(0...5) {
        case 0: return String(int(0...9))
        case 1: return String(int(0...2000))
        case 2: return String([SixelDcsHandler.maxNumber, SixelDcsHandler.maxDimension,
                               SixelDcsHandler.maxColorRegisters, Int(Int32.max), Int.max].randomElement(using: &rng)!)
        case 3: return String(repeating: "9", count: int(19...40))
        case 4: return ""
        default: return String(int(0...100))
        }
    }

    func randomBytes() -> [UInt8] {
        (0..<int(1...512)).map { _ in
            chance(0.8) ? Self.alphabet.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng)
        }
    }

    func sixelBody() -> String {
        var s = chance(0.3) ? "\"\(number());\(number());\(number());\(number())" : ""
        for _ in 0..<int(0...80) {
            switch int(0...9) {
            case 0: s += "#\(number())"
            case 1: s += "#\(number());\(int(0...3));\(number());\(number());\(number())"
            case 2: s += "#\(number())" + String(repeating: ";\(number())", count: int(0...40))
            case 3: s += "!\(number())"
            case 4: s += "-"
            case 5: s += "$"
            case 6: s += String(repeating: "-", count: int(0...400))
            default: s += String(UnicodeScalar(UInt8(int(63...126))))
            }
        }
        return s
    }

    func terminator() -> [UInt8] {
        [[0x1b, 0x5c], [0x1b, 0x5c], [0x9c], [0x07], [0x18], [0x1a], [0x1b], [], [0x90], [0x9d]]
            .randomElement(using: &rng)!
    }

    /// A sequence introducer: the 7-bit form, or the C1 byte after an ESC (from
    /// ground the parser takes a C1 byte for text; from escape it is the
    /// introducer).
    func introducer(_ seven: UInt8, _ c1: UInt8) -> [UInt8] {
        chance(0.5) ? [0x1b, seven] : [0x1b, c1]
    }

    func structured() -> [UInt8] {
        var out = introducer(0x50, 0x90)
        if chance(0.05) { out += [UInt8](repeating: 0x20, count: int(0...100)) }  // intermediates
        switch int(0...5) {
        case 0, 1:  // sixel, with or without parameters
            if chance(0.5) { out += Array("\(number());\(number());\(number())".utf8) }
            out += Array("q".utf8) + Array(sixelBody().utf8)
            if chance(0.1) { out += Array(String(repeating: "~", count: int(0...(2 * Self.sixelCap))).utf8) }
        case 2:  // DECRQSS, short or long
            out += Array("$q".utf8)
            out += Array(String(repeating: ["r", "m", " q", "\"p", "x"].randomElement(using: &rng)!, count: int(0...200)).utf8)
        case 3:  // a DCS nothing handles
            out += Array("\(number())+q\(String(repeating: "54", count: int(0...300)))".utf8)
        default:  // OSC (replaces the DCS introducer)
            out = introducer(0x5d, 0x9d)
            out += Array("\(number());".utf8)
            out += Array(String(repeating: "x", count: int(0...(2 * Self.oscCap))).utf8)
        }
        return out + terminator()
    }

    // MARK: Invariants

    func checkHoldings(_ terminal: Terminal, _ delegate: SixelHardeningTests.Delegate, _ context: @autoclosure () -> String) {
        let parser = terminal.parser
        #expect(parser._osc.count <= Self.oscCap + 1, "\(context())")
        #expect(parser._apc.count <= 1, "\(context())")
        #expect(parser._collect.count <= EscapeSequenceParser.maximumCollectBytes, "\(context())")
        if let sixel = parser.activeDcsHandler as? SixelDcsHandler {
            #expect(sixel.data.count <= Self.sixelCap, "\(context())")
        }
        if let decrqss = parser.activeDcsHandler as? Terminal.DECRQSS {
            #expect(decrqss.data.count <= Terminal.DECRQSS.maxRequestBytes, "\(context())")
        }
        for image in delegate.sizes[checkedImages...] {
            #expect(image.width > 0 && image.width <= SixelDcsHandler.maxDimension, "\(context())")
            #expect(image.height > 0 && image.height <= SixelDcsHandler.maxDimension, "\(context())")
            #expect(image.width * image.height <= SixelDcsHandler.maxPixels, "\(context())")
            #expect(image.byteCount == image.width * image.height * 4, "\(context())")
        }
        checkedImages = delegate.sizes.count
    }

    /// Feeds `input` in random chunks, checking the holdings after each.
    func feedInChunks(_ input: [UInt8], _ terminal: Terminal, _ delegate: SixelHardeningTests.Delegate, _ context: String) {
        var start = 0
        while start < input.count {
            let end = min(input.count, start + int(1...max(1, input.count)))
            terminal.feed(byteArray: Array(input[start..<end]))
            checkHoldings(terminal, delegate, context)
            start = end
        }
    }

    @Test(arguments: [(UInt64(1), true), (2, false), (3, true), (4, false)])
    func randomAndStructuredInputIsBounded(seed: UInt64, sixel: Bool) {
        rng = SeededGenerator(seed: seed)
        let (terminal, delegate) = makeTerminal(sixel: sixel)
        let started = Date()
        for n in 0..<1500 {
            let input = chance(0.5) ? randomBytes() : structured()
            feedInChunks(input, terminal, delegate, "seed \(seed) input \(n)")
            if !sixel {
                #expect(delegate.images.count == 0, "seed \(seed) input \(n)")
            }
            if n % 100 == 99 {
                // Back to ground, as the next program's output would.
                terminal.feed(byteArray: [0x18, 0x1b, 0x5c])
            }
        }
        // The inputs reach the decoder: with sixel on, images were made.
        #expect(sixel == (delegate.images.count > 0), "seed \(seed): \(delegate.images.count) images")
        // Afterwards the terminal still works: DA1 is answered.
        terminal.feed(byteArray: [0x18, 0x1b, 0x5c])
        _ = delegate.replies()
        terminal.feed(text: "\u{1b}[c")
        #expect(delegate.replies().hasPrefix("\u{1b}[?"))
        // Linear work: the whole run takes seconds (a generous bound, for a
        // loaded simulator).
        #expect(Date().timeIntervalSince(started) < 300)
    }

    /// The sequences from m10a review J1 and their relatives, each fed whole
    /// and byte by byte, with sixel on: none traps, each is quick, and each
    /// image is within the caps.
    @Test func knownHostileSequences() {
        let big = String(repeating: "9", count: 30)
        let sequences = [
            "\u{1b}Pq#0!99999999999999999999~\u{1b}\\",
            "\u{1b}Pq#0!2000000000~\u{1b}\\",
            "\u{1b}Pq#0!\(big)~-!\(big)~-!\(big)~\u{1b}\\",
            "\u{1b}Pq\"\(big);\(big);\(big);\(big)#\(big);2;\(big);\(big);\(big)#\(big)!\(big)~\u{1b}\\",
            "\u{1b}Pq#0!10000~" + String(repeating: "-!10000~", count: 2000) + "\u{1b}\\",
            "\u{1b}Pq#0" + String(repeating: "!10000~$", count: 1000) + "\u{1b}\\",
            "\u{1b}P\(big);\(big);\(big)q#0~\u{1b}\\",
        ]
        for sixel in [true, false] {
            for (n, seq) in sequences.enumerated() {
                let (terminal, delegate) = makeTerminal(sixel: sixel)
                checkedImages = 0
                terminal.sixelMaxSequenceBytes = SixelDcsHandler.defaultMaxSequenceBytes
                let started = Date()
                terminal.feed(text: seq)
                for byte in seq.utf8 { terminal.feed(byteArray: [byte]) }
                #expect(Date().timeIntervalSince(started) < 60, "sequence \(n)")
                checkHoldings(terminal, delegate, "sequence \(n), sixel \(sixel)")
                #expect(sixel || delegate.images.count == 0)
                #expect(terminal.parser.activeDcsHandler == nil, "sequence \(n)")
            }
        }
    }
}
