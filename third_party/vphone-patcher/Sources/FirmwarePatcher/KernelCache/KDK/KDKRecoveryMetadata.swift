import Foundation
import VPhonePatchKit

extension KDKRecovery {
    func metadataReferences(_ image: KDKImage) throws -> [KDKReference] {
        var result: [KDKReference] = []
        for section in image.sections {
            if section.segmentName == "__BOOTDATA", section.name == "__static_if" {
                let bytes = try collection.read(Int(section.size), at: section.address)
                for off in stride(from: 0, to: max(0, bytes.count - 3), by: 16) {
                    let source = section.address + UInt64(off)
                    let delta = Int64(bytes.le(Int32.self, off))
                    result.append(.init(kind: 3, source: source, target: source &+ UInt64(bitPattern: delta)))
                }
            } else if section.segmentName == "__TEXT", section.name == "__copyio_vectors" {
                let bytes = try collection.read(Int(section.size), at: section.address)
                for off in stride(from: 0, to: max(0, bytes.count - 7), by: 8) {
                    result.append(.init(kind: 4, source: section.address + UInt64(off), target: section.address &+ bytes.le(UInt64.self, off)))
                }
            } else if section.segmentName == "__TEXT", section.name == "__unwind_info" {
                let bytes = try KDKMachO.Bytes(data: Data(collection.read(Int(section.size), at: section.address)))
                try bytes.check(0, 28)
                let personality = try Int(bytes.u32(12)), personalityCount = try Int(bytes.u32(16))
                for i in 0 ..< personalityCount {
                    let off = personality + i * 4
                    try result.append(.init(kind: 12, source: section.address + UInt64(off), target: image.baseAddress + UInt64(bytes.u32(off))))
                }
                let index = try Int(bytes.u32(20)), count = try Int(bytes.u32(24))
                var firstLSDA = 0, lastLSDA = 0
                for i in 0 ..< count {
                    let off = index + i * 12
                    let target = try image.baseAddress + UInt64(bytes.u32(off)) + (i == count - 1 ? 1 : 0)
                    result.append(.init(kind: 12, source: section.address + UInt64(off), target: target))
                    lastLSDA = try Int(bytes.u32(off + 8))
                    if i == 0 {
                        firstLSDA = lastLSDA
                    }
                }
                for off in stride(from: firstLSDA, to: lastLSDA, by: 4) {
                    try result.append(.init(kind: 12, source: section.address + UInt64(off), target: image.baseAddress + UInt64(bytes.u32(off))))
                }
            } else if section.segmentName == "__TEXT", section.name == "__eh_frame" {
                result += try ehFrameReferences(collection.read(Int(section.size), at: section.address), address: section.address)
            }
        }
        return result
    }

    /// Only CIE encodings and FDE initial locations are required, not CFI
    /// execution. Respect the CIE's pointer encoding instead of assuming sdata8.
    func ehFrameReferences(_ bytes: [UInt8], address: UInt64) throws -> [KDKReference] {
        var cursor = KDKCursor(bytes)
        var encodings: [Int: UInt8] = [:]
        var result: [KDKReference] = []
        while cursor.position < bytes.count {
            let start = cursor.position
            let length = try cursor.read(UInt32.self)
            if length == 0 {
                break
            }
            guard length != UInt32.max else { throw PatcherError.invalidFormat("DWARF64 EH frame not supported by kernel export") }
            let end = cursor.position + Int(length)
            guard end <= bytes.count else { throw PatcherError.invalidFormat("truncated EH frame") }
            let idOffset = cursor.position
            let id = try cursor.read(UInt32.self)
            if id == 0 {
                let version = try cursor.read(UInt8.self), augmentation = try cursor.string()
                if version >= 4 {
                    guard try cursor.read(UInt8.self) == 8, try cursor.read(UInt8.self) == 0 else { throw PatcherError.invalidFormat("unsupported EH address size") }
                }
                _ = try cursor.uleb()
                _ = try cursor.sleb()
                if version == 1 {
                    _ = try cursor.read(UInt8.self)
                } else {
                    _ = try cursor.uleb()
                }
                var encoding: UInt8 = 0
                if !augmentation.isEmpty {
                    guard augmentation.first == "z" else { throw PatcherError.invalidFormat("unsupported EH augmentation") }
                    let size = try Int(cursor.uleb()), augEnd = cursor.position + size
                    guard augEnd <= end else { throw PatcherError.invalidFormat("truncated EH augmentation") }
                    for character in augmentation.dropFirst() {
                        switch character {
                        case "L": _ = try cursor.read(UInt8.self)
                        case "P":
                            let enc = try cursor.read(UInt8.self)
                            _ = try encodedPointer(&cursor, encoding: enc, address: address)
                        case "R": encoding = try cursor.read(UInt8.self)
                        case "S", "B", "G": break
                        default: throw PatcherError.invalidFormat("unsupported EH augmentation \(character)")
                        }
                    }
                    guard cursor.position == augEnd else { throw PatcherError.invalidFormat("EH augmentation size mismatch") }
                }
                encodings[start] = encoding
            } else {
                let cie = idOffset - Int(id)
                guard let encoding = encodings[cie] else { throw PatcherError.invalidFormat("missing EH CIE") }
                let initial = try encodedPointer(&cursor, encoding: encoding, address: address)
                result.append(.init(kind: 3, source: address + UInt64(start + 4), target: address + UInt64(cie)))
                // Preserve the reference writer's ld64 split-info kind. Source
                // locations are 64-bit on the supported arm64 collection corpus.
                result.append(.init(kind: 4, source: address + UInt64(start + 8), target: initial))
            }
            guard cursor.position <= end else { throw PatcherError.invalidFormat("EH fields exceed entry") }
            cursor.position = end
        }
        return result
    }

    func encodedPointer(_ cursor: inout KDKCursor, encoding: UInt8, address: UInt64) throws -> UInt64 {
        let field = address + UInt64(cursor.position)
        let value: UInt64
        switch encoding & 0xF {
        case 0, 4: value = try cursor.read(UInt64.self)
        case 1: value = try cursor.uleb()
        case 2: value = try UInt64(cursor.read(UInt16.self))
        case 3: value = try UInt64(cursor.read(UInt32.self))
        case 9: value = try UInt64(bitPattern: cursor.sleb())
        case 10: value = try UInt64(bitPattern: Int64(cursor.read(Int16.self)))
        case 11: value = try UInt64(bitPattern: Int64(cursor.read(Int32.self)))
        case 12: value = try cursor.read(UInt64.self)
        default: throw PatcherError.invalidFormat("unsupported EH pointer encoding \(encoding)")
        }
        switch encoding & 0x70 {
        case 0: return value
        case 0x10: return field &+ value
        default: throw PatcherError.invalidFormat("unsupported EH relative pointer encoding \(encoding)")
        }
    }
}
