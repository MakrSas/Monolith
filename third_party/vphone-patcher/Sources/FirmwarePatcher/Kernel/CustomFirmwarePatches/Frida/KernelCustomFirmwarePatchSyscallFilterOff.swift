// KernelCustomFirmwarePatchSyscallFilterOff.swift — optional Frida support in
// syscall-filtered processes.
//
// Declared as `kernel-exp-frida_syscall_filter_off`, off in `standard`.
//
// Sandbox profiles can carry per-process syscall filters (`syscall-unix`,
// `syscall-mach`, `syscall-mig`), installed as bitmasks the kernel tests inline.
// Frida's agent runs inside the target, so its own calls are judged against the
// target's masks: in trustd, apsd, cfprefsd, backboardd or runningboardd the
// agent is denied kqueue, thread_get_state and MIG routines it needs, and the
// injection dies (`Autobox: trustd deny(1) syscall-mig 153`). The masks get past
// `kernel-boot-syscallmask` on these processes, so this patch works at the other
// end: the two mask accessors report "no filter" (NULL, the state of an
// unfiltered task) and the MACF BSD syscall check allows. The rest of the
// sandbox is untouched. Ported from mowisec/frida_patches_srd
// (`syscall-filter-off`).
// Reveal + validation: Research/KernelCustomFirmwarePatches/patch_syscall_filter_off.md.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    @discardableResult
    func patchSyscallFilterOff() -> Bool {
        log("\n[FRIDA] syscall filters: report no filter mask, allow the MACF unix check")

        // _task_get_mach_kobj_filter_mask: called just above ipc_kobject_server's
        // filter check, the one that first tests KOBJ_IDX_NOT_SET (cmn #1).
        let kobjChecks = findFilterChecks(kobject: true)
        guard kobjChecks.count == 1, let kobjCheck = kobjChecks.first else {
            log("  [-] expected one kobject filter check, found \(kobjChecks.count); failing closed")
            return false
        }
        guard let kobj = filterAccessorAbove(kobjCheck) else {
            log("  [-] no `bl accessor ; cbz x0` above the kobject filter check")
            return false
        }

        // _task_get_mach_trap_filter_mask: the other inlined bitstr_test, whose
        // accessor call directly precedes it.
        let trapChecks = findFilterChecks(kobject: false)
        guard trapChecks.count == 1, let trapCheck = trapChecks.first,
              let trap = branchLinkTarget(at: trapCheck)
        else {
            log("  [-] expected one mach trap filter check, found \(trapChecks.count); failing closed")
            return false
        }

        // _mac_proc_check_syscall_unix: its call in unix_syscall.
        let unixCalls = findUnixSyscallCheckCalls()
        guard unixCalls.count == 1, let unix = unixCalls.first else {
            log("  [-] expected one mac_proc_check_syscall_unix call, found \(unixCalls.count); failing closed")
            return false
        }

        guard Set([kobj, trap, unix]).count == 3 else {
            log("  [-] the three filter entry points are not distinct functions; failing closed")
            return false
        }

        // Returning before the prologue is only correct while nothing has been
        // signed or pushed yet: require `pacibsp ; stp …, [sp, #-n]!`.
        let targets: [(off: Int, zero: Data, name: String)] = [
            (trap, ARM64.movX0_0, "_task_get_mach_trap_filter_mask"),
            (kobj, ARM64.movX0_0, "_task_get_mach_kobj_filter_mask"),
            (unix, ARM64.movW0_0, "_mac_proc_check_syscall_unix"),
        ]
        for target in targets where !hasSignedFramePrologue(at: target.off) {
            log("  [-] \(target.name) at 0x\(String(target.off, radix: 16)) does not open with pacibsp; stp")
            return false
        }

        for target in targets {
            emit(
                target.off,
                target.zero,
                patchID: "kernel-exp-frida_syscall_filter_off",
                virtualAddress: fileOffsetToVA(target.off),
                description: "return 0 [\(target.name), frida]",
            )
            emit(
                target.off + 4,
                ARM64.ret,
                patchID: "kernel-exp-frida_syscall_filter_off",
                virtualAddress: fileOffsetToVA(target.off + 4),
                description: "ret [\(target.name), frida]",
            )
        }
        return true
    }

    // MARK: - Semantic matchers

    /// The inlined `bitstr_test(mask, idx)` both filter checks share:
    ///
    ///     asr  wT, wIdx, #3
    ///     ldrb wT, [xMask, wT, sxtw]
    ///     and  wS, wIdx, #7
    ///     lsr  wT, wT, wS
    ///     tbnz wT, #0, allow
    ///
    /// The kobject check is preceded by `cmn wIdx, #1 ; b.eq` (KOBJ_IDX_NOT_SET)
    /// and followed by `ldr x, [x, #off] ; cbz x` (mac_task_kobj_msg_evaluate);
    /// the trap check is preceded by `bl accessor ; cbz xMask`. Returns the
    /// window start: the `cmn`, or the trap check's `bl`.
    private func findFilterChecks(kobject: Bool) -> [Int] {
        var hits: [Int] = []
        let before = 2
        let count = kobject ? 9 : 7
        for range in codeRanges {
            var off = range.start + before * 4
            while off + (count - before) * 4 <= min(range.end, buffer.count) {
                defer { off += 4 }
                // Rejection-only gate: `asr wD, wN, #3`.
                guard buffer.readU32(at: off) & 0xFFFF_FC00 == 0x1303_7C00 else { continue }
                let start = off - before * 4
                let w = disasm.disassemble(in: buffer.data, at: start, count: count)
                guard w.count == count, isBitstrTest(Array(w[before ..< before + 5])) else { continue }
                func ops(_ i: Int) -> [ARM64Operand] { w[i].detail?.operands ?? [] }
                guard let maskBase = ops(before + 1).first(where: { $0.type == .memory })?.mem.base else { continue }
                if kobject {
                    // The bitmap is the accessor's return value, still in x0.
                    guard sameRegister(maskBase, .x(0)),
                          w[0].mnemonic == "cmn", ops(0).last?.type == .immediate,
                          ops(0).last?.imm == 1, w[1].mnemonic == "b.eq",
                          w[7].mnemonic == "ldr", ops(7).first?.reg.name?.hasPrefix("x") == true,
                          w[8].mnemonic == "cbz", sameRegister(ops(8).first?.reg, ops(7)[0].reg)
                    else { continue }
                } else {
                    guard w[0].mnemonic == "bl",
                          w[1].mnemonic == "cbz", sameRegister(ops(1).first?.reg, maskBase),
                          maskBase.name?.hasPrefix("x") == true
                    else { continue }
                }
                hits.append(start)
            }
        }
        return hits
    }

    private func isBitstrTest(_ w: [ARM64Instruction]) -> Bool {
        func ops(_ i: Int) -> [ARM64Operand] { w[i].detail?.operands ?? [] }
        // Capstone reports these aliases without their shift operands (`asr`
        // and `lsr` decode to two register operands), so the shift amount is
        // read from the operand's shift field or, where present, a third
        // immediate operand; registers are compared by number.
        guard w[0].mnemonic == "asr", ops(0).count >= 2, shiftAmount(ops(0)) == 3,
              w[1].mnemonic == "ldrb",
              let mem = ops(1).first(where: { $0.type == .memory })?.mem,
              sameRegister(mem.index, ops(0)[0].reg),
              w[2].mnemonic == "and", ops(2).count == 3, sameRegister(ops(2)[1].reg, ops(0)[1].reg),
              ops(2)[2].type == .immediate, ops(2)[2].imm == 7,
              w[3].mnemonic == "lsr", ops(3).count >= 2, sameRegister(ops(3)[0].reg, ops(1)[0].reg),
              sameRegister(ops(3)[1].reg, ops(1)[0].reg),
              ops(3).count < 3 || sameRegister(ops(3)[2].reg, ops(2)[0].reg),
              w[4].mnemonic == "tbnz", ops(4).count == 3, sameRegister(ops(4)[0].reg, ops(3)[0].reg),
              ops(4)[1].type == .immediate, ops(4)[1].imm == 0
        else { return false }
        return true
    }

    /// The accessor call `bl accessor ; cbz x0, …` within four instructions
    /// above the kobject filter check.
    private func filterAccessorAbove(_ check: Int) -> Int? {
        for back in 1 ... 4 {
            let off = check - back * 4
            let w = disasm.disassemble(in: buffer.data, at: off, count: 2)
            guard w.count == 2, w[0].mnemonic == "bl", w[1].mnemonic == "cbz",
                  w[1].detail?.operands.first?.reg == .x(0)
            else { continue }
            return branchLinkTarget(at: off)
        }
        return nil
    }

    /// `and w1, wNum, #0xffff ; mov x0, xProc ; bl check ; mov xR, x0 ; cbnz w0`
    /// in unix_syscall; returns the call target.
    ///
    /// That shape alone is not unique: the iOS 26.0 and 26.2 kernels carry it a
    /// second time, calling another function. The real call is the cold block
    /// unix_syscall reaches only when its inlined
    /// `bitstr_test(proc_syscall_filter_mask(p), syscode)` misses, so the site
    /// must also be the target of that test's `tbz wT, #0` (see
    /// `isSyscallMaskMiss(branchingTo:syscall:)`).
    private func findUnixSyscallCheckCalls() -> [Int] {
        var hits: [Int] = []
        for range in codeRanges {
            var off = range.start
            while off + 5 * 4 <= min(range.end, buffer.count) {
                defer { off += 4 }
                // Rejection-only gate: `and w1, wN, #0xffff`.
                guard buffer.readU32(at: off) & 0xFFFF_FC1F == 0x1200_3C01 else { continue }
                let w = disasm.disassemble(in: buffer.data, at: off, count: 5)
                func ops(_ i: Int) -> [ARM64Operand] { w.count > i ? w[i].detail?.operands ?? [] : [] }
                guard w.count == 5,
                      w[0].mnemonic == "and", ops(0).count == 3, ops(0)[0].reg == .w(1),
                      ops(0)[2].type == .immediate, ops(0)[2].imm == 0xFFFF,
                      w[1].mnemonic == "mov", ops(1).first?.reg == .x(0),
                      w[2].mnemonic == "bl",
                      w[3].mnemonic == "mov", ops(3).last?.reg == .x(0),
                      w[4].mnemonic == "cbnz", ops(4).first?.reg == .w(0),
                      isSyscallMaskMiss(branchingTo: off, syscall: ops(0)[1].reg, floor: range.start),
                      let target = branchLinkTarget(at: off + 8)
                else { continue }
                hits.append(target)
            }
        }
        return hits
    }

    /// The constant shift of an `asr`/`lsr` alias: a third immediate operand,
    /// or the shift Capstone attaches to the source register.
    private func shiftAmount(_ ops: [ARM64Operand]) -> Int64? {
        if ops.count >= 3, ops[2].type == .immediate { return ops[2].imm }
        guard ops.count >= 2, ops[1].shift.type != .none else { return nil }
        return Int64(ops[1].shift.amount)
    }

    /// Same general register, whatever width or extension names it.
    private func sameRegister(_ a: ARM64Register?, _ b: ARM64Register?) -> Bool {
        guard let a = a?.name, let b = b?.name, a.count > 1, b.count > 1,
              let ka = a.first, let kb = b.first, "wx".contains(ka), "wx".contains(kb)
        else { return false }
        return a.dropFirst() == b.dropFirst()
    }

    /// True when a `ldrb ; and wS, wNum, #7 ; lsr ; tbz wT, #0, site` — the tail
    /// of unix_syscall's inlined syscall-mask test, on the same syscall number
    /// register — branches to `site` from within 4 KiB before it.
    private func isSyscallMaskMiss(branchingTo site: Int, syscall: ARM64Register, floor: Int) -> Bool {
        var off = site - 4
        while off >= max(floor + 12, site - 0x1000) {
            defer { off -= 4 }
            // Rejection-only gate: `tbz wT, #0`.
            guard buffer.readU32(at: off) & 0xFFF8_0000 == 0x3600_0000 else { continue }
            let w = disasm.disassemble(in: buffer.data, at: off - 12, count: 4)
            func ops(_ i: Int) -> [ARM64Operand] { w.count > i ? w[i].detail?.operands ?? [] : [] }
            guard w.count == 4,
                  w[3].mnemonic == "tbz", ops(3).count == 3, ops(3)[1].type == .immediate, ops(3)[1].imm == 0,
                  ops(3)[2].type == .immediate, Int(ops(3)[2].imm) == site,
                  w[2].mnemonic == "lsr", sameRegister(ops(2).first?.reg, ops(3)[0].reg),
                  w[1].mnemonic == "and", ops(1).count == 3, sameRegister(ops(1)[1].reg, syscall),
                  ops(1)[2].type == .immediate, ops(1)[2].imm == 7,
                  w[0].mnemonic == "ldrb"
            else { continue }
            return true
        }
        return false
    }

    /// Direct `bl` target as a file offset.
    private func branchLinkTarget(at off: Int) -> Int? {
        guard let insn = disasAt(off), insn.mnemonic == "bl",
              let ops = insn.detail?.operands, ops.count == 1, ops[0].type == .immediate
        else { return nil }
        return Int(ops[0].imm)
    }

    private func hasSignedFramePrologue(at off: Int) -> Bool {
        let w = disasm.disassemble(in: buffer.data, at: off, count: 2)
        guard w.count == 2, w[0].mnemonic == "pacibsp", w[1].mnemonic == "stp",
              let detail = w[1].detail, detail.writeback, !detail.postIndex,
              let mem = detail.operands.last, mem.type == .memory, mem.mem.base == .sp
        else { return false }
        return true
    }
}
