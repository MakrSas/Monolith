// Reference recovery for stripped kernel collections. Port of ipsw#1372 at
// 7d81acd4b97e67c0a25b5ddc514ce2ad02e7d474; see LICENSE. No external tools.
import Foundation
import VPhonePatchKit

struct KDKFunction {
    var start: UInt64
    var end: UInt64
    func contains(_ address: UInt64) -> Bool {
        start <= address && address < end
    }
}

struct KDKCode {
    var section: KDKMachO.Section
    var bytes: [UInt8]
    func word(_ address: UInt64) -> UInt32? {
        guard address >= section.address, address - section.address < UInt64(bytes.count),
              bytes.count - Int(address - section.address) >= 4 else { return nil }
        return bytes.le(UInt32.self, Int(address - section.address))
    }
}

extension KDKImage {
    var sections: [KDKMachO.Section] {
        segments.flatMap(\.sections)
    }

    var codeSections: [KDKMachO.Section] {
        sections.filter { $0.size > 0 && !$0.name.contains("stubs") && $0.flags & 0x8000_0400 != 0 }
    }

    func functions(in collection: KDKKernelCollection) throws -> [KDKFunction] {
        guard let load = command(KDKMachO.lcFunctionStarts) else {
            throw PatcherError.invalidFormat("KDK recovery requires LC_FUNCTION_STARTS: \(identifier)")
        }
        var cursor = try KDKCursor(collection.bytes.bytes(Int(load.bytes.le(UInt32.self, 8)), Int(load.bytes.le(UInt32.self, 12))))
        guard !cursor.bytes.isEmpty else { return [] }
        var start = try baseAddress &+ (cursor.uleb())
        var result: [KDKFunction] = []
        while cursor.position < cursor.bytes.count {
            let delta = try cursor.uleb()
            if delta == 0 {
                break
            }
            result.append(.init(start: start, end: start &+ delta))
            start &+= delta
        }
        if let sec = sections.first(where: { $0.contains(start) }) {
            result.append(.init(start: start, end: sec.address + sec.size))
        }
        return result
    }
}

/// Bounded readers for metadata rather than unchecked Data subscripts.
struct KDKCursor {
    let bytes: [UInt8]
    var position = 0
    init(_ bytes: [UInt8], at position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard position >= 0, position <= bytes.count, size <= bytes.count - position else {
            throw PatcherError.invalidFormat("truncated KDK metadata at \(position)")
        }
        defer { position += size }
        return bytes.le(type, position)
    }

    mutating func uleb() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let byte = try read(UInt8.self)
            if shift == 63, byte > 1 {
                throw PatcherError.invalidFormat("KDK ULEB128 overflow")
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
        }
        throw PatcherError.invalidFormat("unterminated KDK ULEB128")
    }

    mutating func sleb() throws -> Int64 {
        var value: UInt64 = 0, shift = 0
        var byte: UInt8 = 0
        repeat {
            guard shift < 64 else { throw PatcherError.invalidFormat("KDK SLEB128 overflow") }
            byte = try read(UInt8.self)
            value |= UInt64(byte & 0x7F) << shift
            shift += 7
        } while byte & 0x80 != 0
        if shift < 64, byte & 0x40 != 0 {
            value |= ~UInt64(0) << shift
        }
        return Int64(bitPattern: value)
    }

    mutating func string() throws -> String {
        let start = position
        while try read(UInt8.self) != 0 {}
        return String(decoding: bytes[start ..< position - 1], as: UTF8.self)
    }
}

extension [UInt64] {
    func upperBound(_ address: UInt64) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] <= address {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

final class KDKRecovery {
    let collection: KDKKernelCollection
    var images: [String: KDKImage] = [:]
    var functions: [String: [KDKFunction]] = [:]
    var code: [String: [KDKCode]] = [:]
    var branchTargets = Set<UInt64>()
    var allCode: [KDKCode] = []
    var allCodeStarts: [UInt64] = []
    var allFunctions: [KDKFunction] = []
    var allFunctionStarts: [UInt64] = []
    var foreignReturns: [UInt64: Bool] = [:]
    let disassembler = ARM64Disassembler()

    init(_ collection: KDKKernelCollection) throws {
        self.collection = collection
        for entry in collection.entries {
            let image = try collection.image(entry.identifier)
            let funcs = try image.functions(in: collection)
            images[entry.identifier] = image
            functions[entry.identifier] = funcs
            allFunctions += funcs
            branchTargets.formUnion(funcs.map(\.start))
            branchTargets.formUnion(image.symbols.filter { !$0.isUndefined && $0.value != 0 }.map(\.value))
            code[entry.identifier] = try image.codeSections.map { try .init(section: $0, bytes: collection.read(Int($0.size), at: $0.address)) }
        }
        allCode = code.values.flatMap(\.self).sorted { $0.section.address < $1.section.address }
        allCodeStarts = allCode.map(\.section.address)
        allFunctions.sort { $0.start < $1.start }
        allFunctionStarts = allFunctions.map(\.start)
    }

    func recover() throws -> [String: [KDKReference]] {
        let pointers = try pointerReferences()
        var result: [String: [KDKReference]] = [:]
        for entry in collection.entries {
            let image = images[entry.identifier]!
            var refs = pointers[entry.identifier] ?? []
            refs += try metadataReferences(image)
            for section in code[entry.identifier] ?? [] {
                var adrps: [UInt64: UInt64] = [:]
                for off in stride(from: 0, to: section.bytes.count - 3, by: 4) {
                    let word = section.bytes.le(UInt32.self, off), pc = section.section.address + UInt64(off)
                    if ARM64Inst.isADRP(word) {
                        let target = KDKInstruction.adrp(word, pc)
                        if image.segments.contains(where: { (target & ~UInt64(0xFFF)) < $0.address + $0.memorySize && $0.address < (target & ~UInt64(0xFFF)) + 0x1000 }),
                           disassembler.disassembleOne(ARM64.encodeU32(word), at: pc)?.mnemonic == "adrp"
                        {
                            adrps[pc] = target
                            refs.append(.init(kind: 5, source: pc, target: target))
                        }
                    } else if ARM64Inst.isBorBL(word), let target = KDKInstruction.branch(word, pc) {
                        let owner = image.sections.first { $0.contains(target) }
                        if owner?.address == section.section.address {
                            continue
                        }
                        if !branchTargets.contains(target), (owner?.flags ?? 0) & 0x8000_0400 == 0 {
                            continue
                        }
                        if let decoded = disassembler.disassembleOne(ARM64.encodeU32(word), at: pc),
                           decoded.mnemonic == "b" || decoded.mnemonic == "bl"
                        {
                            refs.append(.init(kind: 7, source: pc, target: target))
                        }
                    }
                }
                refs += recoverOff12(image, section, adrps)
            }
            result[entry.identifier] = refs.sorted { ($0.source, $0.kind, $0.extra, $0.target) < ($1.source, $1.kind, $1.extra, $1.target) }
        }
        return result
    }

    func pointerReferences() throws -> [String: [KDKReference]] {
        guard let load = collection.commands.first(where: { $0.command == KDKMachO.lcDyldChainedFixups }) else { return [:] }
        let bytes = try KDKMachO.Bytes(data: Data(collection.bytes.bytes(Int(load.bytes.le(UInt32.self, 8)), Int(load.bytes.le(UInt32.self, 12)))))
        let start = try Int(bytes.u32(4)), count = try Int(bytes.u32(start))
        try bytes.check(start + 4, count * 4)
        let ranges = images.flatMap { id, image in image.sections.filter { $0.size > 0 }.map { (id, $0.address, $0.size) } }.sorted { $0.1 < $1.1 }
        let starts = ranges.map(\.1)
        var result: [String: [KDKReference]] = [:]
        for i in 0 ..< count {
            let relative = try Int(bytes.u32(start + 4 + i * 4))
            if relative == 0 {
                continue
            }
            let record = start + relative
            let pageSize = try UInt64(bytes.u16(record + 4)), format = try bytes.u16(record + 6)
            let segmentOffset = try bytes.u64(record + 8), pages = try Int(bytes.u16(record + 20))
            guard pageSize > 0, format == 8 || format == 7 else { throw PatcherError.invalidFormat("unsupported collection chain format \(format)") }
            let recordSize = try Int(bytes.u32(record))
            try bytes.check(record, recordSize)
            guard recordSize >= 22 + pages * 2 else { throw PatcherError.invalidFormat("truncated collection chain starts") }
            for page in 0 ..< pages {
                let first = try bytes.u16(record + 22 + page * 2)
                if first == 0xFFFF {
                    continue
                }
                var chains = [first]
                if first & 0x8000 != 0 {
                    chains = []
                    var index = Int(first & 0x7FFF)
                    while true {
                        guard 22 + index * 2 + 2 <= recordSize else { throw PatcherError.invalidFormat("bad multi-chain index") }
                        let value = try bytes.u16(record + 22 + index * 2)
                        chains.append(value & 0x7FFF)
                        index += 1
                        if value & 0x8000 != 0 {
                            break
                        }
                    }
                }
                for chain in chains {
                    let pageOffset = segmentOffset + UInt64(page) * pageSize
                    var offset = pageOffset + UInt64(chain)
                    while true {
                        guard offset >= pageOffset, offset - pageOffset < pageSize else { throw PatcherError.invalidFormat("collection fixup leaves its page") }
                        let raw = try collection.bytes.u64(Int(offset))
                        let source = collection.baseAddress + offset
                        let owner = starts.upperBound(source) - 1
                        if owner >= 0, source - ranges[owner].1 < ranges[owner].2 {
                            var target: UInt64?
                            if format == 8 {
                                target = raw & 0x3FFF_FFFF
                            } else if raw & (1 << 62) == 0 {
                                target = raw & (raw >> 63 == 1 ? 0xFFFF_FFFF : 0x7FF_FFFF_FFFF)
                            }
                            if let target {
                                result[ranges[owner].0, default: []].append(.init(kind: 2, source: source, target: collection.baseAddress &+ target))
                            }
                        }
                        let next = (raw >> 51) & (format == 8 ? 0xFFF : 0x7FF)
                        if next == 0 {
                            break
                        }
                        offset += next * 4
                    }
                }
            }
        }
        return result
    }
}
