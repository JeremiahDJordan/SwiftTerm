//
//  SixelHardeningTests.swift
//
//  The host's control over sixel (`DCS q`): it can be turned off, and the
//  decoder is bounded whatever the program sends — numbers saturate instead
//  of trapping, images are cropped, the drawing work and the sequence held are
//  capped. DECRQSS (`DCS $ q`) holds only a short request, an abandoned DCS
//  releases its handler at once, and OSC strings are held up to
//  `TerminalOptions.maximumOscBytes`. (`ParserFuzzTests` throws random and
//  structured input at all of this.)
//
import Foundation
import Testing

@testable import SwiftTerm

final class SixelHardeningTests {
    /// Records replies and images (`TerminalTestDelegate` does not record images).
    final class Delegate: TerminalDelegate {
        private(set) var sentData: [[UInt8]] = []
        private(set) var images: [(bytes: [UInt8], width: Int, height: Int)] = []
        /// Every image's size and byte count, kept even when `keepsBytes` is off.
        private(set) var sizes: [(width: Int, height: Int, byteCount: Int)] = []
        /// Off, `images` holds no pixels (the fuzz test makes many large images).
        var keepsBytes = true
        private(set) var titles: [String] = []

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) { sentData.append(Array(data)) }
        func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
            images.append((keepsBytes ? bytes : [], width, height))
            sizes.append((width, height, bytes.count))
        }

        /// What the terminal sent back since the last call, as text.
        func replies() -> String {
            defer { sentData.removeAll() }
            return sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
        }
    }

    private let esc = "\u{1b}"

    private func makeTerminal(sixel: Bool = true, maximumOscBytes: Int = TerminalOptions.default.maximumOscBytes) -> (Terminal, Delegate) {
        let delegate = Delegate()
        let options = TerminalOptions(cols: 20, rows: 5, sixelEnabled: sixel, maximumOscBytes: maximumOscBytes)
        return (Terminal(delegate: delegate, options: options), delegate)
    }

    private func firstLine(_ terminal: Terminal) -> String {
        TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) ?? ""
    }

    /// `seq`, then DA1 and some text: the DA1 answer arrives and the text is
    /// drawn, so the parser left the sequence and went on.
    private func feedThenProbe(_ terminal: Terminal, _ delegate: Delegate, _ seq: String) {
        terminal.feed(text: seq + "\(esc)[cafter")
        #expect(delegate.replies().hasPrefix("\(esc)[?"))
        #expect(firstLine(terminal) == "after")
    }

    /// RGBA of the pixel at (x, y).
    private func pixel(_ image: (bytes: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> [UInt8] {
        let s = (y * image.width + x) * 4
        return Array(image.bytes[s..<s + 4])
    }

    // MARK: The off switch

    @Test func sixelIsOnByDefault() {
        #expect(TerminalOptions.default.sixelEnabled)
        #expect(TerminalOptions().sixelEnabled)
    }

    @Test func offASixelIsConsumedWithoutAnImage() {
        let (terminal, delegate) = makeTerminal(sixel: false)
        feedThenProbe(terminal, delegate, "\(esc)Pq#0;2;100;0;0#0!3~\(esc)\\")
        #expect(delegate.images.count == 0)
    }

    /// Off, nothing decodes, so the sequences that crash or exhaust the
    /// decoder when it runs are harmless.
    @Test func offTheCrashingSequencesAreConsumed() {
        let (terminal, delegate) = makeTerminal(sixel: false)
        feedThenProbe(terminal, delegate, "\(esc)Pq#0!99999999999999999999~\(esc)\\")
        terminal.feed(text: "\r")
        feedThenProbe(terminal, delegate, "\(esc)Pq#0!2000000000~\(esc)\\")
        #expect(delegate.images.count == 0)
    }

    /// Off, an unterminated sixel holds nothing: there is no handler.
    @Test func offNothingIsBuffered() {
        let (terminal, _) = makeTerminal(sixel: false)
        terminal.feed(text: "\(esc)Pq#0" + String(repeating: "~", count: 65_536))
        #expect(terminal.parser.activeDcsHandler == nil)
        terminal.feed(text: "\(esc)\\after")
        #expect(firstLine(terminal) == "after")
    }

    /// Read when each sequence starts, so a host sets it after the terminal exists.
    @Test func theOptionIsReadPerSequence() {
        let (terminal, delegate) = makeTerminal()
        terminal.options.sixelEnabled = false
        terminal.feed(text: "\(esc)Pq#0~$\(esc)\\")
        #expect(delegate.images.count == 0)
        terminal.options.sixelEnabled = true
        terminal.feed(text: "\(esc)Pq#0~$\(esc)\\")
        #expect(delegate.images.count == 1)
    }

    /// DA1 is still governed by `enableSixelReported` alone.
    @Test func da1FollowsEnableSixelReported() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(enableSixelReported: false, sixelEnabled: true))
        terminal.feed(text: "\(esc)[c")
        let answer = delegate.replies()
        #expect(!answer.dropFirst(3).prefix { $0 != "c" }.split(separator: ";").contains("4"), "\(answer.debugDescription)")
    }

    // MARK: The decoder, on

    @Test func aSmallImageStillDecodes() throws {
        let (terminal, delegate) = makeTerminal()
        feedThenProbe(terminal, delegate, "\(esc)Pq#1;2;100;0;0#1!3~-#1@$\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == 3)
        #expect(image.height == 7)
        #expect(pixel(image, 2, 5) == [255, 0, 0, 255])
        #expect(pixel(image, 0, 6) == [255, 0, 0, 255])
        #expect(pixel(image, 1, 6) == [0, 0, 0, 0])
    }

    /// m10a review J1: the repeat count overflowed `Int` (SIGTRAP).
    @Test func aHugeRepeatCountSaturates() throws {
        let (terminal, delegate) = makeTerminal()
        feedThenProbe(terminal, delegate, "\(esc)Pq#0!99999999999999999999~\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == SixelDcsHandler.maxDimension)
        #expect(image.height == 6)
    }

    /// m10a review J1: two billion repeats took about a minute and 7 GB.
    @Test func twoBillionRepeatsAreCroppedAndQuick() throws {
        let (terminal, delegate) = makeTerminal()
        let start = Date()
        feedThenProbe(terminal, delegate, "\(esc)Pq#0!2000000000~\(esc)\\")
        #expect(Date().timeIntervalSince(start) < 30)  // was about a minute
        let image = try #require(delegate.images.first)
        #expect(image.width == SixelDcsHandler.maxDimension)
        #expect(image.height == 6)
        #expect(image.bytes.count == SixelDcsHandler.maxDimension * 6 * 4)
    }

    /// Colour registers, colour values and raster attributes go through the
    /// same number reader. (The decoder never reads a sequence's last byte,
    /// as upstream: hence the `$`.)
    @Test func hugeNumbersElsewhereSaturate() throws {
        let (terminal, delegate) = makeTerminal()
        let big = "99999999999999999999999999"
        feedThenProbe(terminal, delegate, "\(esc)P\(big);\(big)q\"\(big);\(big);\(big);\(big)#\(big);2;\(big);\(big);\(big)#\(big);1;\(big);\(big);\(big)#\(big)~$\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == 1)
        #expect(image.height == 6)
    }

    @Test func aTallImageIsCropped() throws {
        let (terminal, delegate) = makeTerminal()
        let rows = SixelDcsHandler.maxDimension / 6 + 10
        feedThenProbe(terminal, delegate, "\(esc)Pq#0~" + String(repeating: "-", count: rows) + "~\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == 1)
        #expect(image.height == SixelDcsHandler.maxDimension)
    }

    /// Drawing the same band over and over stops after `drawPasses` times the
    /// image's area: a later pass is not drawn.
    @Test func overdrawingIsBounded() throws {
        let (terminal, delegate) = makeTerminal()
        let red = "#1;2;100;0;0#2;2;0;100;0#1"
        let passes = String(repeating: "!100~$", count: SixelDcsHandler.drawPasses)
        feedThenProbe(terminal, delegate, "\(esc)Pq" + red + passes + "#2!100~\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == 100)
        #expect(pixel(image, 50, 3) == [255, 0, 0, 255])
    }

    /// m10a review R3-2: each side was capped on its own, so a
    /// 10,000 x 10,000 image (a 400 MB buffer) was still possible. The area
    /// is capped too: the height stops where the area would pass `maxPixels`.
    @Test func theAreaIsCapped() throws {
        let (terminal, delegate) = makeTerminal()
        let rows = 400  // 2,406 px tall at 10,000 wide: past maxPixels
        feedThenProbe(terminal, delegate, "\(esc)Pq#0!10000~" + String(repeating: "-~", count: rows) + "$\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == SixelDcsHandler.maxDimension)
        #expect(image.height == SixelDcsHandler.maxPixels / SixelDcsHandler.maxDimension)
        #expect(image.bytes.count <= SixelDcsHandler.maxPixels * 4)
    }

    /// A colour command keeps only the numbers it uses, however many it is
    /// sent, so a long list cannot grow into an array eight times its size.
    @Test func aColourCommandKeepsFiveNumbers() throws {
        let handler = SixelDcsHandler(terminal: makeTerminal().0)
        handler.data = Array(("1;2;100;0;0" + String(repeating: ";7", count: 10_000) + "~").utf8)
        var p = 0
        #expect(handler.nextIntArray(&p) == [1, 2, 100, 0, 0])
        #expect(handler.data[p] == UInt8(ascii: "~"))

        // ...and the extra numbers change nothing in the image.
        let (terminal, delegate) = makeTerminal()
        feedThenProbe(terminal, delegate, "\(esc)Pq#1;2;100;0;0" + String(repeating: ";7", count: 1_000) + "#1~$\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(pixel(image, 0, 0) == [255, 0, 0, 255])
    }

    /// Only `maxColorRegisters` registers can be defined: a definition of a
    /// higher one is ignored, so its pixels are transparent.
    @Test func colourRegistersAreBounded() throws {
        let (terminal, delegate) = makeTerminal()
        let last = SixelDcsHandler.maxColorRegisters - 1
        let over = SixelDcsHandler.maxColorRegisters
        feedThenProbe(terminal, delegate, "\(esc)Pq#\(last);2;100;0;0#\(over);2;100;0;0#\(last)~#\(over)~$\(esc)\\")
        let image = try #require(delegate.images.first)
        #expect(image.width == 2)
        #expect(pixel(image, 0, 0) == [255, 0, 0, 255])
        #expect(pixel(image, 1, 0) == [0, 0, 0, 0])
    }

    /// An empty sixel, or one that draws nothing, makes no image (the
    /// terminator now always unhooks, so this reaches the decoder).
    @Test func anEmptySixelMakesNoImage() {
        let (terminal, delegate) = makeTerminal()
        feedThenProbe(terminal, delegate, "\(esc)Pq\(esc)\\")
        terminal.feed(text: "\r")
        feedThenProbe(terminal, delegate, "\(esc)Pq#0;2;100;0;0$\(esc)\\")
        #expect(delegate.images.count == 0)
    }

    // MARK: The sequence held

    @Test func aSequenceAtTheCapDecodesOneLongerIsDropped() throws {
        let (terminal, delegate) = makeTerminal()
        terminal.sixelMaxSequenceBytes = 64
        let body = "#0~" + String(repeating: "$", count: 61)
        #expect(body.utf8.count == 64)
        // Split across two feeds, as it would arrive.
        terminal.feed(text: "\(esc)Pq" + body.prefix(30))
        terminal.feed(text: body.dropFirst(30) + "\(esc)\\")
        #expect(delegate.images.count == 1)

        terminal.feed(text: "\(esc)Pq" + body.prefix(30))
        terminal.feed(text: body.dropFirst(30) + "$")
        let handler = try #require(terminal.parser.activeDcsHandler as? SixelDcsHandler)
        #expect(handler.overflowed)
        #expect(handler.data.isEmpty)
        terminal.feed(text: String(repeating: "~", count: 4096))
        #expect(handler.data.isEmpty)
        feedThenProbe(terminal, delegate, "\(esc)\\")
        #expect(delegate.images.count == 1)

        // The next sequence starts afresh.
        terminal.feed(text: "\(esc)Pq#0~$\(esc)\\")
        #expect(delegate.images.count == 2)
    }

    // MARK: DCS lifecycle

    /// The terminator in a feed of its own still ends the sequence (it used
    /// to be unhooked only when content arrived in the same feed, so the
    /// request went unanswered and the handler stayed behind).
    @Test func aTerminatorInAFeedOfItsOwnEndsTheSequence() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)P$qr")
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.replies() == "\(esc)P1$r1;5r\(esc)\\")
        #expect(terminal.parser.activeDcsHandler == nil)
        terminal.feed(text: "\(esc)Pq#0~$")
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.images.count == 1)
    }

    /// A DCS aborted by SUB leaves no handler that a later sequence nothing
    /// handles (sixel while off) would be handed to. (CAN is content in a DCS
    /// string, as upstream.)
    @Test func anAbortedSequenceLeavesNoHandlerBehind() {
        let (terminal, delegate) = makeTerminal(sixel: false)
        terminal.feed(text: "\(esc)P$qr\u{1a}")
        terminal.feed(text: "\(esc)Pq#0;2;100;0;0#0!3~\(esc)\\")
        #expect(delegate.replies().isEmpty)
        #expect(terminal.parser.activeDcsHandler == nil)
    }

    /// A sixel abandoned by SUB (or a C1 control) releases its handler and
    /// what it holds at once, not when the next sequence starts.
    @Test func anAbandonedSixelIsReleasedAtOnce() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)Pq#0" + String(repeating: "~", count: 4096))
        #expect(terminal.parser.activeDcsHandler is SixelDcsHandler)
        terminal.feed(text: "\u{1a}after")
        #expect(terminal.parser.activeDcsHandler == nil)
        #expect(firstLine(terminal) == "after")
        terminal.feed(byteArray: Array("\(esc)Pq#0~~".utf8) + [0x9d])  // C1 OSC
        #expect(terminal.parser.activeDcsHandler == nil)
        #expect(delegate.images.count == 0)
    }

    /// m10a review R1-1: intermediate bytes were collected without bound
    /// (`ESC P` and endless spaces held one byte per byte). They are capped,
    /// and a sequence with more is dropped.
    @Test func intermediatesAreCapped() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)P" + String(repeating: " ", count: 100_000))
        #expect(terminal.parser._collect.count == EscapeSequenceParser.maximumCollectBytes)
        feedThenProbe(terminal, delegate, "q#0~$\(esc)\\")
        terminal.feed(text: "\(esc)[" + String(repeating: "!", count: 100) + "p")
        #expect(terminal.parser._collect.count <= EscapeSequenceParser.maximumCollectBytes)
        // An ordinary sequence afterwards is handled.
        terminal.feed(text: "\(esc)[2;3H")
        #expect(terminal.buffer.y == 1 && terminal.buffer.x == 2)
    }

    /// An ESC sequence is dispatched with up to `maximumCollectBytes`
    /// intermediates and dropped with one more (m10a re-review R2-2).
    @Test func anEscSequenceWithTooManyIntermediatesIsDropped() {
        let (terminal, _) = makeTerminal()
        var dispatched: [Int] = []
        terminal.parser.escHandlerFallback = { collect, _ in dispatched.append(collect.count) }
        let most = EscapeSequenceParser.maximumCollectBytes
        terminal.feed(text: "\(esc)" + String(repeating: " ", count: most) + "F")
        terminal.feed(text: "\(esc)" + String(repeating: " ", count: most + 1) + "F")
        #expect(dispatched == [most])
    }

    // MARK: DECRQSS

    @Test func decrqssStillAnswers() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)P$qr\(esc)\\")
        #expect(delegate.replies() == "\(esc)P1$r1;5r\(esc)\\")
    }

    @Test func aLongDecrqssIsHeldShortAndRefused() throws {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)P$qr" + String(repeating: "r", count: 100_000))
        let handler = try #require(terminal.parser.activeDcsHandler as? Terminal.DECRQSS)
        #expect(handler.data.count == Terminal.DECRQSS.maxRequestBytes)
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.replies() == "\(esc)P0$r\(esc)\\")
    }

    /// A request exactly at the cap is read as sent (and, being no request
    /// this answers, refused); the cap only drops what goes past it.
    @Test func aDecrqssAtTheCapIsRead() throws {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)P$q" + String(repeating: "r", count: Terminal.DECRQSS.maxRequestBytes))
        let handler = try #require(terminal.parser.activeDcsHandler as? Terminal.DECRQSS)
        #expect(!handler.overflowed)
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.replies() == "\(esc)P0$r\(esc)\\")
    }

    // MARK: OSC strings

    @Test func oscIsCappedAt64MiBByDefault() {
        #expect(TerminalOptions.default.maximumOscBytes == 64 * 1024 * 1024)
        #expect(TerminalOptions().maximumOscBytes == 64 * 1024 * 1024)
    }

    /// A string exactly at the cap (code included) is handled; one byte
    /// more is dropped, and while it arrives no more than the cap plus one
    /// byte is held.
    @Test func anOscStringAtTheCapIsHandledOneLongerIsDropped() {
        let (terminal, delegate) = makeTerminal(maximumOscBytes: 16)
        terminal.feed(text: "\(esc)]0;" + String(repeating: "a", count: 14) + "\u{07}")
        #expect(delegate.titles == [String(repeating: "a", count: 14)])

        terminal.feed(text: "\(esc)]0;" + String(repeating: "b", count: 15))
        terminal.feed(text: String(repeating: "b", count: 100_000))
        #expect(terminal.parser._osc.count == 17)
        terminal.feed(text: "\u{07}after")
        #expect(delegate.titles.count == 1)
        #expect(firstLine(terminal) == "after")

        // The next string starts afresh.
        terminal.feed(text: "\(esc)]2;ok\(esc)\\")
        #expect(delegate.titles.last == "ok")
    }

    /// Read as the string arrives, so a host lowers it after the terminal exists.
    @Test func theOscCapIsReadAsTheStringArrives() {
        let (terminal, delegate) = makeTerminal()
        terminal.options.maximumOscBytes = 8
        terminal.feed(text: "\(esc)]0;" + String(repeating: "c", count: 64))
        #expect(terminal.parser._osc.count == 9)
        terminal.feed(text: "\u{07}")
        #expect(delegate.titles.isEmpty)
    }

    /// A string cut short at the cap is dropped even if the cap is raised
    /// before it ends (m10a review R1-5).
    @Test func aStringCutShortIsDroppedWhenTheCapIsRaised() {
        let (terminal, delegate) = makeTerminal(maximumOscBytes: 8)
        terminal.feed(text: "\(esc)]0;" + String(repeating: "c", count: 64))
        terminal.options.maximumOscBytes = 1024
        terminal.feed(text: "\u{07}")
        #expect(delegate.titles.isEmpty)
        terminal.feed(text: "\(esc)]0;ok\u{07}")
        #expect(delegate.titles == ["ok"])
    }
}
