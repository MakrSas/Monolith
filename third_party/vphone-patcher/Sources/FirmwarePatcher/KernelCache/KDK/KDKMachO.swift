// KDKMachO.swift — The Mach-O images of a kernel collection, as the KDK export reads them.
//
// The export (`KDKImageExport`) rebuilds a fileset entry of an MH_FILESET
// kernelcache as the standalone Mach-O ld64 would have written. It is a port of
// blacktop/go-macho's `File.Export` (go-macho#94), and this file holds the parts
// of go-macho it reads through: an entry's load commands, segments, sections,
// symbols and indirect symbols, with addresses resolved through the
// collection's own segments, exactly as go-macho resolves them.
//
// Only what kernel collections contain is modelled: 64-bit little-endian
// Mach-O, with offsets of an entry's load commands relative to the collection.

import Foundation
import VPhonePatchKit

enum KDKMachO {
    // MARK: - Constants

    static let magic64: UInt32 = 0xFEED_FACF
    static let headerSize = 32
    static let segmentCommandSize = 72
    static let sectionSize = 80
    static let nlistSize = 16
    static let pointerSize: UInt64 = 8
    /// go-macho's page size for arm64 (16 KB).
    static let pageSize: UInt64 = 0x4000

    static let mhFileset: UInt32 = 0xC
    static let mhDylibInCache: UInt32 = 0x8000_0000

    static let lcSymtab: UInt32 = 0x2
    static let lcUnixThread: UInt32 = 0x5
    static let lcDysymtab: UInt32 = 0xB
    static let lcSegment64: UInt32 = 0x19
    static let lcUUID: UInt32 = 0x1B
    static let lcCodeSignature: UInt32 = 0x1D
    static let lcSegmentSplitInfo: UInt32 = 0x1E
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcDyldInfo: UInt32 = 0x22
    static let lcDyldInfoOnly: UInt32 = 0x8000_0022
    static let lcFunctionStarts: UInt32 = 0x26
    static let lcMain: UInt32 = 0x8000_0028
    static let lcDataInCode: UInt32 = 0x29
    static let lcSourceVersion: UInt32 = 0x2A
    static let lcDylibCodeSignDRs: UInt32 = 0x2B
    static let lcEncryptionInfo64: UInt32 = 0x2C
    static let lcLinkerOptimizationHint: UInt32 = 0x2E
    static let lcBuildVersion: UInt32 = 0x32
    static let lcDyldExportsTrie: UInt32 = 0x8000_0033
    static let lcDyldChainedFixups: UInt32 = 0x8000_0034
    static let lcFilesetEntry: UInt32 = 0x8000_0035
    static let lcFunctionVariants: UInt32 = 0x37
    static let lcFunctionVariantFixups: UInt32 = 0x38

    static let armThreadState64: UInt32 = 6
    /// `sizeof(arm_thread_state64_t)`: x0-x28, fp, lr, sp, pc, cpsr, pad.
    static let armThreadState64Size = 272

    static let indirectSymbolLocal: UInt32 = 0x8000_0000
    static let indirectSymbolAbsolute: UInt32 = 0x4000_0000

    // MARK: - Model

    struct Section {
        var name: String
        var segmentName: String
        var address: UInt64
        var size: UInt64
        var offset: UInt32
        var align: UInt32
        var relocationOffset: UInt32
        var relocationCount: UInt32
        var flags: UInt32
        var reserved1: UInt32
        var reserved2: UInt32
        var reserved3: UInt32

        var type: UInt32 {
            flags & 0xFF
        }

        var isNonLazySymbolPointers: Bool {
            type == 0x6
        }

        var isLazySymbolPointers: Bool {
            type == 0x7
        }

        var isSymbolPointers: Bool {
            isNonLazySymbolPointers || isLazySymbolPointers
        }

        /// S_ZEROFILL, S_GB_ZEROFILL or S_THREAD_LOCAL_ZEROFILL.
        var isZerofill: Bool {
            type == 0x1 || type == 0xC || type == 0x12
        }

        func contains(_ address: UInt64) -> Bool {
            self.address <= address && address < self.address &+ size
        }
    }

    struct Segment {
        var command: UInt32
        var commandSize: UInt32
        var name: String
        var address: UInt64
        var memorySize: UInt64
        var fileOffset: UInt64
        var fileSize: UInt64
        var maxProtection: UInt32
        var initialProtection: UInt32
        var sectionCount: UInt32
        var flags: UInt32
        var sections: [Section]

        /// go-macho's segment lookup: `[address, address + memorySize)`.
        func contains(_ address: UInt64) -> Bool {
            address >= self.address && address &- self.address < memorySize
        }
    }

    /// One load command as it appears in the image. Segments are parsed; every
    /// other command is kept as its bytes, which the export patches in place.
    struct LoadCommand {
        var command: UInt32
        var bytes: [UInt8]
        var segment: Segment?

        var size: Int {
            if let segment {
                return segmentCommandSize + segment.sections.count * sectionSize
            }
            return bytes.count
        }
    }

    struct Header {
        var magic: UInt32
        var cpuType: UInt32
        var cpuSubtype: UInt32
        var fileType: UInt32
        var commandCount: UInt32
        var commandsSize: UInt32
        var flags: UInt32
        var reserved: UInt32

        var bytes: [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(headerSize)
            for field in [magic, cpuType, cpuSubtype, fileType, commandCount, commandsSize, flags, reserved] {
                out.appendLE(field)
            }
            return out
        }
    }

    // MARK: - Byte Access

    /// Little-endian reads with bounds checks, over the whole collection.
    struct Bytes {
        let data: Data

        var count: Int {
            data.count
        }

        func u8(_ offset: Int) throws -> UInt8 {
            guard offset >= 0, offset < data.count else { throw outOfBounds(offset, 1) }
            return data[data.startIndex + offset]
        }

        func u16(_ offset: Int) throws -> UInt16 {
            try check(offset, 2)
            return data.loadLE(UInt16.self, at: offset)
        }

        func u32(_ offset: Int) throws -> UInt32 {
            try check(offset, 4)
            return data.loadLE(UInt32.self, at: offset)
        }

        func u64(_ offset: Int) throws -> UInt64 {
            try check(offset, 8)
            return data.loadLE(UInt64.self, at: offset)
        }

        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            try check(offset, count)
            return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + count])
        }

        func check(_ offset: Int, _ count: Int) throws {
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
                throw outOfBounds(offset, count)
            }
        }

        func outOfBounds(_ offset: Int, _ count: Int) -> PatcherError {
            .invalidFormat("kernelcache read of \(count) bytes at 0x\(String(offset, radix: 16)) is out of bounds")
        }
    }

    static func name(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    static func fixedName(_ name: String) -> [UInt8] {
        var out = Array(name.utf8.prefix(16))
        out += [UInt8](repeating: 0, count: 16 - out.count)
        return out
    }

    // MARK: - Parsing

    /// The header and load commands at `offset` in `bytes`, with segments and
    /// sections parsed.
    static func loadCommands(in bytes: Bytes, at offset: Int) throws -> (Header, [LoadCommand]) {
        try bytes.check(offset, headerSize)
        let header = try Header(
            magic: bytes.u32(offset), cpuType: bytes.u32(offset + 4), cpuSubtype: bytes.u32(offset + 8),
            fileType: bytes.u32(offset + 12), commandCount: bytes.u32(offset + 16), commandsSize: bytes.u32(offset + 20),
            flags: bytes.u32(offset + 24), reserved: bytes.u32(offset + 28)
        )
        guard header.magic == magic64 else {
            throw PatcherError.invalidFormat("Mach-O at 0x\(String(offset, radix: 16)) is not 64-bit little-endian")
        }
        try bytes.check(offset + headerSize, Int(header.commandsSize))
        guard UInt64(header.commandCount) * 8 <= UInt64(header.commandsSize) else {
            throw PatcherError.invalidFormat("load command count exceeds sizeofcmds")
        }
        let commandsEnd = offset + headerSize + Int(header.commandsSize)
        var commands: [LoadCommand] = []
        var cursor = offset + headerSize
        for _ in 0 ..< header.commandCount {
            guard cursor <= commandsEnd - 8 else {
                throw PatcherError.invalidFormat("load command header exceeds sizeofcmds")
            }
            let command = try bytes.u32(cursor)
            let size = try Int(bytes.u32(cursor + 4))
            guard size >= 8 else {
                throw PatcherError.invalidFormat("load command 0x\(String(command, radix: 16)) has size \(size)")
            }
            guard size <= commandsEnd - cursor else {
                throw PatcherError.invalidFormat("load command exceeds sizeofcmds")
            }
            let minimum: Int = switch command {
            case lcSegment64: segmentCommandSize
            case lcSymtab: 24
            case lcDysymtab: 80
            case lcDyldInfo, lcDyldInfoOnly: 48
            case lcFilesetEntry: 32
            case lcUnixThread: 16
            case lcUUID: 24
            case lcCodeSignature, lcSegmentSplitInfo, lcEncryptionInfo, lcDyldChainedFixups,
                 lcFunctionStarts, lcDataInCode, lcFunctionVariants, lcFunctionVariantFixups,
                 lcDylibCodeSignDRs, lcEncryptionInfo64, lcLinkerOptimizationHint, lcDyldExportsTrie:
                16
            default: 8
            }
            guard size >= minimum else {
                throw PatcherError.invalidFormat("short load command 0x\(String(command, radix: 16))")
            }
            let raw = try bytes.bytes(cursor, size)
            var load = LoadCommand(command: command, bytes: raw, segment: nil)
            if command == lcSegment64 {
                load.segment = try segment(raw)
            }
            commands.append(load)
            cursor += size
        }
        return (header, commands)
    }

    static func segment(_ raw: [UInt8]) throws -> Segment {
        guard raw.count >= segmentCommandSize else {
            throw PatcherError.invalidFormat("LC_SEGMENT_64 of \(raw.count) bytes")
        }
        let count = raw.le(UInt32.self, 64)
        guard raw.count >= segmentCommandSize + Int(count) * sectionSize else {
            throw PatcherError.invalidFormat("LC_SEGMENT_64 \(name(Array(raw[8 ..< 24]))) is too short for \(count) sections")
        }
        var sections: [Section] = []
        for index in 0 ..< Int(count) {
            let base = segmentCommandSize + index * sectionSize
            sections.append(Section(
                name: name(Array(raw[base ..< base + 16])),
                segmentName: name(Array(raw[base + 16 ..< base + 32])),
                address: raw.le(UInt64.self, base + 32),
                size: raw.le(UInt64.self, base + 40),
                offset: raw.le(UInt32.self, base + 48),
                align: raw.le(UInt32.self, base + 52),
                relocationOffset: raw.le(UInt32.self, base + 56),
                relocationCount: raw.le(UInt32.self, base + 60),
                flags: raw.le(UInt32.self, base + 64),
                reserved1: raw.le(UInt32.self, base + 68),
                reserved2: raw.le(UInt32.self, base + 72),
                reserved3: raw.le(UInt32.self, base + 76)
            ))
        }
        let address = raw.le(UInt64.self, 24), memorySize = raw.le(UInt64.self, 32)
        let fileOffset = raw.le(UInt64.self, 40), fileSize = raw.le(UInt64.self, 48)
        guard !address.addingReportingOverflow(memorySize).overflow,
              !fileOffset.addingReportingOverflow(fileSize).overflow,
              memorySize <= UInt64(Int.max) - KDKMachO.pageSize,
              fileSize <= UInt64(Int.max) - KDKMachO.pageSize
        else {
            throw PatcherError.invalidFormat("segment address or size overflow")
        }
        for section in sections {
            guard !section.address.addingReportingOverflow(section.size).overflow else {
                throw PatcherError.invalidFormat("section address or size overflow")
            }
        }
        return Segment(
            command: raw.le(UInt32.self, 0), commandSize: raw.le(UInt32.self, 4),
            name: name(Array(raw[8 ..< 24])),
            address: raw.le(UInt64.self, 24), memorySize: raw.le(UInt64.self, 32),
            fileOffset: raw.le(UInt64.self, 40), fileSize: raw.le(UInt64.self, 48),
            maxProtection: raw.le(UInt32.self, 56), initialProtection: raw.le(UInt32.self, 60),
            sectionCount: count, flags: raw.le(UInt32.self, 68), sections: sections
        )
    }

    static func write(_ segment: Segment, to out: inout [UInt8]) {
        out.appendLE(segment.command)
        out.appendLE(segment.commandSize)
        out += fixedName(segment.name)
        out.appendLE(segment.address)
        out.appendLE(segment.memorySize)
        out.appendLE(segment.fileOffset)
        out.appendLE(segment.fileSize)
        out.appendLE(segment.maxProtection)
        out.appendLE(segment.initialProtection)
        out.appendLE(segment.sectionCount)
        out.appendLE(segment.flags)
        for section in segment.sections {
            out += fixedName(section.name)
            out += fixedName(section.segmentName)
            out.appendLE(section.address)
            out.appendLE(section.size)
            out.appendLE(section.offset)
            out.appendLE(section.align)
            out.appendLE(section.relocationOffset)
            out.appendLE(section.relocationCount)
            out.appendLE(section.flags)
            out.appendLE(section.reserved1)
            out.appendLE(section.reserved2)
            out.appendLE(section.reserved3)
        }
    }

    /// The symbols of an LC_SYMTAB, named from its string table as go-macho does:
    /// a name offset past the table gives an empty name.
    static func symbols(_ symtab: [UInt8], in bytes: Bytes) throws -> [KDKSymbol] {
        let symbolOffset = Int(symtab.le(UInt32.self, 8))
        let count = Int(symtab.le(UInt32.self, 12))
        let stringOffset = Int(symtab.le(UInt32.self, 16))
        let stringSize = Int(symtab.le(UInt32.self, 20))
        try bytes.check(stringOffset, stringSize)
        try bytes.check(symbolOffset, count * nlistSize)
        let strings = bytes.data
        let stringBase = strings.startIndex + stringOffset
        func string(_ offset: UInt64) -> String {
            guard offset < UInt64(stringSize) else { return "" }
            let start = stringBase + Int(offset)
            let end = strings[start ..< stringBase + stringSize].firstIndex(of: 0) ?? stringBase + stringSize
            return String(decoding: strings[start ..< end], as: UTF8.self)
        }
        var symbols: [KDKSymbol] = []
        symbols.reserveCapacity(count)
        for index in 0 ..< count {
            let base = symbolOffset + index * nlistSize
            let type = try bytes.u8(base + 4)
            let value = try bytes.u64(base + 8)
            var symbol = try KDKSymbol(
                name: string(UInt64(bytes.u32(base))), type: type, sect: bytes.u8(base + 5),
                desc: bytes.u16(base + 6), value: value
            )
            if symbol.isIndirect {
                symbol.indirectName = string(value)
            }
            symbols.append(symbol)
        }
        return symbols
    }

    static func indirectSymbols(_ dysymtab: [UInt8], in bytes: Bytes) throws -> [UInt32] {
        let offset = Int(dysymtab.le(UInt32.self, 56))
        let count = Int(dysymtab.le(UInt32.self, 60))
        try bytes.check(offset, count * 4)
        return try (0 ..< count).map { try bytes.u32(offset + $0 * 4) }
    }
}

// MARK: - Symbols

/// A symbol table entry, or a symbol the extraction adds to an image.
struct KDKSymbol: Equatable {
    var name: String
    var indirectName = ""
    var type: UInt8
    var sect: UInt8
    var desc: UInt16
    var value: UInt64
    /// For a pointer bound to `name + bindAddend` (set by the export only).
    var bindAddend: Int64 = 0

    init(name: String, indirectName: String = "", type: UInt8, sect: UInt8, desc: UInt16, value: UInt64) {
        self.name = name
        self.indirectName = indirectName
        self.type = type
        self.sect = sect
        self.desc = desc
        self.value = value
    }

    static let typeExternal: UInt8 = 0x01
    static let typeAbsolute: UInt8 = 0x02
    static let typeIndirect: UInt8 = 0x0A
    static let typeSection: UInt8 = 0x0E

    var isExternal: Bool {
        type & 0x01 != 0
    }

    var isUndefined: Bool {
        type & 0x0E == 0
    }

    var isDefinedInSection: Bool {
        type & 0x0E == 0x0E
    }

    var isIndirect: Bool {
        type & 0x0E == 0x0A
    }

    var isWeakReference: Bool {
        desc & 0x40 != 0
    }

    var isWeakDefinition: Bool {
        desc & 0x80 != 0
    }
}

// MARK: - Kernel Collection

/// An MH_FILESET kernelcache: its segments, which resolve every address of
/// every entry, and its fileset entries.
struct KDKKernelCollection {
    struct Entry {
        let identifier: String
        let address: UInt64
        let fileOffset: UInt64
    }

    let bytes: KDKMachO.Bytes
    let header: KDKMachO.Header
    let commands: [KDKMachO.LoadCommand]
    let entries: [Entry]

    init(_ data: Data) throws {
        let data = data.startIndex == 0 ? data : Data(data)
        bytes = KDKMachO.Bytes(data: data)
        (header, commands) = try KDKMachO.loadCommands(in: bytes, at: 0)
        guard header.fileType == KDKMachO.mhFileset else {
            throw PatcherError.invalidFormat("the kernelcache is not an MH_FILESET kernel collection")
        }
        let collectionSize = data.count
        entries = try commands.filter { $0.command == KDKMachO.lcFilesetEntry }.map { load in
            let raw = load.bytes
            guard raw.count >= 32 else { throw PatcherError.invalidFormat("LC_FILESET_ENTRY of \(raw.count) bytes") }
            let nameOffset = Int(raw.le(UInt32.self, 24))
            guard nameOffset >= 32, nameOffset < raw.count else { throw PatcherError.invalidFormat("LC_FILESET_ENTRY names no entry") }
            guard raw.le(UInt64.self, 16) <= UInt64(collectionSize - KDKMachO.headerSize) else {
                throw PatcherError.invalidFormat("fileset entry header is outside the collection")
            }
            return Entry(
                identifier: KDKMachO.name(Array(raw[nameOffset...])),
                address: raw.le(UInt64.self, 8), fileOffset: raw.le(UInt64.self, 16)
            )
        }
    }

    var segments: [KDKMachO.Segment] {
        commands.compactMap(\.segment)
    }

    /// The collection's preferred load address, its __TEXT.
    var baseAddress: UInt64 {
        segments.first { $0.name == "__TEXT" }?.address ?? 0
    }

    /// The file offset of `address`, through the collection's segments.
    func offset(of address: UInt64) throws -> UInt64 {
        for segment in segments where segment.contains(address) {
            return segment.fileOffset + (address - segment.address)
        }
        throw PatcherError.invalidFormat("address 0x\(String(address, radix: 16)) is not in the kernelcache")
    }

    /// `count` bytes at `address`, read from the file as go-macho's address
    /// reader does: from the address's file offset onwards.
    func read(_ count: Int, at address: UInt64) throws -> [UInt8] {
        guard let offset = try Int(exactly: offset(of: address)) else {
            throw PatcherError.invalidFormat("kernelcache file offset exceeds host integer range")
        }
        return try bytes.bytes(offset, count)
    }

    /// The collection header's own LC_UNIXTHREAD.
    var unixThread: KDKMachO.LoadCommand? {
        let threads = commands.filter { $0.command == KDKMachO.lcUnixThread }
        return threads.count == 1 ? threads[0] : nil
    }

    func image(_ identifier: String) throws -> KDKImage {
        guard let entry = entries.first(where: { $0.identifier == identifier }) else {
            throw PatcherError.fileNotFound("fileset entry \(identifier) in the kernelcache")
        }
        return try KDKImage(entry: entry, in: self)
    }
}

/// A fileset entry: its header and load commands as the collection holds them,
/// with every offset in them relative to the collection.
struct KDKImage {
    let identifier: String
    var header: KDKMachO.Header
    var commands: [KDKMachO.LoadCommand]
    var symbols: [KDKSymbol]
    var indirectSymbols: [UInt32]

    init(entry: KDKKernelCollection.Entry, in collection: KDKKernelCollection) throws {
        identifier = entry.identifier
        (header, commands) = try KDKMachO.loadCommands(in: collection.bytes, at: Int(entry.fileOffset))
        if let symtab = commands.first(where: { $0.command == KDKMachO.lcSymtab }) {
            symbols = try KDKMachO.symbols(symtab.bytes, in: collection.bytes)
        } else {
            symbols = []
        }
        if let dysymtab = commands.first(where: { $0.command == KDKMachO.lcDysymtab }) {
            indirectSymbols = try KDKMachO.indirectSymbols(dysymtab.bytes, in: collection.bytes)
        } else {
            indirectSymbols = []
        }
    }

    var segments: [KDKMachO.Segment] {
        commands.compactMap(\.segment)
    }

    func command(_ command: UInt32) -> KDKMachO.LoadCommand? {
        commands.first { $0.command == command }
    }

    var isInCache: Bool {
        header.flags & KDKMachO.mhDylibInCache != 0
    }

    /// The image's preferred load address, its __TEXT.
    var baseAddress: UInt64 {
        segments.first { $0.name == "__TEXT" }?.address ?? 0
    }
}

// MARK: - Little-Endian Helpers

extension [UInt8] {
    func le<T: FixedWidthInteger>(_: T.Type, _ offset: Int) -> T {
        var value: T = 0
        for index in 0 ..< MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (8 * index)
        }
        return value
    }

    mutating func setLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        for index in 0 ..< MemoryLayout<T>.size {
            self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for index in 0 ..< MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }

    mutating func appendULEB128(_ value: UInt64) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            append(byte)
        } while value != 0
    }

    /// Zero bytes up to a multiple of `alignment`.
    mutating func pad(to alignment: Int) {
        let remainder = count % alignment
        if remainder != 0 {
            append(contentsOf: [UInt8](repeating: 0, count: alignment - remainder))
        }
    }
}
