// LINKEDIT reconstruction in File.Export order, including its symbol/string
// ordering and indirect-symbol fallback for stripped collections.
import Foundation
import VPhonePatchKit

extension KDKImageExport {
    struct SymbolTable {
        var entries: [KDKSymbol]
        var locals: UInt32
        var external: UInt32
        var undefined: UInt32
        var bytes: [UInt8]
        var strings: [UInt8]
        var indexMap: [Int]
    }

    func symbolTable() throws -> SymbolTable {
        struct Entry { var symbol: KDKSymbol
            var original: Int
            var nameOffset: UInt32 = 0
            var indirectOffset: UInt64 = 0
        }
        let imports = Set(source.symbols.filter(\.isUndefined).map(\.name))
        var groups = [[Entry](), [Entry](), [Entry]()]
        func add(_ original: KDKSymbol, index: Int) throws {
            var s = original
            if s.isDefinedInSection, s.value != 0 {
                s.value = try remap(s.value)
            }
            if index == -1, s.isUndefined {
                s.value = 0
            }
            let group = !s.isExternal ? 0 : (s.isUndefined ? 2 : 1)
            groups[group].append(Entry(symbol: s, original: index))
        }
        for symbol in symbols where !(symbol.isExternal && imports.contains(symbol.name)) {
            try add(symbol, index: -1)
        }
        for (index, symbol) in source.symbols.enumerated() where symbol.name != "<redacted>" {
            try add(symbol, index: index)
        }
        var strings = [UInt8](repeating: 0, count: 4)
        for g in [1, 2, 0] {
            for i in groups[g].indices {
                let s = groups[g][i].symbol
                if !s.name.isEmpty {
                    groups[g][i].nameOffset = UInt32(strings.count)
                    strings += s.name.utf8
                    strings.append(0)
                }
                if s.isIndirect, !s.indirectName.isEmpty {
                    groups[g][i].indirectOffset = UInt64(strings.count)
                    strings += s.indirectName.utf8
                    strings.append(0)
                }
            }
        }
        strings.pad(to: 8)
        var bytes: [UInt8] = [], map = [Int](repeating: -1, count: source.symbols.count)
        let entries = groups.flatMap(\.self)
        for (index, entry) in entries.enumerated() {
            let s = entry.symbol
            bytes.appendLE(entry.nameOffset)
            bytes.append(s.type)
            bytes.append(s.sect)
            bytes.appendLE(s.desc)
            bytes.appendLE(s.isIndirect ? entry.indirectOffset : s.value)
            if entry.original >= 0 {
                map[entry.original] = index
            }
        }
        return SymbolTable(entries: entries.map(\.symbol), locals: UInt32(groups[0].count), external: UInt32(groups[1].count),
                           undefined: UInt32(groups[2].count), bytes: bytes, strings: strings, indexMap: map)
    }

    func indirectTable(_ table: SymbolTable) -> [UInt8] {
        var undefined: [String: UInt32] = [:]
        for (i, symbol) in table.entries.enumerated() where symbol.isUndefined {
            undefined[symbol.name] = UInt32(i)
        }
        let got = section("__DATA_CONST", "__auth_got")
        func fallback(_ entry: Int) -> UInt32? {
            for section in sections {
                let start = UInt64(section.reserved1), index = UInt64(entry)
                var slot: UInt64
                if section.isSymbolPointers {
                    guard index >= start, index - start < section.size / 8 else { continue }
                    slot = section.address + (index - start) * 8
                } else if section.name == "__auth_stubs", let got {
                    guard index >= start, index - start < section.size / 16 else { continue }
                    slot = got.address + (index - start) * 8
                } else {
                    continue
                }
                return binds[slot].flatMap { undefined[$0.name] }
            }
            return nil
        }
        var out: [UInt8] = []
        for (entry, index) in source.indirectSymbols.enumerated() {
            if index & (KDKMachO.indirectSymbolLocal | KDKMachO.indirectSymbolAbsolute) != 0 {
                out.appendLE(index)
            } else if index < table.indexMap.count, table.indexMap[Int(index)] >= 0 {
                out.appendLE(UInt32(table.indexMap[Int(index)]))
            } else {
                out.appendLE(fallback(entry) ?? KDKMachO.indirectSymbolLocal)
            }
        }
        return out
    }

    func functionStarts() throws -> [UInt8]? {
        guard let cmd = source.command(KDKMachO.lcFunctionStarts) else { return nil }
        let bytes = try collection.bytes.bytes(Int(cmd.bytes.le(UInt32.self, 8)), Int(cmd.bytes.le(UInt32.self, 12)))
        var cursor = 0, address = source.baseAddress
        var starts: [UInt64] = []
        while cursor < bytes.count {
            var delta: UInt64 = 0, shift = 0
            var complete = false
            while cursor < bytes.count, shift < 64 {
                let byte = bytes[cursor]
                cursor += 1
                delta |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
            }
            if !complete || delta == 0 {
                break
            }
            address &+= delta
            try starts.append(remap(address))
        }
        var out: [UInt8] = []
        var previous = segments.first { $0.name == "__TEXT" }?.address ?? 0
        for start in Set(starts).sorted() {
            out.appendULEB128(start &- previous)
            previous = start
        }
        out.append(0)
        out.pad(to: 8)
        return out
    }

    mutating func rebuildLinkedit() throws {
        guard let leIndex = commands.firstIndex(where: { $0.segment?.name == "__LINKEDIT" }),
              let linkedit = commands[leIndex].segment,
              let symIndex = commands.firstIndex(where: { $0.command == KDKMachO.lcSymtab }),
              let dysymIndex = commands.firstIndex(where: { $0.command == KDKMachO.lcDysymtab })
        else {
            throw invalid("export requires LINKEDIT, SYMTAB and DYSYMTAB")
        }
        // These are DSC/general dylib features, not the stripped kernelcache
        // contract. Reject them before discarding any original LINKEDIT data.
        for command in commands where [KDKMachO.lcDyldExportsTrie, KDKMachO.lcCodeSignature,
                                       KDKMachO.lcDylibCodeSignDRs, KDKMachO.lcLinkerOptimizationHint].contains(command.command)
        {
            if command.bytes.le(UInt32.self, 12) != 0 {
                throw invalid("unsupported nonempty load command 0x\(String(command.command, radix: 16))")
            }
        }
        var link: [UInt8] = []
        func store(_ bytes: [UInt8], command: UInt32) {
            guard let index = commands.firstIndex(where: { $0.command == command }) else { return }
            commands[index].bytes.setLE(UInt32(linkedit.fileOffset) + UInt32(link.count), at: 8)
            commands[index].bytes.setLE(UInt32(bytes.count), at: 12)
            link += bytes
            link.pad(to: 8)
        }
        if packed {
            try store(chainedFixups(), command: KDKMachO.lcDyldChainedFixups)
        }
        for command in [KDKMachO.lcDyldExportsTrie, KDKMachO.lcDataInCode] {
            if let load = commands.first(where: { $0.command == command }) {
                let off = Int(load.bytes.le(UInt32.self, 8)), size = Int(load.bytes.le(UInt32.self, 12))
                try check(off, size)
                store(Array(data[off ..< off + size]), command: command)
            }
        }
        if packed {
            try store(splitInfo(), command: KDKMachO.lcSegmentSplitInfo)
        }
        if let starts = try functionStarts() {
            store(starts, command: KDKMachO.lcFunctionStarts)
        }
        for command in [KDKMachO.lcFunctionVariants, KDKMachO.lcFunctionVariantFixups] {
            if let load = commands.first(where: { $0.command == command }) {
                let off = Int(load.bytes.le(UInt32.self, 8)), size = Int(load.bytes.le(UInt32.self, 12))
                try check(off, size)
                store(Array(data[off ..< off + size]), command: command)
            }
        }
        if let i = commands.firstIndex(where: { $0.command == KDKMachO.lcDyldInfo || $0.command == KDKMachO.lcDyldInfoOnly }) {
            var payload: [UInt8] = []
            for field in stride(from: 8, through: 40, by: 8) {
                let off = Int(commands[i].bytes.le(UInt32.self, field)), size = Int(commands[i].bytes.le(UInt32.self, field + 4))
                if size > 0 {
                    try check(off, size)
                    commands[i].bytes.setLE(UInt32(linkedit.fileOffset) + UInt32(link.count + payload.count), at: field)
                    payload += data[off ..< off + size]
                }
            }
            link += payload
            link.pad(to: 8)
        }
        let table = try symbolTable()
        let symOffset = UInt32(linkedit.fileOffset) + UInt32(link.count)
        link += table.bytes
        link.pad(to: 8)
        let indirectOffset = UInt32(linkedit.fileOffset) + UInt32(link.count)
        link += indirectTable(table)
        link.pad(to: 8)
        let stringOffset = UInt32(linkedit.fileOffset) + UInt32(link.count)
        link += table.strings
        link.pad(to: 8)
        for (off, value) in [(8, symOffset), (12, UInt32(table.entries.count)), (16, stringOffset), (20, UInt32(table.strings.count))] {
            commands[symIndex].bytes.setLE(value, at: off)
        }
        for (off, value): (Int, UInt32) in [(8, 0), (12, table.locals), (16, table.locals), (20, table.external),
                                            (24, table.locals + table.external), (28, table.undefined),
                                            (56, indirectOffset), (60, UInt32(source.indirectSymbols.count)),
                                            (64, 0), (68, 0), (72, 0), (76, 0)]
        {
            commands[dysymIndex].bytes.setLE(value, at: off)
        }
        // File.Export updates the in-memory empty DATA_IN_CODE offset after
        // writing its command; its serialized value stays at the earlier blob.
        commands[leIndex].segment?.fileSize = UInt64(link.count)
        commands[leIndex].segment?.memorySize = Self.aligned(UInt64(link.count))
        let start = Int(linkedit.fileOffset)
        data.padTo(start)
        data.replaceSubrange(start ..< data.count, with: link)
        var loadBytes: [UInt8] = []
        writeCommands(to: &loadBytes)
        try check(KDKMachO.headerSize, loadBytes.count)
        data.replaceSubrange(KDKMachO.headerSize ..< KDKMachO.headerSize + loadBytes.count, with: loadBytes)
    }
}
