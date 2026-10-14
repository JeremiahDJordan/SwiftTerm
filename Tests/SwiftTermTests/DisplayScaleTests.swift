//
//  DisplayScaleTests.swift
//  SwiftTerm
//
//  The default (CoreGraphics) renderer snaps cells to the pixel grid and sizes
//  lines with backingScaleFactor(). On iOS that was UIScreen.main.scale — the
//  device's main screen, not necessarily the one the view is on (an external
//  display, a second built-in display). It follows the view's trait
//  collection now, and a change of display scale re-measures the cells
//  without resetting the emulator.
//

#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import SwiftTerm

@MainActor
final class DisplayScaleTests {
    static func isOnPixelGrid(_ value: CGFloat, scale: CGFloat) -> Bool {
        abs((value * scale).rounded() - value * scale) < 0.0001
    }

    @Test func theScaleIsTheViewsDisplayScale() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(view.backingScaleFactor() == view.traitCollection.displayScale)
        // A scale other than the device's main screen's, which the old code returned.
        let other: CGFloat = view.traitCollection.displayScale == 2 ? 3 : 2
        view.traitOverrides.displayScale = other
        view.updateTraitsIfNeeded()
        #expect(view.backingScaleFactor() == other)
    }

    /// A display-scale change re-snaps the cells to the new pixel grid and
    /// re-grids like a font change: the running program keeps its modes.
    /// A font size whose cell width snaps differently at 1x and at 3x.
    static func sizeSnappingDifferently() -> CGFloat? {
        stride(from: 12.0, through: 16.0, by: 0.25).first { size in
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
            let width = "W".size(withAttributes: [.font: font]).width
            return width.rounded() != (width * 3).rounded() / 3
        }.map { CGFloat($0) }
    }

    @Test func aScaleChangeReMeasuresTheCellsAndKeepsTheModes() throws {
        let size = try #require(Self.sizeSnappingDifferently())
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.traitOverrides.displayScale = 1
        view.updateTraitsIfNeeded()
        view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let atOne = view.cellDimension
        #expect(Self.isOnPixelGrid(atOne.width, scale: 1) && Self.isOnPixelGrid(atOne.height, scale: 1))
        view.feed(byteArray: ArraySlice(Array("\u{1b}[?1h\u{1b}=".utf8)))

        view.traitOverrides.displayScale = 3
        view.updateTraitsIfNeeded()

        let atThree = view.cellDimension
        #expect(Self.isOnPixelGrid(atThree.width, scale: 3) && Self.isOnPixelGrid(atThree.height, scale: 3))
        #expect(atThree != atOne, "the cells were not re-measured for 3x")
        let terminal = view.getTerminal()
        #expect(terminal.cols == Int(600 / atThree.width) && terminal.rows == Int(400 / atThree.height))
        #expect(terminal.applicationCursor && terminal.applicationKeypad, "the scale change reset the emulator")
    }

    /// A display scale below 1 (only reachable through an override) is
    /// treated as 1: cells never snap to a grid coarser than a point.
    @Test func aScaleBelowOneIsTreatedAsOne() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.traitOverrides.displayScale = 0.5
        view.updateTraitsIfNeeded()
        #expect(view.backingScaleFactor() == 1)
    }

    /// A font size and two scales at which its cells come out the same.
    static func sameCellCase() -> (size: CGFloat, from: CGFloat, to: CGFloat)? {
        for size in stride(from: 8.0, through: 30.0, by: 0.25) {
            for (from, to) in [(CGFloat(1), CGFloat(2)), (2, 3), (1, 3), (2, 4)] {
                let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
                view.traitOverrides.displayScale = from
                view.updateTraitsIfNeeded()
                view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
                let cell = view.cellDimension
                view.traitOverrides.displayScale = to
                view.updateTraitsIfNeeded()
                if view.cellDimension == cell { return (CGFloat(size), from, to) }
            }
        }
        return nil
    }

    /// A scale change that leaves the cells as they were still repaints every
    /// row for the new scale, through the display path (the only way a paused
    /// Metal view redraws).
    @Test func aScaleChangeWithTheSameCellsRedrawsEveryRow() throws {
        let found = try #require(Self.sameCellCase())
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.traitOverrides.displayScale = found.from
        view.updateTraitsIfNeeded()
        view.font = UIFont.monospacedSystemFont(ofSize: found.size, weight: .regular)
        view.feed(byteArray: ArraySlice(Array("hello\r\n".utf8)))
        view.updateDisplay()
        #expect(!view.pendingDisplay && view.getTerminal().getUpdateRange() == nil)
        let cell = view.cellDimension

        view.traitOverrides.displayScale = found.to
        view.updateTraitsIfNeeded()

        #expect(view.cellDimension == cell)
        #expect(view.pendingDisplay, "a scale change must schedule a redraw")
        let range = view.getTerminal().getUpdateRange()
        #expect(range?.startY == 0 && (range?.endY ?? -1) >= view.getTerminal().rows - 1)
    }
}
#endif
