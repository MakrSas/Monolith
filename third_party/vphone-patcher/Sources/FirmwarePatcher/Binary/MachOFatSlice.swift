// MachOFatSlice.swift — take one architecture out of a universal Mach-O.
//
// watchOS ships its binaries for arm64_32 and arm64e in one file. The VM's
// kernel runs the arm64e slice, which is the one the patchers understand, so a
// watch binary is thinned to it before it is patched and signed.

import Foundation
import VPhonePatchKit

public enum MachOFatSlice {
    public static let arm64e = (cpuType: UInt32(0x0100_000C), cpuSubtype: UInt32(2))

    private static let fatMagic: UInt32 = 0xCAFE_BABE

    /// Whether `data` is a universal (32-bit fat header) Mach-O.
    public static func isFat(_ data: Data) -> Bool {
        data.count >= 8 && u32be(data, 0) == fatMagic
    }

    /// The slice for `cpuType`/`cpuSubtype` (capability bits ignored) of a
    /// universal Mach-O.
    public static func slice(
        _ data: Data,
        cpuType: UInt32 = arm64e.cpuType,
        cpuSubtype: UInt32 = arm64e.cpuSubtype,
    ) throws -> Data {
        guard isFat(data) else {
            throw PatcherError.invalidFormat("not a universal Mach-O")
        }
        let count = Int(u32be(data, 4))
        guard 8 + count * 20 <= data.count else {
            throw PatcherError.invalidFormat("fat header declares \(count) architectures it does not have")
        }
        for index in 0 ..< count {
            let entry = 8 + index * 20
            guard u32be(data, entry) == cpuType, u32be(data, entry + 4) & 0x00FF_FFFF == cpuSubtype else { continue }
            let offset = Int(u32be(data, entry + 8))
            let size = Int(u32be(data, entry + 12))
            guard offset + size <= data.count else {
                throw PatcherError.invalidFormat("fat slice \(index) is out of bounds")
            }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size)
        }
        throw PatcherError.invalidFormat("no slice for CPU type 0x\(String(cpuType, radix: 16)) subtype \(cpuSubtype)")
    }

    private static func u32be(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start ..< start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
