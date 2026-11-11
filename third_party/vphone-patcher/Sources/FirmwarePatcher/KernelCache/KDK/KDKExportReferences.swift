// Reference relocation for the KDK writer. Kind values are dyld split-seg v2.
import Foundation
import VPhonePatchKit

extension KDKImageExport {
    func indirectSymbol(at address: UInt64) -> KDKSymbol? {
        guard let section = sections.first(where: { $0.contains(address) }), section.isSymbolPointers else { return nil }
        let entry = UInt64(section.reserved1) + (address - section.address) / 8
        guard entry < source.indirectSymbols.count else { return nil }
        let index = source.indirectSymbols[Int(entry)]
        guard index & KDKMachO.indirectSymbolLocal == 0, index < source.symbols.count else { return nil }
        return source.symbols[Int(index)]
    }

    mutating func adjustReferences() throws {
        var exactADRP: [UInt64: KDKReference] = [:]
        var pointerSymbols: [UInt64: KDKSymbol] = [:]
        var ambiguous = Set<UInt64>()
        var byAddress: [UInt64: KDKSymbol] = [:]
        var branches: [UInt64: KDKSymbol] = [:]
        for symbol in symbols where byAddress[symbol.value] == nil {
            byAddress[symbol.value] = symbol
        }
        for ref in references {
            if ref.kind == 6, ref.extra != 0,
               exactADRP[ref.extra].map({ ref.source < $0.source }) ?? true
            {
                exactADRP[ref.extra] = ref
            }
            if ref.kind == 2, !ambiguous.contains(ref.target), let address = try? remap(ref.source),
               let symbol = indirectSymbol(at: address)
            {
                if let old = pointerSymbols[ref.target], old.name != symbol.name {
                    pointerSymbols.removeValue(forKey: ref.target)
                    ambiguous.insert(ref.target)
                } else {
                    pointerSymbols[ref.target] = symbol
                }
            }
        }
        for ref in references {
            let address = try remap(ref.source)
            let off = try offset(address)
            try check(off, ref.kind == 2 || ref.kind == 4 ? 8 : 4)
            if ref.kind == 2 {
                let raw = data.le(UInt64.self, off)
                if raw >> 63 != 0 {
                    auths[address] = raw & 0x0007_FFFF_0000_0000
                }
            }
            let target = ref.kind == 5 ? exactADRP[ref.source]?.target ?? ref.target : ref.target
            var mapped = try? remap(target)
            if mapped == nil, ref.kind == 5 {
                let page = target & ~UInt64(0xFFF)
                if let m = mappings.first(where: { page <= $0.original.address + $0.original.memorySize && page + 0xFFF >= $0.original.address }) {
                    mapped = m.start & ~UInt64(0xFFF)
                }
            }
            if let mapped {
                if ref.kind == 7, let sym = pointerSymbols[target], sym.isWeakDefinition {
                    branches[address] = sym
                    continue
                }
                // The reference asks its VM reader for both offsets, including
                // pointer targets. Preserve that validation and BR26 behavior.
                let targetOff = try offset(mapped)
                let adjustment = (mapped &- target) &- (address &- ref.source)
                switch ref.kind {
                case 2:
                    if let sym = indirectSymbol(at: address), sym.isWeakDefinition {
                        binds[address] = sym
                    } else {
                        rebases[address] = mapped
                    }
                case 3:
                    others[address] = mapped
                    data.setLE(data.le(UInt32.self, off) &+ UInt32(truncatingIfNeeded: adjustment), at: off)
                case 4:
                    others[address] = mapped
                    data.setLE(data.le(UInt64.self, off) &+ adjustment, at: off)
                case 12:
                    others[address] = mapped
                    data.setLE(UInt32(truncatingIfNeeded: mapped &- segments.first(where: { $0.name == "__TEXT" })!.address), at: off)
                case 7:
                    others[address] = mapped
                    try writeBranch(at: off, delta: targetOff - off)
                case 5:
                    others[address] = mapped
                    let word = data.le(UInt32.self, off)
                    guard word & 0x9F00_0000 == 0x9000_0000 else { throw invalid("ADRP reference does not address ADRP") }
                    try write(ARM64Encoder.encodeADRP(rd: word & 31, pc: address, target: mapped), at: off)
                case 6:
                    others[address] = mapped
                    if ref.extra != 0, let chosen = exactADRP[ref.extra], let page = try? remap(chosen.target),
                       page & ~UInt64(0xFFF) != mapped & ~UInt64(0xFFF)
                    {
                        continue
                    }
                    let word = data.le(UInt32.self, off)
                    // Unknown OFF12 instruction forms are left intact by the
                    // reference writer, but still recorded in split-seg info.
                    if let encoded = ARM64Encoder.retargetPageOffset(word, offset: UInt32(mapped & 0xFFF)) {
                        try write(encoded, at: off)
                    }
                default: throw invalid("unsupported reference kind \(ref.kind)")
                }
            } else {
                var sym = indirectSymbol(at: address) ?? byAddress[target] ?? pointerSymbols[target]
                if sym == nil, auths[address] == nil, ref.kind == 2 {
                    var best: UInt64 = 256
                    for candidate in symbols where candidate.value != 0 && candidate.value <= target {
                        let delta = target - candidate.value
                        if delta < best {
                            sym = candidate
                            sym?.bindAddend = Int64(delta)
                            best = delta
                        }
                    }
                }
                guard let sym else { others[address] = target
                    continue
                }
                if ref.kind == 2 {
                    binds[address] = sym
                } else if ref.kind == 7 {
                    branches[address] = sym
                } else {
                    others[address] = target
                }
            }
        }
        if let got = section("__DATA_CONST", "__auth_got"), let stubs = section("__TEXT_EXEC", "__auth_stubs") {
            var slots: [String: UInt64] = [:]
            for (address, symbol) in binds where got.contains(address) {
                slots[symbol.name] = min(slots[symbol.name] ?? address, address)
            }
            for (address, symbol) in branches {
                guard let slot = slots[symbol.name] else { continue }
                let target = stubs.address + (slot - got.address) / 8 * 16
                try writeBranch(at: offset(address), delta: Int(truncatingIfNeeded: target &- address))
                others[address] = target
            }
        }
    }

    mutating func writeBranch(at off: Int, delta: Int) throws {
        try check(off, 4)
        let word = data.le(UInt32.self, off)
        guard word & 0x7C00_0000 == 0x1400_0000 else { throw invalid("BR26 reference does not address B/BL") }
        try write(word & 0x8000_0000 == 0 ? ARM64Encoder.encodeB(from: 0, to: delta) : ARM64Encoder.encodeBL(from: 0, to: delta), at: off)
    }

    func finalReferences() throws -> [KDKReference] {
        func inImage(_ address: UInt64) -> Bool {
            segments.contains { $0.name != "__LINKEDIT" && address >= $0.address && address - $0.address <= $0.memorySize }
        }
        struct Key: Hashable { var source: UInt64
            var kind: UInt8
        }
        var seen = Set<Key>()
        var result: [KDKReference] = []
        func add(_ kind: UInt8, _ source: UInt64, _ target: UInt64) {
            if seen.insert(Key(source: source, kind: kind)).inserted {
                result.append(KDKReference(kind: kind, source: source, target: target))
            }
        }
        for ref in references {
            let address = try remap(ref.source)
            switch ref.kind {
            case 2, 13:
                if binds[address] == nil, let target = rebases[address], inImage(target) {
                    add(auths[address] == nil ? 2 : 13, address, target)
                }
            case 6:
                guard var target = others[address], inImage(target) else { continue }
                let off = try offset(address)
                try check(off, 4)
                if let encoded = ARM64Encoder.decodePageOffset(data.le(UInt32.self, off)) {
                    var page = target & ~UInt64(0xFFF)
                    if ref.extra != 0, let adrp = try? remap(ref.extra), let t = others[adrp], inImage(t) {
                        page = t & ~UInt64(0xFFF)
                    }
                    target = page | UInt64(encoded)
                    if !inImage(target) {
                        continue
                    }
                }
                add(ref.kind, address, target)
            default:
                if let target = others[address], inImage(target) {
                    add(ref.kind, address, target)
                }
            }
        }
        if let got = section("__DATA_CONST", "__auth_got"), let stubs = section("__TEXT_EXEC", "__auth_stubs"), got.size > 0, stubs.size > 0 {
            for i in 0 ..< got.size / 8 where i * 16 + 8 <= stubs.size {
                add(5, stubs.address + i * 16, got.address + i * 8)
                add(6, stubs.address + i * 16 + 4, got.address + i * 8)
            }
        }
        return result
    }

    func splitLocation(_ address: UInt64, allowEnd: Bool) -> (Int, UInt64)? {
        let all = sections
        if let i = all.firstIndex(where: { $0.contains(address) }) {
            return (i + 1, address - all[i].address)
        }
        if allowEnd {
            if let i = all.firstIndex(where: { $0.size == 0 && address == $0.address }) {
                return (i + 1, 0)
            }
            if let i = all.firstIndex(where: { $0.size > 0 && address == $0.address + $0.size }) {
                return (i + 1, all[i].size)
            }
        }
        if let seg = segments.first(where: { $0.contains(address) }), seg.name == "__TEXT" {
            return (0, address - seg.address)
        }
        return nil
    }

    func splitInfo() throws -> [UInt8] {
        var groups: [Int: [UInt64: [UInt8: [UInt64]]]] = [:]
        for ref in try finalReferences() {
            guard let (from, fromOffset) = splitLocation(ref.source, allowEnd: false),
                  let (to, toOffset) = splitLocation(ref.target, allowEnd: true)
            else {
                throw invalid("split-info reference outside sections: \(ref)")
            }
            groups[from << 16 | to, default: [:]][toOffset, default: [:]][ref.kind, default: []].append(fromOffset)
        }
        var out: [UInt8] = [0x7F]
        out.appendULEB128(UInt64(groups.count))
        for combo in groups.keys.sorted() {
            let targets = groups[combo]!
            out.appendULEB128(UInt64(combo >> 16))
            out.appendULEB128(UInt64(combo & 0xFFFF))
            out.appendULEB128(UInt64(targets.count))
            var lastTarget: UInt64 = 0
            for target in targets.keys.sorted() {
                let kinds = targets[target]!
                out.appendULEB128(target - lastTarget)
                out.appendULEB128(UInt64(kinds.count))
                lastTarget = target
                for kind in kinds.keys.sorted() {
                    let offsets = kinds[kind]!.sorted()
                    out.appendULEB128(UInt64(kind))
                    out.appendULEB128(UInt64(offsets.count))
                    var previous: UInt64 = 0
                    for off in offsets {
                        out.appendULEB128(off - previous)
                        previous = off
                    }
                }
            }
        }
        out.append(0)
        out.pad(to: 8)
        return out
    }
}
