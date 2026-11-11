// KernelCustomFirmwarePatchTproOff.swift — optional Frida spawn support.
//
// Declared as `kernel-exp-frida_tpro_off`, off in `standard`.
//
// Every libdyld API entry asserts that the thread's TPRO pages are read-only and
// otherwise aborts with "TPRO regions should not be writable on entry to dyld".
// Frida's spawn handshake re-enters dyld while dyld's own TPRO window is open,
// so a spawned (or spawn-gated and resumed) app aborts. Clearing the kernel's
// `_xprr_tpro_enabled` takes the no-TPRO path the kernel already has for
// processes without TPRO. Ported from mowisec/frida_patches_srd (`tpro-off`).
// Reveal + validation: Research/KernelCustomFirmwarePatches/patch_tpro_off.md.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    @discardableResult
    func patchTproOff() -> Bool {
        log("\n[FRIDA] tpro: clear _xprr_tpro_enabled")

        let sites = findTproRegionFlagGuards()
        guard sites.count == 1, let site = sites.first else {
            log("  [-] expected one VM_REGION_FLAG_TPRO_ENABLED guard, found \(sites.count); failing closed")
            return false
        }
        guard let flagOff = vaToFileOffset(site.flagVA) else {
            log("  [-] _xprr_tpro_enabled VA 0x\(String(site.flagVA, radix: 16)) has no file offset")
            return false
        }
        let inDataConst = segments.contains { seg in
            seg.name == "__DATA_CONST" && seg.fileSize > 0
                && Int(seg.fileOffset) <= flagOff && flagOff + 4 <= Int(seg.fileOffset + seg.fileSize)
        }
        guard inDataConst else {
            log("  [-] _xprr_tpro_enabled resolved outside __DATA_CONST (foff 0x\(String(flagOff, radix: 16)))")
            return false
        }
        let value = buffer.readU32(at: flagOff)
        guard value == 1 else {
            log("  [-] _xprr_tpro_enabled holds \(value), expected 1")
            return false
        }

        emit(
            flagOff,
            Data([0, 0, 0, 0]),
            patchID: "kernel-exp-frida_tpro_off",
            virtualAddress: site.flagVA,
            description: "zero [_xprr_tpro_enabled] (guard at 0x\(String(site.guardOff, radix: 16)), frida)",
        )
        return true
    }

    // MARK: - Semantic matcher

    /// The one TPRO read that gates the VM_REGION_FLAG_TPRO_ENABLED store:
    ///
    ///     adrp xA, page
    ///     ldr  wA, [xA, #off]          ; _xprr_tpro_enabled
    ///     cbz  wA, skip
    ///     ldr  wB, [xM, #imm]
    ///     cmp  wB, wC
    ///     b.lo skip
    ///     ldrh wF, [xN, #flags]
    ///     orr  wF, wF, #2              ; VM_REGION_FLAG_TPRO_ENABLED
    ///     strh wF, [xN, #flags]
    private func findTproRegionFlagGuards() -> [(guardOff: Int, flagVA: UInt64)] {
        var hits: [(Int, UInt64)] = []
        for range in codeRanges {
            var off = range.start + 7 * 4
            while off + 8 <= min(range.end, buffer.count) {
                defer { off += 4 }
                // Rejection-only gate: `orr wD, wN, #2`. Everything that decides
                // the match is checked on Capstone's decode below.
                guard buffer.readU32(at: off) & 0xFFFF_FC00 == 0x321F_0000 else { continue }
                let start = off - 7 * 4
                guard let va = fileOffsetToVA(start) else { continue }
                let w = disasm.disassemble(in: buffer.data, at: start, count: 9, address: va)
                guard w.count == 9, let flagVA = tproGuardFlagVA(w) else { continue }
                hits.append((start, flagVA))
            }
        }
        return hits
    }

    private func tproGuardFlagVA(_ w: [ARM64Instruction]) -> UInt64? {
        func ops(_ i: Int) -> [ARM64Operand] { w[i].detail?.operands ?? [] }

        guard w[0].mnemonic == "adrp", ops(0).count == 2, ops(0)[0].type == .register,
              ops(0)[1].type == .immediate
        else { return nil }
        let pageReg = ops(0)[0].reg

        // ldr wA, [xA, #off] — the flag load, from the ADRP's page.
        guard w[1].mnemonic == "ldr", ops(1).count == 2, ops(1)[0].type == .register,
              ops(1)[0].reg.name?.hasPrefix("w") == true,
              ops(1)[1].type == .memory, ops(1)[1].mem.base == pageReg, ops(1)[1].mem.index == .invalid
        else { return nil }
        let flagReg = ops(1)[0].reg

        // cbz wA, skip — and b.lo to the same skip.
        guard w[2].mnemonic == "cbz", ops(2).count == 2, ops(2)[0].reg == flagReg,
              ops(2)[1].type == .immediate,
              w[3].mnemonic == "ldr", w[4].mnemonic == "cmp",
              w[5].mnemonic == "b.lo", ops(5).first?.type == .immediate,
              ops(5)[0].imm == ops(2)[1].imm
        else { return nil }

        // ldrh wF, [xN, #flags] ; orr wF, wF, #2 ; strh wF, [xN, #flags]
        guard w[6].mnemonic == "ldrh", ops(6).count == 2, ops(6)[1].type == .memory,
              w[7].mnemonic == "orr", ops(7).count == 3,
              ops(7)[0].reg == ops(6)[0].reg, ops(7)[1].reg == ops(6)[0].reg,
              ops(7)[2].type == .immediate, ops(7)[2].imm == 2,
              w[8].mnemonic == "strh", ops(8).count == 2, ops(8)[0].reg == ops(6)[0].reg,
              ops(8)[1].type == .memory, ops(8)[1].mem == ops(6)[1].mem
        else { return nil }

        return UInt64(bitPattern: ops(0)[1].imm) &+ UInt64(bitPattern: Int64(ops(1)[1].mem.disp))
    }
}
