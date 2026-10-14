//
//  KittyLocalTransmissionPolicyTests.swift
//
//  The host's control over kitty graphics: the local transmission media
//  (`t=f`, `t=t`, `t=s`) are refused unless the host opts in, with one reply
//  for every path and without touching what the path names; kitty graphics can
//  be turned off altogether; and one transmission's size is bounded.
//
#if canImport(Darwin)
import Darwin
import Foundation
import Testing

@testable import SwiftTerm

final class KittyLocalTransmissionPolicyTests {
    @_silgen_name("shm_open")
    private static func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

    // `shm_open` is variadic in C (the mode follows `...`), and Swift cannot
    // call a variadic C function. The binding above is fine without O_CREAT,
    // where the mode is not read. To create, the mode has to arrive where
    // `va_arg` reads it: on Apple arm64 variadic arguments are passed on the
    // stack, so eight register-sized arguments fill x0-x7 and the mode goes
    // to the first stack slot; on x86_64 they are passed like any other.
    // The arm64 form calls the function through `dlsym`, so the module does
    // not declare `shm_open` with two different types.
    // (With the plain binding the object got whatever was on the stack as its
    // mode, sometimes without read permission, and these tests failed or
    // passed with the code layout; `fchmod` cannot fix it up: Darwin refuses
    // it on shared memory with EINVAL.)
    #if arch(arm64)
    private typealias ShmCreate = @convention(c) (UnsafePointer<CChar>, Int32, Int, Int, Int, Int, Int, Int, Int) -> Int32
    private static func swiftShmCreate(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return -1 }  // RTLD_DEFAULT
        let create = unsafeBitCast(symbol, to: ShmCreate.self)
        return create(name, oflag, 0, 0, 0, 0, 0, 0, Int(mode))
    }
    #else
    private static func swiftShmCreate(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32 {
        swiftShmOpen(name, oflag, mode)
    }
    #endif

    /// The refusal, exactly as the terminal sends it for image id 7.
    private static let refusal = "\u{1b}_Gi=7;ENOTSUP: unsupported transmission\u{1b}\\"

    /// A 1x1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII=")!

    private func makeTerminal(_ options: TerminalOptions = TerminalOptions(cols: 10, rows: 5)) -> (Terminal, TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        return (Terminal(delegate: delegate, options: options), delegate)
    }

    private func send(_ terminal: Terminal, _ control: String, payload: Data) {
        terminal.feed(text: "\u{1b}_G\(control);\(payload.base64EncodedString())\u{1b}\\")
    }

    /// What the terminal sent back since the last call, as text.
    private func replies(_ delegate: TerminalTestDelegate) -> String {
        defer { delegate.clearSentData() }
        return delegate.sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    /// A fresh directory in the temporary directory; its files carry
    /// "tty-graphics-protocol" in their names, so a `t=t` transmission
    /// would be allowed to delete them.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tty-graphics-protocol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func createSharedMemory(name: String, bytes: [UInt8]) -> Bool {
        let fd = name.withCString { swiftShmCreate($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & 0o600 == 0o600,
              ftruncate(fd, off_t(bytes.count)) == 0,
              let map = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              map != MAP_FAILED else {
            _ = name.withCString { shm_unlink($0) }
            return false
        }
        bytes.withUnsafeBytes { buf in _ = memcpy(map, buf.baseAddress!, bytes.count) }
        munmap(map, bytes.count)
        return true
    }

    private static func sharedMemoryExists(_ name: String) -> Bool {
        let fd = name.withCString { swiftShmOpen($0, O_RDONLY, 0) }
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Darwin (macOS and the iOS Simulator) always has POSIX shared memory,
    /// so there the shm tests always run, and a helper that cannot create an
    /// object fails them instead of skipping them.
    private static func sharedMemoryAvailable() -> Bool {
        #if canImport(Darwin)
        return true
        #else
        let name = "/st-kitty-\(UInt32.random(in: 0...UInt32.max))"
        guard createSharedMemory(name: name, bytes: [0]) else { return false }
        _ = name.withCString { shm_unlink($0) }
        return true
        #endif
    }

    // MARK: Local media refused by default

    @Test func localMediaAreOffByDefault() {
        #expect(TerminalOptions.default.allowKittyLocalFileTransmission == false)
        #expect(TerminalOptions().allowKittyLocalFileTransmission == false)
        #expect(TerminalOptions.default.kittyGraphicsEnabled == true)
    }

    /// `t=f` and `t=t`, with and without display, and a query for them: one
    /// reply whether the path names a readable image, a non-image, a missing
    /// file, a directory, or is not even a path. Nothing is read or removed.
    @Test func fileMediaGetTheSameRefusalForEveryPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("tty-graphics-protocol-image.png")
        let other = dir.appendingPathComponent("tty-graphics-protocol-store.sqlite")
        try Self.png.write(to: image)
        try Data("SQLite format 3\u{0}".utf8).write(to: other)
        let payloads: [Data] = [
            Data(image.path.utf8),
            Data(other.path.utf8),
            Data(dir.appendingPathComponent("tty-graphics-protocol-missing.png").path.utf8),
            Data(dir.path.utf8),
            Data("/dev/null".utf8),
            Data([0x2f, 0x00, 0x78]),
        ]
        let (t, delegate) = makeTerminal()
        for medium in ["f", "t"] {
            for action in ["t", "T", "q"] {
                for payload in payloads {
                    send(t, "a=\(action),t=\(medium),f=100,i=7", payload: payload)
                    #expect(replies(delegate) == Self.refusal, "a=\(action),t=\(medium) \(String(decoding: payload, as: UTF8.self))")
                }
                // An empty payload too: refused before it is decoded.
                t.feed(text: "\u{1b}_Ga=\(action),t=\(medium),f=100,i=7;\u{1b}\\")
                #expect(replies(delegate) == Self.refusal)
            }
        }
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(try Data(contentsOf: image) == Self.png)
        #expect(try Data(contentsOf: other) == Data("SQLite format 3\u{0}".utf8))
    }

    /// `t=t` would read and delete a temporary file: the file survives.
    @Test func aTemporaryFileTransmissionLeavesTheFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tty-graphics-protocol-1.rgb")
        try Data([1, 2, 3]).write(to: file)
        let (t, delegate) = makeTerminal()
        send(t, "a=T,t=t,f=24,s=1,v=1,i=7", payload: Data(file.path.utf8))
        #expect(replies(delegate) == Self.refusal)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    /// Quiet mode suppresses the refusal like any error (`q=2`).
    @Test func theRefusalHonoursQuietMode() throws {
        let (t, delegate) = makeTerminal()
        send(t, "a=t,t=f,f=100,i=7,q=2", payload: Data("/missing".utf8))
        #expect(replies(delegate) == "")
        send(t, "a=t,t=f,f=100,i=7,q=0", payload: Data("/missing".utf8))
        #expect(replies(delegate) == Self.refusal)
    }

    /// `t=s` would map a shared-memory object and unlink it: an existing one
    /// survives, and a missing one gets the same reply.
    @Test(.enabled(if: KittyLocalTransmissionPolicyTests.sharedMemoryAvailable()))
    func aSharedMemoryTransmissionLeavesTheObject() throws {
        let name = "/st-kitty-\(UInt32.random(in: 0...UInt32.max))"
        try #require(Self.createSharedMemory(name: name, bytes: [1, 2, 3]))
        defer { _ = name.withCString { shm_unlink($0) } }
        let (t, delegate) = makeTerminal()
        for action in ["t", "T", "q"] {
            send(t, "a=\(action),t=s,f=24,s=1,v=1,i=7", payload: Data(name.utf8))
            #expect(replies(delegate) == Self.refusal)
            send(t, "a=\(action),t=s,f=24,s=1,v=1,i=7", payload: Data((name + "-missing").utf8))
            #expect(replies(delegate) == Self.refusal)
        }
        #expect(Self.sharedMemoryExists(name))
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    /// Only a chunked transmission's first chunk says what it is (a medium
    /// other than `t=d` cannot be chunked): a later chunk naming a local
    /// medium is just more base64.
    @Test func aLaterChunkCannotNameALocalMedium() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tty-graphics-protocol-1.rgb")
        try Data([1, 2, 3]).write(to: file)
        for allowed in [false, true] {
            let (t, delegate) = makeTerminal(TerminalOptions(cols: 10, rows: 5, allowKittyLocalFileTransmission: allowed))
            t.feed(text: "\u{1b}_Ga=t,t=d,f=24,s=1,v=1,i=7,m=1;\u{1b}\\")
            send(t, "a=t,t=t,f=24,s=1,v=1,i=8,m=0", payload: Data(file.path.utf8))
            #expect(replies(delegate) == "\u{1b}_Gi=7;EINVAL: bad payload\u{1b}\\")
            #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        }
    }

    // MARK: Direct transmission

    @Test func directTransmissionStillWorks() {
        let (t, delegate) = makeTerminal()
        send(t, "a=t,f=24,s=1,v=1,i=9", payload: Data([1, 2, 3]))
        #expect(replies(delegate) == "\u{1b}_Gi=9;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[9] != nil)
        send(t, "a=T,f=100,i=10", payload: Self.png)
        #expect(replies(delegate) == "\u{1b}_Gi=10;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[10] != nil)
        // Chunked.
        let b64 = Array(Data([4, 5, 6, 7, 8, 9]).base64EncodedString())
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=11,m=1;\(String(b64[0..<4]))\u{1b}\\")
        t.feed(text: "\u{1b}_Gm=0;\(String(b64[4...]))\u{1b}\\")
        #expect(replies(delegate) == "\u{1b}_Gi=11;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[11] != nil)
    }

    // MARK: Opting in

    /// The host's opt-in (here at run time) restores the local media.
    @Test func optingInRestoresTheLocalMedia() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tty-graphics-protocol-image.png")
        try Self.png.write(to: file)
        let temporary = dir.appendingPathComponent("tty-graphics-protocol-1.rgb")
        try Data([1, 2, 3]).write(to: temporary)

        let (t, delegate) = makeTerminal()
        t.options.allowKittyLocalFileTransmission = true
        send(t, "a=t,t=f,f=100,i=7", payload: Data(file.path.utf8))
        #expect(replies(delegate) == "\u{1b}_Gi=7;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[7] != nil)
        send(t, "a=t,t=t,f=24,s=1,v=1,i=8", payload: Data(temporary.path.utf8))
        #expect(replies(delegate) == "\u{1b}_Gi=8;OK\u{1b}\\")
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        // ... and the path-dependent replies with them.
        send(t, "a=t,t=f,f=100,i=7", payload: Data(dir.appendingPathComponent("missing").path.utf8))
        #expect(replies(delegate) == "\u{1b}_Gi=7;EINVAL: bad path\u{1b}\\")
    }

    @Test(.enabled(if: KittyLocalTransmissionPolicyTests.sharedMemoryAvailable()))
    func optingInRestoresSharedMemory() throws {
        let name = "/st-kitty-\(UInt32.random(in: 0...UInt32.max))"
        try #require(Self.createSharedMemory(name: name, bytes: [1, 2, 3]))
        defer { _ = name.withCString { shm_unlink($0) } }
        let (t, delegate) = makeTerminal(TerminalOptions(cols: 10, rows: 5, allowKittyLocalFileTransmission: true))
        send(t, "a=t,t=s,f=24,s=1,v=1,i=7", payload: Data(name.utf8))
        #expect(replies(delegate) == "\u{1b}_Gi=7;OK\u{1b}\\")
        #expect(!Self.sharedMemoryExists(name))
    }

    // MARK: Kitty graphics off

    /// Off, kitty graphics is ignored like an unknown APC: no reply (a
    /// client's capability query then gets only the DA1 answer that follows
    /// it), nothing stored, nothing touched, and the screen is unaffected.
    @Test func graphicsOffIgnoresEverySequence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let temporary = dir.appendingPathComponent("tty-graphics-protocol-1.rgb")
        try Data([1, 2, 3]).write(to: temporary)

        let (t, delegate) = makeTerminal(TerminalOptions(cols: 10, rows: 5, kittyGraphicsEnabled: false,
                                                         allowKittyLocalFileTransmission: true))
        send(t, "a=q,f=24,s=1,v=1,i=1", payload: Data([1, 2, 3]))
        send(t, "a=T,f=24,s=1,v=1,i=2", payload: Data([1, 2, 3]))
        send(t, "a=T,f=100,i=3,U=1", payload: Self.png)
        send(t, "a=t,t=t,f=24,s=1,v=1,i=4", payload: Data(temporary.path.utf8))
        send(t, "a=t,t=f,f=24,s=1,v=1,i=5", payload: Data("/missing".utf8))
        t.feed(text: "\u{1b}_Ga=p,i=2\u{1b}\\\u{1b}_Ga=d\u{1b}\\x")
        #expect(replies(delegate) == "")
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(TerminalTestHarness.lineText(buffer: t.buffer, row: 0) == "x")
    }

    /// Turning it off drops a chunked transmission in progress; turning it
    /// back on starts afresh.
    @Test func turningGraphicsOffDropsAPendingTransmission() {
        let (t, delegate) = makeTerminal()
        let b64 = Data([1, 2, 3]).base64EncodedString()
        t.feed(text: "\u{1b}_Ga=t,f=24,s=1,v=1,i=1,m=1;\(b64)\u{1b}\\")
        #expect(t.kittyGraphicsState.pending != nil)
        t.options.kittyGraphicsEnabled = false
        t.feed(text: "\u{1b}_Gm=0;\u{1b}\\")
        #expect(t.kittyGraphicsState.pending == nil)
        t.options.kittyGraphicsEnabled = true
        send(t, "a=t,f=24,s=1,v=1,i=2", payload: Data([1, 2, 3]))
        #expect(replies(delegate) == "\u{1b}_Gi=2;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }

    /// Off, the parser keeps only an APC's command byte, however long the
    /// sequence; so does any APC other than kitty graphics.
    @Test func unreadApcContentIsNotBuffered() {
        let filler = String(repeating: "A", count: 64 * 1024)
        let (off, _) = makeTerminal(TerminalOptions(cols: 10, rows: 5, kittyGraphicsEnabled: false))
        off.feed(text: "\u{1b}_Ga=T,f=100;" + filler)
        #expect(off.parser._apc.count == 1)
        off.feed(text: "\u{1b}\\x")
        #expect(TerminalTestHarness.lineText(buffer: off.buffer, row: 0) == "x")

        let (on, _) = makeTerminal()
        on.feed(text: "\u{1b}_X" + filler)
        #expect(on.parser._apc.count == 1)
        on.feed(text: "\u{1b}_Ga=T,f=100;" + filler)
        #expect(on.parser._apc.count == 1 + "a=T,f=100;".count + filler.count)
        on.feed(text: "\u{1b}\\")
        #expect(on.parser._apc.isEmpty)
    }

    // MARK: Size caps

    /// A chunked transmission that grows past the cap is abandoned with an
    /// error; the next one works.
    @Test func aChunkedTransmissionPastTheCapIsRefused() {
        let (t, delegate) = makeTerminal()
        t.kittyGraphicsState.maxEncodedPayloadBytes = 8
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=1,m=1;AAAA\u{1b}\\")
        t.feed(text: "\u{1b}_Gm=1;AAAA\u{1b}\\")
        #expect(replies(delegate) == "")
        t.feed(text: "\u{1b}_Gm=1;AAAA\u{1b}\\")
        #expect(replies(delegate) == "\u{1b}_Gi=1;EFBIG: too much data\u{1b}\\")
        #expect(t.kittyGraphicsState.pending == nil)
        // Exactly at the cap is fine.
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=2,m=1;AAAA\u{1b}\\")
        t.feed(text: "\u{1b}_Gm=0;AAAA\u{1b}\\")
        #expect(replies(delegate) == "\u{1b}_Gi=2;OK\u{1b}\\")
    }

    /// One sequence longer than the cap allows is dropped by the parser
    /// (with any transmission it continued), without being buffered whole;
    /// the parser then carries on.
    @Test func anOverlongSequenceIsDropped() {
        let (t, delegate) = makeTerminal()
        t.kittyGraphicsState.maxEncodedPayloadBytes = 8
        let limit = t.kittyGraphicsState.maxSequenceBytes
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=1,m=1;AAAA\u{1b}\\")
        #expect(t.kittyGraphicsState.pending != nil)
        t.feed(text: "\u{1b}_Gm=1;" + String(repeating: "A", count: limit * 2))
        #expect(t.parser._apc.count == limit + 1)
        t.feed(text: "\u{1b}\\x")
        #expect(t.kittyGraphicsState.pending == nil)
        #expect(replies(delegate) == "")
        #expect(TerminalTestHarness.lineText(buffer: t.buffer, row: 0) == "x")
        send(t, "a=t,f=24,s=1,v=1,i=2", payload: Data([1, 2, 3]))
        #expect(replies(delegate) == "\u{1b}_Gi=2;OK\u{1b}\\")
    }

    /// The parser's boundary: a sequence of exactly `maxSequenceBytes`
    /// (command byte included) is dispatched, one byte more is not.
    @Test func theSequenceCapIsExact() {
        let (t, delegate) = makeTerminal()
        t.kittyGraphicsState.maxEncodedPayloadBytes = 8
        let limit = t.kittyGraphicsState.maxSequenceBytes
        let control = "Ga=t,f=24,s=1,v=1,i=1;"
        t.feed(text: "\u{1b}_" + control + String(repeating: "A", count: limit - control.count) + "\u{1b}\\")
        // Dispatched: its payload is over the transmission cap.
        #expect(replies(delegate) == "\u{1b}_Gi=1;EFBIG: too much data\u{1b}\\")
        t.feed(text: "\u{1b}_" + control + String(repeating: "A", count: limit - control.count + 1) + "\u{1b}\\")
        #expect(replies(delegate) == "")
    }

    /// A full reset (RIS) drops a chunked transmission in progress.
    @Test func aResetDropsAPendingTransmission() {
        let (t, _) = makeTerminal()
        t.feed(text: "\u{1b}_Ga=t,f=24,s=1,v=1,i=1,m=1;AAAA\u{1b}\\")
        #expect(t.kittyGraphicsState.pending != nil)
        t.feed(text: "\u{1b}c")
        #expect(t.kittyGraphicsState.pending == nil)
    }

    /// Erasing the display (ED 2) clears images but not a chunked
    /// transmission in progress.
    @Test func erasingTheDisplayKeepsAPendingTransmission() {
        let (t, delegate) = makeTerminal()
        let b64 = Array(Data([4, 5, 6, 7, 8, 9]).base64EncodedString())
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=11,m=1;\(String(b64[0..<4]))\u{1b}\\")
        t.feed(text: "\u{1b}[2J")
        t.feed(text: "\u{1b}_Gm=0;\(String(b64[4...]))\u{1b}\\")
        #expect(replies(delegate) == "\u{1b}_Gi=11;OK\u{1b}\\")
        #expect(t.kittyGraphicsState.imagesById[11] != nil)
    }

    // MARK: Compression (o=z)

    /// zlib (RFC 1950) of [1, 2, 3], and the bare deflate stream inside it.
    private static let zlib123 = Data(base64Encoded: "eJxjZGIGAAANAAc=")!
    private static let deflate123 = Data(base64Encoded: "Y2RiBgA=")!

    @Test func compressedDataInflates() {
        #expect(Terminal.inflateKittyData(Self.zlib123, limit: 100) == Data([1, 2, 3]))
        #expect(Terminal.inflateKittyData(Self.deflate123, limit: 100) == Data([1, 2, 3]))
        // Bare deflate whose first bytes pass the zlib header check (a
        // stored block with nonzero padding bits): 29 bytes, 0 to 28.
        let zlibShaped = Data(base64Encoded: "CB0A4v8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHAMA")!
        #expect(Terminal.inflateKittyData(zlibShaped, limit: 100) == Data(0..<29))
        let (t, delegate) = makeTerminal()
        send(t, "a=t,o=z,f=24,s=1,v=1,i=1", payload: Self.zlib123)
        send(t, "a=t,o=z,f=24,s=1,v=1,i=2", payload: Self.deflate123)
        #expect(replies(delegate) == "\u{1b}_Gi=1;OK\u{1b}\\\u{1b}_Gi=2;OK\u{1b}\\")
    }

    /// Malformed or truncated data is an error, not an endless loop (the
    /// decoder used to wait forever for more input).
    @Test func malformedCompressedDataIsRefused() {
        var badChecksum = Self.zlib123
        badChecksum[badChecksum.endIndex - 1] ^= 1
        var presetDictionary = Self.zlib123
        presetDictionary[1] = 0xbb   // FDICT set, FCHECK still valid
        let cases: [Data] = [
            Data(base64Encoded: "Y2RiBg==")!,          // truncated deflate
            Data(base64Encoded: "ABAA7/8=")!,          // a stored block cut short
            Self.zlib123.prefix(Self.zlib123.count - 4), // no Adler-32 trailer
            badChecksum,
            presetDictionary,
            Data([0x78, 0x9c]),
            Data(),
        ]
        for data in cases {
            #expect(Terminal.inflateKittyData(data, limit: 100) == nil, "\(data as NSData)")
        }
        let (t, delegate) = makeTerminal()
        send(t, "a=q,o=z,f=24,s=1,v=1,i=1", payload: Data(base64Encoded: "Y2RiBg==")!)
        #expect(replies(delegate) == "\u{1b}_Gi=1;EINVAL: bad payload\u{1b}\\")
    }

    /// The output cap holds while inflating: 1 MiB of zeros in about 1 KiB
    /// stops at the cap.
    @Test func inflationStopsAtTheCap() throws {
        let zeros = try (Data(count: 1 << 20) as NSData).compressed(using: .zlib) as Data
        #expect(zeros.count < 4096)
        #expect(Terminal.inflateKittyData(zeros, limit: 1 << 20)?.count == 1 << 20)
        #expect(Terminal.inflateKittyData(zeros, limit: (1 << 20) - 1) == nil)
        #expect(Terminal.inflateKittyData(Self.zlib123, limit: 2) == nil)
        #expect(Terminal.inflateKittyData(Self.zlib123, limit: 3) == Data([1, 2, 3]))
    }

    @Test func adler32MatchesZlib() {
        #expect(Terminal.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Terminal.adler32(Data()) == 1)
        // Past zlib's NMAX block, where the sums must be reduced.
        #expect(Terminal.adler32(Data(repeating: 0xff, count: 100_000)) == 0x149A_302C)
    }

    @Test func theCapCoversTheLargestImage() {
        // 400 MiB decoded, in base64.
        #expect(Terminal.kittyMaxEncodedPayloadBytes == 559_240_536)
        #expect(KittyGraphicsState().maxEncodedPayloadBytes == Terminal.kittyMaxEncodedPayloadBytes)
    }
}
#endif
