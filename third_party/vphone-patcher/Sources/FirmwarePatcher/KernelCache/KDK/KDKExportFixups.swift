// ARM64E_KERNEL chained fixups: 4 KiB chain pages, 4-byte next stride.
import Foundation
import VPhonePatchKit

extension KDKImageExport {
    struct FixupPage: Hashable { var segment: Int
        var page: Int
    }

    /// Encode dyld's four ARM64e pointer layouts. PAC metadata occupies bits
    /// 32...50; plain rebases keep low43 + high8, binds carry signed19 addends.
    static func pointer(target: UInt64, ordinal: UInt16?, addend: Int64 = 0, auth: UInt64?, next: UInt64) throws -> UInt64 {
        guard next <= 0x7FF, addend >= -(1 << 18), addend < 1 << 18 else {
            throw PatcherError.invalidFormat("ARM64e chained pointer field overflow")
        }
        var word = next << 51
        if let auth {
            word |= 1 << 63 | (auth & 0x0007_FFFF_0000_0000)
            word |= ordinal.map(UInt64.init) ?? (target & 0xFFFF_FFFF)
        } else if let ordinal {
            word |= UInt64(ordinal) | ((UInt64(bitPattern: addend) & 0x7FFFF) << 32)
        } else {
            word |= target & 0x7FF_FFFF_FFFF
            word |= ((target >> 56) & 0xFF) << 43
        }
        if ordinal != nil {
            word |= 1 << 62
        }
        return word
    }

    func importOrder(_ fixups: [UInt64]) -> [UInt64] {
        let allSections = sections
        func sectionIndex(_ address: UInt64) -> Int? {
            allSections.firstIndex { $0.contains(address) }
        }
        var atoms: [Int: [UInt64]] = [:], vtables: [Int: [UInt64]] = [:]
        for symbol in source.symbols where symbol.isDefinedInSection && symbol.value != 0 {
            if let mapped = try? remap(symbol.value), let section = sectionIndex(mapped) {
                atoms[section, default: []].append(mapped)
                if symbol.name.hasPrefix("__ZTV") {
                    vtables[section, default: []].append(mapped)
                }
            }
        }
        if fixups.count > 1 {
            for i in 0 ..< fixups.count - 1 {
                let first = fixups[i], second = fixups[i + 1]
                guard let section = sectionIndex(first), section == sectionIndex(second) else { continue }
                if rebases[first] != nil, rebases[second] != nil, first + 8 == second,
                   let a = auths[first], let b = auths[second], (a >> 32) & 0xFFFF == 0x3771, (b >> 32) & 0xFFFF == 0x56B7
                {
                    atoms[section, default: []].append(first)
                }
                if second > first + 8, binds[first] != nil, auths[first] != nil,
                   binds[second] != nil, auths[second] == nil
                {
                    let starts = vtables[section, default: []].sorted()
                    if starts.contains(where: { $0 <= first }), !starts.contains(where: { $0 > first && $0 <= second }) {
                        atoms[section, default: []].append(second)
                    }
                }
            }
        }
        for index in atoms.keys {
            atoms[index]!.sort()
        }
        struct Order { var address: UInt64
            var section: UInt64
            var atom: UInt64
            var indirect: Bool
        }
        let orders = fixups.map { address -> Order in
            guard let index = sectionIndex(address) else { return Order(address: address, section: 0, atom: 0, indirect: false) }
            let s = allSections[index]
            return Order(address: address, section: s.address, atom: atoms[index]?.last(where: { $0 <= address }) ?? s.address, indirect: s.isSymbolPointers)
        }
        return orders.sorted { a, b in
            if a.section != b.section {
                return a.section < b.section
            }
            if a.indirect != b.indirect {
                return a.indirect
            }
            if a.indirect {
                return a.address < b.address
            }
            if a.atom != b.atom {
                return a.atom < b.atom
            }
            return a.address > b.address
        }.map(\.address)
    }

    mutating func chainedFixups() throws -> [UInt8] {
        let fixups = Set(binds.keys).union(rebases.keys).sorted()
        let weak = Set(source.symbols.filter { $0.isUndefined && $0.isWeakReference }.map(\.name))
        let weakDefs = Set(binds.values.filter(\.isWeakDefinition).map(\.name))
        var ordinals: [String: UInt16] = [:]
        var strings: [UInt8] = [0], imports: [UInt8] = []
        for address in importOrder(fixups) {
            guard let symbol = binds[address], ordinals[symbol.name] == nil else { continue }
            guard let ordinal = UInt16(exactly: ordinals.count), strings.count < 1 << 23 else { throw invalid("too many chained imports") }
            ordinals[symbol.name] = ordinal
            let flags: UInt32 = (weakDefs.contains(symbol.name) ? 0xFD : 0xFE) | (weak.contains(symbol.name) ? 0x100 : 0)
            imports.appendLE(flags | UInt32(strings.count) << 9)
            strings += symbol.name.utf8
            strings.append(0)
        }
        let segs = segments
        var pages: [FixupPage: [UInt64]] = [:]
        for address in fixups {
            guard let i = segs.firstIndex(where: { $0.contains(address) }) else { throw invalid("fixup outside segments") }
            pages[.init(segment: i, page: Int((address - segs[i].address) / 0x1000)), default: []].append(address)
        }
        var starts = [UInt8](repeating: 0, count: 4 + segs.count * 4)
        starts.setLE(UInt32(segs.count), at: 0)
        for (index, seg) in segs.enumerated() {
            guard let last = pages.keys.filter({ $0.segment == index }).map(\.page).max() else { continue }
            guard last < Int(UInt16.max) else { throw invalid("too many fixup pages") }
            var pageStarts: [UInt16] = [], overflow: [UInt16] = []
            for page in 0 ... last {
                let addresses = pages[.init(segment: index, page: page)] ?? []
                if addresses.isEmpty {
                    pageStarts.append(0xFFFF)
                    continue
                }
                var chains: [UInt16] = []
                for i in addresses.indices {
                    if i == 0 || (addresses[i] - addresses[i - 1]) % 4 != 0 || (addresses[i] - addresses[i - 1]) / 4 > 0x7FF {
                        chains.append(UInt16(addresses[i] - seg.address - UInt64(page) * 0x1000))
                    }
                    var next: UInt64 = 0
                    if i + 1 < addresses.count {
                        let delta = addresses[i + 1] - addresses[i]
                        if delta % 4 == 0, delta / 4 <= 0x7FF {
                            next = delta / 4
                        }
                    }
                    let address = addresses[i]
                    let symbol = binds[address]
                    let target = (rebases[address] ?? baseAddress) &- (segs.first { $0.name == "__TEXT" }?.address ?? 0)
                    let word = try Self.pointer(target: target, ordinal: symbol.flatMap { ordinals[$0.name] },
                                                addend: symbol?.bindAddend ?? 0, auth: auths[address], next: next)
                    let off = try offset(address)
                    try check(off, 8)
                    data.setLE(word, at: off)
                }
                if chains.count == 1 {
                    pageStarts.append(chains[0])
                } else {
                    guard overflow.count < 0x8000 else { throw invalid("too many chain starts") }
                    pageStarts.append(0x8000 | UInt16(overflow.count))
                    chains[chains.count - 1] |= 0x8000
                    overflow += chains
                }
            }
            starts.pad(to: 8)
            starts.setLE(UInt32(starts.count), at: 4 + index * 4)
            starts.appendLE(UInt32(22 + 2 * (pageStarts.count + overflow.count)))
            starts.appendLE(UInt16(0x1000))
            starts.appendLE(UInt16(7)) // ARM64E_KERNEL
            starts.appendLE(seg.address &- (segs.first { $0.name == "__TEXT" }?.address ?? 0))
            starts.appendLE(UInt32(0))
            starts.appendLE(UInt16(pageStarts.count))
            for start in pageStarts + overflow {
                starts.appendLE(start)
            }
        }
        let importsOffset = (32 + starts.count + 3) & ~3
        let stringsOffset = importsOffset + imports.count
        var out: [UInt8] = []
        for word: UInt32 in [0, 32, UInt32(importsOffset), UInt32(stringsOffset), UInt32(ordinals.count), 1, 0] {
            out.appendLE(word)
        }
        out.padTo(32)
        out += starts
        out.padTo(importsOffset)
        out += imports
        out += strings
        out.pad(to: 8)
        return out
    }
}
