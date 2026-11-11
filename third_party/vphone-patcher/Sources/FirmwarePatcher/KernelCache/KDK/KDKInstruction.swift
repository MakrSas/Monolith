// Raw predicates used by reference dataflow recovery, matching the pinned
// arm64-cgo scanner. This is analysis only: all emitted instructions go through
// ARM64Encoder. ADRP/B/BL candidates are additionally decoded with Capstone.
import VPhonePatchKit

enum KDKInstruction {
    static func sign(_ value: UInt64, _ bits: Int) -> Int64 {
        Int64(bitPattern: value << (64 - bits)) >> (64 - bits)
    }

    static func adrp(_ word: UInt32, _ pc: UInt64) -> UInt64 {
        let imm = UInt64((word >> 29) & 3) | UInt64((word >> 5) & 0x7FFFF) << 2
        return (pc & ~UInt64(0xFFF)) &+ UInt64(bitPattern: sign(imm, 21) << 12)
    }

    static func branch(_ word: UInt32, _ pc: UInt64) -> UInt64? {
        let delta: Int64
        if ARM64Inst.isBorBL(word) {
            delta = sign(UInt64(word & 0x03FF_FFFF) << 2, 28)
        } else if word & 0xFF00_0010 == 0x5400_0000 || word & 0x7E00_0000 == 0x3400_0000 {
            delta = sign(UInt64((word >> 5) & 0x7FFFF) << 2, 21)
        } else if word & 0x7E00_0000 == 0x3600_0000 {
            delta = sign(UInt64((word >> 5) & 0x3FFF) << 2, 16)
        } else {
            return nil
        }
        return pc &+ UInt64(bitPattern: delta)
    }

    static func ret(_ w: UInt32) -> Bool {
        w & 0xFFFF_FC1F == 0xD65F_0000 || w == 0xD65F_0BFF || w == 0xD65F_0FFF
    }

    static func brk(_ w: UInt32) -> Bool {
        w & 0xFFE0_001F == 0xD420_0000
    }

    static func br(_ w: UInt32) -> Bool {
        w & 0xFFFF_FC1F == 0xD61F_0000
    }

    static func blr(_ w: UInt32) -> Bool {
        w & 0xFFFF_FC1F == 0xD63F_0000
    }

    static func b(_ w: UInt32) -> Bool {
        w & 0xFC00_0000 == 0x1400_0000
    }

    static func authJump(_ w: UInt32) -> Bool {
        w & 0xFEFF_F000 == 0xD61F_0000 && !br(w)
    }

    static func authCall(_ w: UInt32) -> Bool {
        w & 0xFEFF_F000 == 0xD63F_0000 && !blr(w)
    }

    static func linear(_ w: UInt32) -> Bool {
        branch(w, 0) == nil && !blr(w) && !br(w) && w & 0xFFFF_FC1F != 0xD65F_0000
    }

    static func add(_ w: UInt32) -> Bool {
        w & 0xFF00_0000 == 0x9100_0000 || w & 0xFF20_0000 == 0x8B00_0000
    }

    static func store(_ w: UInt32) -> Bool {
        w & 0xFFC0_0000 == 0xF800_0000 || w & 0xFFC0_0000 == 0xF900_0000
    }

    static func storePair(_ w: UInt32) -> Bool {
        w & 0xFE00_0000 == 0xA800_0000 && w & 0x0040_0000 == 0
    }

    static func writes(_ w: UInt32, _ register: UInt32) -> Bool {
        let rt = ARM64Inst.rd(w), rn = ARM64Inst.rn(w), rt2 = (w >> 10) & 31
        if w & 0x0A00_0000 == 0x0800_0000 {
            let simd = w & 0x0400_0000 != 0
            if w & 0x3A00_0000 == 0x2800_0000 {
                let load = w & 0x0040_0000 != 0, mode = (w >> 23) & 3
                return ((mode == 1 || mode == 3) && rn == register) || (load && !simd && (rt == register || rt2 == register))
            }
            if w & 0x3B00_0000 == 0x1800_0000 {
                return !simd && rt == register
            }
            if w & 0x3B00_0000 == 0x3900_0000 {
                return !simd && (w >> 22) & 3 != 0 && rt == register
            }
            if w & 0x3B20_0000 == 0x3800_0000 {
                let mode = (w >> 10) & 3
                return ((mode == 1 || mode == 3) && rn == register) || (!simd && (w >> 22) & 3 != 0 && rt == register)
            }
            if w & 0x3B20_0C00 == 0x3820_0800 {
                return !simd && (w >> 22) & 3 != 0 && rt == register
            }
            return rt == register || ARM64Inst.rm(w) == register
        }
        if w & 0x0E00_0000 == 0x0E00_0000 {
            if w & 0x5F20_FC00 == 0x1E20_0000 {
                return rt == register
            }
            if w & 0xBFE0_8400 == 0x0E00_0400 {
                let imm = (w >> 11) & 15
                return w & 0x2000_0000 == 0 && (imm == 5 || imm == 7) && rt == register
            }
            return false
        }
        return rt == register
    }
}
