import Foundation
import VPhonePatchKit

/// One shared baseline-A64 emulator, not a per-instruction trampoline pool.
enum VPhoneCSSCCode {
    struct Builder {
        var data = Data()
        var labels: [String: Int] = [:]
        var fixups: [(Int, String, UInt32?, UInt32?, Bool)] = []
        var valid = true

        mutating func emit(_ bytes: Data?) {
            guard let bytes else { valid = false; return }
            data += bytes
        }

        mutating func label(_ name: String) { labels[name] = data.count }
        mutating func branch(_ name: String, register: UInt32? = nil, bit: UInt32? = nil, nonzero: Bool = false) {
            fixups.append((data.count, name, register, bit, nonzero))
            emit(ARM64.nop)
        }

        mutating func equal(_ name: String) {
            emit(ARM64Encoder.encodeCsetW(rd: 13, condition: .eq))
            branch(name, register: 13, nonzero: true)
        }

        mutating func constant(_ register: UInt32, _ value: UInt32) {
            emit(ARM64Encoder.encodeMovzX(rd: register, imm16: UInt16(truncatingIfNeeded: value)))
            if value >> 16 != 0 {
                emit(ARM64Encoder.encodeMovkX(rd: register, imm16: UInt16(value >> 16), shift: 16))
            }
        }

        func finish() throws -> Data {
            guard valid else { throw PatcherError.invalidFormat("unencodable CSSC fallback") }
            var result = data
            for (offset, label, register, bit, nonzero) in fixups {
                guard let target = labels[label] else { throw PatcherError.invalidFormat("missing CSSC label \(label)") }
                let bytes: Data?
                if let register, let bit {
                    bytes = ARM64Encoder.encodeTestBitBranch(nonzero: nonzero, register: register, bit: bit, from: offset, to: target)
                } else if let register {
                    bytes = ARM64Encoder.encodeCompareBranch(nonzero: nonzero, register: register, from: offset, to: target, width64: true)
                } else {
                    bytes = ARM64Encoder.encodeB(from: offset, to: target)
                }
                guard let bytes else { throw PatcherError.invalidFormat("CSSC branch out of range") }
                result.replaceSubrange(offset..<offset + 4, with: bytes)
            }
            return result
        }
    }

    /// C ABI: bool emulate(uint32_t word, const uint64_t regs[31], uint64_t *result).
    /// Unknown words leave result untouched. Only caller-saved GPRs are used;
    /// no FP/SIMD, allocation, memory patching or privileged instructions.
    static func emulator() throws -> Data {
        var c = Builder()
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 14, rn: 0, lsb: 31, width: 1))
        // Rn; encoded register 31 is ZR, never SP or an out-of-bounds load.
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 3, rn: 0, lsb: 5, width: 5))
        loadRegister(&c, destination: 4, index: 3, name: "a")
        c.branch("a64", register: 14, nonzero: true)
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 4, rn: 4, lsb: 0, width: 32))
        c.label("a64")
        c.constant(12, 0x7FFF_FC00)
        c.emit(ARM64Encoder.encodeAndRegister(rd: 3, rn: 0, rm: 12, width64: false))
        for (word, label) in [(UInt32(0x5AC0_2000), "abs"), (0x5AC0_1C00, "cnt"), (0x5AC0_1800, "ctz")] {
            c.constant(12, word)
            c.emit(ARM64Encoder.encodeCompareRegister(rn: 3, rm: 12))
            c.equal(label)
        }
        c.constant(12, 0x7FE0_FC00)
        c.emit(ARM64Encoder.encodeAndRegister(rd: 3, rn: 0, rm: 12, width64: false))
        for kind in 0..<4 {
            c.constant(12, 0x1AC0_6000 + UInt32(kind) * 0x400)
            c.emit(ARM64Encoder.encodeCompareRegister(rn: 3, rm: 12))
            c.equal("reg\(kind)")
        }
        c.constant(12, 0x7FFC_0000)
        c.emit(ARM64Encoder.encodeAndRegister(rd: 3, rn: 0, rm: 12, width64: false))
        for kind in 0..<4 {
            c.constant(12, 0x11C0_0000 + UInt32(kind) * 0x40000)
            c.emit(ARM64Encoder.encodeCompareRegister(rn: 3, rm: 12))
            c.equal("imm\(kind)")
        }
        c.constant(0, 0)
        c.emit(ARM64.ret)

        for kind in 0..<4 {
            c.label("reg\(kind)")
            c.constant(15, UInt32(kind))
            c.branch("register")
            c.label("imm\(kind)")
            c.constant(15, UInt32(kind))
            c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 5, rn: 0, lsb: 10, width: 8, signed: kind & 1 == 0))
            c.branch("minmax")
        }
        c.label("register")
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 3, rn: 0, lsb: 16, width: 5))
        loadRegister(&c, destination: 5, index: 3, name: "b")
        c.label("minmax")
        c.branch("wide", register: 14, nonzero: true)
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 4, rn: 4, lsb: 0, width: 32))
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 5, rn: 5, lsb: 0, width: 32))
        c.branch("wide", register: 15, bit: 0, nonzero: true)
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 4, rn: 4, lsb: 0, width: 32, signed: true))
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 5, rn: 5, lsb: 0, width: 32, signed: true))
        c.label("wide")
        c.emit(ARM64Encoder.encodeCompareRegister(rn: 4, rm: 5))
        c.branch("unsigned", register: 15, bit: 0, nonzero: true)
        c.branch("signedMin", register: 15, bit: 1, nonzero: true)
        c.emit(ARM64Encoder.encodeConditionalSelect(rd: 4, rn: 4, rm: 5, condition: .ge))
        c.branch("done")
        c.label("signedMin")
        c.emit(ARM64Encoder.encodeConditionalSelect(rd: 4, rn: 4, rm: 5, condition: .lt))
        c.branch("done")
        c.label("unsigned")
        c.branch("unsignedMin", register: 15, bit: 1, nonzero: true)
        c.emit(ARM64Encoder.encodeConditionalSelect(rd: 4, rn: 4, rm: 5, condition: .hs))
        c.branch("done")
        c.label("unsignedMin")
        c.emit(ARM64Encoder.encodeConditionalSelect(rd: 4, rn: 4, rm: 5, condition: .lo))
        c.branch("done")

        c.label("abs")
        c.branch("abs64", register: 14, nonzero: true)
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 4, rn: 4, lsb: 0, width: 32, signed: true))
        c.label("abs64")
        c.emit(ARM64Encoder.encodeAddSubXShifted(subtract: true, rd: 5, rn: 31, rm: 4))
        c.emit(ARM64Encoder.encodeCompareRegister(rn: 4, rm: 31))
        c.emit(ARM64Encoder.encodeConditionalSelect(rd: 4, rn: 4, rm: 5, condition: .ge))
        c.branch("done")

        c.label("ctz")
        c.branch("ctz64", register: 14, nonzero: true)
        c.emit(ARM64Encoder.encodeReverseBits(rd: 4, rn: 4, width64: false))
        c.emit(ARM64Encoder.encodeCountLeadingZeros(rd: 4, rn: 4, width64: false))
        c.branch("done")
        c.label("ctz64")
        c.emit(ARM64Encoder.encodeReverseBits(rd: 4, rn: 4, width64: true))
        c.emit(ARM64Encoder.encodeCountLeadingZeros(rd: 4, rn: 4, width64: true))
        c.branch("done")

        c.label("cnt")
        c.constant(5, 0)
        c.label("bits")
        c.branch("counted", register: 4)
        c.emit(ARM64Encoder.encodeSubImm12(rd: 6, rn: 4, imm12: 1))
        c.emit(ARM64Encoder.encodeAndRegister(rd: 4, rn: 4, rm: 6))
        c.emit(ARM64Encoder.encodeAddImm12(rd: 5, rn: 5, imm12: 1))
        c.branch("bits")
        c.label("counted")
        c.emit(ARM64Encoder.encodeMovX(rd: 4, rm: 5))
        c.label("done")
        c.branch("result64", register: 14, nonzero: true)
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 4, rn: 4, lsb: 0, width: 32))
        c.label("result64")
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 4, rn: 2, offset: 0))
        c.constant(0, 1)
        c.emit(ARM64.ret)
        return try c.finish()
    }

    private static func loadRegister(_ c: inout Builder, destination: UInt32, index: UInt32, name: String) {
        c.emit(ARM64Encoder.encodeCmpWImmediate(rn: index, imm12: 31))
        c.equal("zero\(name)")
        c.emit(ARM64Encoder.encodeAddSubXShifted(subtract: false, rd: 6, rn: 1, rm: index, shift: 3))
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: destination, rn: 6, offset: 0))
        c.branch("loaded\(name)")
        c.label("zero\(name)")
        c.constant(destination, 0)
        c.label("loaded\(name)")
    }
}
