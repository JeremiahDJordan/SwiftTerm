//
//  FontChangeKeepsModesTests.swift
//  SwiftTerm
//
//  A font change re-lays the grid the way a frame change does
//  (processSizeChange). It must not soft-reset the emulator (DECSTR), which
//  the public resize(cols:rows:) does: a running program (vim, htop) would
//  lose its cursor-key and keypad modes, insert and origin mode, and a hidden
//  cursor would reappear. Margins reset when the grid changes, as on any
//  resize (Buffer.resize).
//

#if os(macOS) || os(iOS)
import Foundation
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import SwiftTerm

@MainActor
final class FontChangeKeepsModesTests {
    final class SizeRecorder: TerminalViewDelegate {
        var sizes: [String] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizes.append("\(newCols)x\(newRows)") }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    static func font(_ size: CGFloat) -> TTFont {
        TTFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func makeView(font size: CGFloat = 12, frame: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)) -> TerminalView {
        let view = TerminalView(frame: frame)
        view.font = font(size)
        return view
    }

    static func feed(_ view: TerminalView, _ text: String) {
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    /// Runs the display update the feed queued, so a later one is ours.
    static func flushDisplay(_ view: TerminalView) {
        view.updateDisplay()
        #expect(!view.pendingDisplay && view.getTerminal().getUpdateRange() == nil)
    }

    /// A font change repaints every row through the display path.
    static func expectFullRedrawQueued(_ view: TerminalView) {
        let terminal = view.getTerminal()
        #expect(view.pendingDisplay, "a font change must schedule a redraw")
        let range = terminal.getUpdateRange()
        #expect(range?.startY == 0 && (range?.endY ?? -1) >= terminal.rows - 1, "a font change must repaint every row")
    }

    @Test func modesSurviveAFontChangeThatChangesTheGrid() {
        let view = Self.makeView()
        let terminal = view.getTerminal()
        let before = (terminal.cols, terminal.rows)
        // DECCKM, DECKPAM, IRM, DECOM, cursor hidden (DECTCEM off)
        Self.feed(view, "\u{1b}[?1h\u{1b}=\u{1b}[4h\u{1b}[?6h\u{1b}[?25l")
        #expect(terminal.applicationCursor && terminal.applicationKeypad && terminal.insertMode
                && terminal.originMode && terminal.cursorHidden)
        Self.flushDisplay(view)

        view.font = Self.font(20)

        #expect(terminal.cols < before.0 && terminal.rows < before.1, "the larger font must re-grid")
        Self.expectFullRedrawQueued(view)
        #expect(terminal.applicationCursor, "DECCKM was reset by the font change")
        #expect(terminal.applicationKeypad, "the keypad mode was reset by the font change")
        #expect(terminal.insertMode, "insert mode was reset by the font change")
        #expect(terminal.originMode, "origin mode was reset by the font change")
        #expect(terminal.cursorHidden, "a hidden cursor was shown by the font change")
    }

    /// The scroll region follows the same rule as any resize: Buffer.resize
    /// resets it to the full screen when the grid changes. The font change
    /// matches a frame change that lands on the same grid.
    @Test func marginsResetLikeAnyResize() {
        let byFont = Self.makeView()
        Self.feed(byFont, "\u{1b}[2;10r")
        #expect(byFont.getTerminal().buffer.scrollTop == 1 && byFont.getTerminal().buffer.scrollBottom == 9)
        byFont.font = Self.font(20)
        let terminal = byFont.getTerminal()
        #expect(terminal.buffer.scrollTop == 0)
        #expect(terminal.buffer.scrollBottom == terminal.rows - 1)

        // The same grid change by frame.
        let byFrame = Self.makeView(font: 20)
        Self.feed(byFrame, "\u{1b}[2;10r")
        byFrame.processSizeChange(newSize: CGSize(width: 900, height: 700))
        byFrame.processSizeChange(newSize: byFont.frame.size)
        #expect(byFrame.getTerminal().cols == terminal.cols && byFrame.getTerminal().rows == terminal.rows)
        #expect(byFrame.getTerminal().buffer.scrollTop == terminal.buffer.scrollTop)
        #expect(byFrame.getTerminal().buffer.scrollBottom == terminal.buffer.scrollBottom)
    }

    /// The grid change is reported to the delegate, once, with the new grid.
    @Test func aFontChangeReportsTheNewGridOnce() {
        let view = Self.makeView()
        let recorder = SizeRecorder()
        view.terminalDelegate = recorder
        view.font = Self.font(20)
        let terminal = view.getTerminal()
        #expect(recorder.sizes == ["\(terminal.cols)x\(terminal.rows)"])
    }

    /// A larger font size whose cells, at this display's scale, are wider
    /// than `small`'s yet close enough that 5x5 cells of it plus half a cell
    /// are still 5x5 cells of `small`. Searched, because cells snap to the
    /// pixel grid: at 2x, 12 and 12.5 pt both snap to 7.5 pt wide.
    static func sizeSharingAGrid(with small: CGSize, from base: CGFloat) -> (size: CGFloat, cell: CGSize)? {
        // Taller cells as well if any size gives them, so the content and
        // caret checks see the height change too.
        let probe = makeView(font: base)
        var wider: (size: CGFloat, cell: CGSize)?
        for size in stride(from: base + 0.25, through: base + 4, by: 0.25) {
            probe.font = font(size)
            let large: CGSize = probe.cellDimension
            guard large.width > small.width,
                  6 * small.width > 5 * large.width + 0.5, 6 * small.height > 5 * large.height + 0.5 else { continue }
            if large.height > small.height { return (size, large) }
            wider = wider ?? (size, large)
        }
        return wider
    }

    /// A font change that keeps the grid (a frame between both fonts' cell
    /// sizes) keeps the margins, as a frame change that keeps the grid does,
    /// and reports the unchanged grid once (the cell size changed); the
    /// content and the caret follow the new cell size.
    @Test func aFontChangeThatKeepsTheGridKeepsTheMarginsAndUpdatesTheCellSize() throws {
        let small: CGSize = Self.makeView(font: 12).cellDimension
        let found = try #require(Self.sizeSharingAGrid(with: small, from: 12),
                                 "no font size near 12 pt shares a grid with it at this scale")
        let large = found.cell

        // The scroller's reserved width (macOS) is not part of the grid.
        let probe = Self.makeView(font: 12)
        let scroller = probe.frame.width - probe.getEffectiveWidth(size: probe.frame.size)
        let frame = CGRect(x: 0, y: 0, width: scroller + 5 * large.width + 0.5, height: 5 * large.height + 0.5)
        let view = Self.makeView(font: 12, frame: frame)
        let terminal = view.getTerminal()
        let grid = (terminal.cols, terminal.rows)
        try #require(grid == (5, 5))
        // Scroll region 2–4, DECCKM, cursor to row 3, column 4.
        Self.feed(view, "\u{1b}[2;4r\u{1b}[?1h\u{1b}[3;4H")
        let recorder = SizeRecorder()
        view.terminalDelegate = recorder
        Self.flushDisplay(view)

        view.font = Self.font(found.size)

        #expect(terminal.cols == grid.0 && terminal.rows == grid.1)
        #expect(recorder.sizes == ["5x5"], "the unchanged grid is reported once (the cell size changed)")
        Self.expectFullRedrawQueued(view)
        #expect(terminal.buffer.scrollTop == 1 && terminal.buffer.scrollBottom == 3)
        #expect(terminal.applicationCursor)
        #expect(view.cellDimension.width == large.width)
        #expect(view.caretFrame.height == large.height)
        #expect(abs(view.caretFrame.origin.x - 3 * large.width) < 0.001, "the caret must move to the new cell grid")
        #if os(iOS)
        #expect(view.contentSize.height == CGFloat(terminal.displayBuffer.lines.count) * large.height,
                "the scroll content must follow the new cell height")
        #endif
    }

    /// A frame too narrow for the minimum grid: the terminal keeps 2 columns,
    /// and font changes report that grid, not the 0 columns the frame would
    /// hold.
    @Test func aGridBelowTheMinimumIsReportedAsTheTerminalHasIt() {
        let view = Self.makeView(font: 12, frame: CGRect(x: 0, y: 0, width: 10, height: 400))
        let terminal = view.getTerminal()
        #expect(terminal.cols == 2)
        let recorder = SizeRecorder()
        view.terminalDelegate = recorder
        view.font = Self.font(40)
        view.font = Self.font(41)
        #expect(recorder.sizes.count == 2)
        #expect(recorder.sizes.allSatisfy { $0 == "\(terminal.cols)x\(terminal.rows)" }, "reported \(recorder.sizes)")
    }
}
#endif
