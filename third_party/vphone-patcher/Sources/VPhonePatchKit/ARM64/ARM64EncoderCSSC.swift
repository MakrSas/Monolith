import Foundation

// Baseline A64 instructions used by the kernel CSSC fallback. Expected words
// are checked against Keystone 0.9.2 in KernelCSSCTests; no CSSC is emitted.
public extension ARM64Encoder {
    static func encodeBitfieldExtract(rd: UInt32, rn: UInt32, lsb: UInt32, width: UInt32, signed: Bool = false) -> Data? {
        guard rd < 32, rn < 32, width > 0, lsb < 64, width <= 64 - lsb else { return nil }
        return ARM64.encodeU32((signed ? 0x9340_0000 : 0xD340_0000)
            | (lsb << 16) | ((lsb + width - 1) << 10) | (rn << 5) | rd)
    }

    static func encodeAndRegister(rd: UInt32, rn: UInt32, rm: UInt32, width64: Bool = true) -> Data? {
        guard rd < 32, rn < 32, rm < 32 else { return nil }
        return ARM64.encodeU32((width64 ? 0x8A00_0000 : 0x0A00_0000) | (rm << 16) | (rn << 5) | rd)
    }

    static func encodeCompareRegister(rn: UInt32, rm: UInt32, width64: Bool = true) -> Data? {
        guard rn < 32, rm < 32 else { return nil }
        return ARM64.encodeU32((width64 ? 0xEB00_001F : 0x6B00_001F) | (rm << 16) | (rn << 5))
    }

    static func encodeConditionalSelect(rd: UInt32, rn: UInt32, rm: UInt32, condition: ARM64Condition) -> Data? {
        guard rd < 32, rn < 32, rm < 32 else { return nil }
        return ARM64.encodeU32(0x9A80_0000 | (rm << 16) | (condition.rawValue << 12) | (rn << 5) | rd)
    }

    static func encodeReverseBits(rd: UInt32, rn: UInt32, width64: Bool) -> Data? {
        guard rd < 32, rn < 32 else { return nil }
        return ARM64.encodeU32((width64 ? 0xDAC0_0000 : 0x5AC0_0000) | (rn << 5) | rd)
    }

    static func encodeCountLeadingZeros(rd: UInt32, rn: UInt32, width64: Bool) -> Data? {
        guard rd < 32, rn < 32 else { return nil }
        return ARM64.encodeU32((width64 ? 0xDAC0_1000 : 0x5AC0_1000) | (rn << 5) | rd)
    }

    static func encodeReadStatus(rt: UInt32) -> Data? {
        guard rt < 31 else { return nil }
        return ARM64.encodeU32(0xD53B_4200 | rt)
    }

    static func encodeWriteStatus(rt: UInt32) -> Data? {
        guard rt < 31 else { return nil }
        return ARM64.encodeU32(0xD51B_4200 | rt)
    }

    static func encodeSelectStackPointer(interruptStack: Bool) -> Data {
        ARM64.encodeU32(interruptStack ? 0xD500_41BF : 0xD500_40BF)
    }
}
