// ARM64E_X1 admission; reveal procedure is in Research/0_binary_patch_comparison.md.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    @discardableResult
    func patchArm64eX1Admission() -> Bool {
        let identifier = "kernel-boot-arm64e_x1"
        guard gate.isEnabled(identifier) else { return false }
        guard let (start, end) = kernTextRange else { return false }

        var grades: [(entry: Int, compare: Int)] = []
        let raw = buffer.original
        for block in stride(from: start, to: end, by: 0x4000) {
            let scanStart = max(start, block - 16)
            let stop = min(end, block + 0x4000 + 0x100)
            let instructions = disasm.disassemble(raw.subdata(in: scanStart ..< stop), at: UInt64(scanStart))
            for (index, instruction) in instructions.enumerated() where instruction.address >= UInt64(block) && instruction.address < UInt64(block + 0x4000) {
                guard x1RegImmediate(instruction, mnemonic: "cmp", register: .w(1), immediate: 2),
                      index >= 3, index + 7 < instructions.count
                else { continue }
                let tail = Array(instructions[(index - 3) ... (index + 7)])
                guard x1GradeTail(tail) else { continue }

                // ml_grade_binary has no PAC prologue; anchor its entry on the per-CPU load and BL xref.
                let compare = Int(instruction.address)
                let prefix = disasm.disassemble(in: raw, at: max(start, compare - 0x100), count: min(0x100, compare - start) / 4)
                let entries = prefix.filter { candidate in
                    guard candidate.mnemonic == "mrs", blIndex[Int(candidate.address)] != nil else { return false }
                    let head = disasm.disassemble(in: raw, at: Int(candidate.address), count: 3)
                    guard head.count == 3,
                          let register = head[0].detail?.operands.first?.reg,
                          let first = head[1].detail?.operands, first.count == 2,
                          first[0].type == .register, first[0].reg == register,
                          first[1].type == .memory, first[1].mem.base == register,
                          let second = head[2].detail?.operands, second.count == 2,
                          second[1].type == .memory, second[1].mem.base == register,
                          second[1].mem.disp == 8
                    else { return false }
                    return head[1].mnemonic == "ldr" && head[2].mnemonic == "ldr"
                }
                if entries.count == 1 { grades.append((Int(entries[0].address), compare)) }
            }
        }
        guard grades.count == 1 else {
            log("  [-] ARM64E_X1: ml_grade_binary not unique (\(grades.count))")
            return false
        }
        let grade = grades[0]
        var execSites: [(offset: Int, register: UInt32)] = []
        for caller in blIndex[grade.entry] ?? [] {
            let instructions = disasm.disassemble(in: raw, at: caller + 4, count: 32)
            for index in instructions.indices where index >= 2 && index + 6 < instructions.count {
                if let register = x1ExecPACGate(Array(instructions[(index - 2) ... (index + 6)])) {
                    execSites.append((Int(instructions[index].address), register))
                }
            }
        }
        guard execSites.count == 1 else {
            log("  [-] ARM64E_X1: exec IMGPF_NOJOP gate not unique (\(execSites.count))")
            return false
        }

        // The successful shared-region path retains subtype 2 for the existing auth pagers.
        guard let shared = x1ExecSharedRegionGate(after: execSites[0].offset) else {
            log("  [-] ARM64E_X1: exec shared-region PAC gate not unique")
            return false
        }
        let sites: [(offset: Int, register: UInt32, name: String)] = [
            (grade.compare, 1, "grade"),
            (execSites[0].offset, execSites[0].register, "exec_ptrauth"),
            (shared.offset, shared.register, "exec_shared_region"),
        ]
        guard let cave = findCodeCave(size: sites.count * 12) else {
            log("  [-] ARM64E_X1: no executable cave")
            return false
        }
        var writes: [(offset: Int, data: Data, name: String)] = []
        for (index, site) in sites.enumerated() {
            let trampoline = cave + index * 12
            guard let entry = ARM64Encoder.encodeB(from: site.offset, to: trampoline),
                  let cmp = ARM64Encoder.encodeCmpWImmediate(rn: site.register, imm12: 12),
                  let ccmp = ARM64Encoder.encodeCcmpWImmediate(rn: site.register, imm5: 2, nzcv: 6, condition: .ne),
                  let resume = ARM64Encoder.encodeB(from: trampoline + 8, to: site.offset + 4)
            else { return false }
            // NZCV=0110 makes subtype 12 equivalent to CMP Wn,#2 with Wn=2.
            writes.append((trampoline, cmp + ccmp + resume, site.name + ".cave"))
            writes.append((site.offset, entry, site.name))
        }
        for write in writes {
            emit(write.offset, write.data, patchID: identifier + "." + write.name,
                 virtualAddress: fileOffsetToVA(write.offset),
                 description: "ARM64E_X1 subtype 12 or legacy subtype 2 [\(write.name)]")
        }
        return true
    }

    private func x1RegImmediate(_ instruction: ARM64Instruction, mnemonic: String, register: ARM64Register, immediate: Int64) -> Bool {
        guard instruction.mnemonic == mnemonic, let ops = instruction.detail?.operands, ops.count == 2 else { return false }
        return ops[0].type == .register && ops[0].reg == register && ops[1].type == .immediate && ops[1].imm == immediate
    }

    private func x1ExecSharedRegionGate(after execCompare: Int) -> (offset: Int, register: UInt32)? {
        let instructions = disasm.disassemble(in: buffer.original, at: execCompare + 4,
                                              count: min(0x800, buffer.original.count - execCompare - 4) / 4)
        var hits: [(Int, UInt32)] = []
        for index in instructions.indices where index >= 2 && index + 3 < instructions.count {
            let i = Array(instructions[(index - 2) ... (index + 3)])
            guard i[0].mnemonic == "ldr", let load = i[0].detail?.operands, load.count == 2,
                  load[0].type == .register, load[1].type == .memory,
                  i[1].mnemonic == "and", let mask = i[1].detail?.operands, mask.count == 3,
                  mask[0].reg == load[0].reg, mask[1].reg == load[0].reg,
                  mask[2].type == .immediate, mask[2].imm == 0x0FFF_FFFF,
                  x1RegImmediate(i[2], mnemonic: "cmp", register: load[0].reg, immediate: 2),
                  let reject = x1BranchTarget(i[3], mnemonic: "b.ne"),
                  i[4].mnemonic == "ldr", let flags = i[4].detail?.operands, flags.count == 2,
                  flags[1].type == .memory, flags[1].mem.disp == 0x48,
                  x1BranchTarget(i[5], mnemonic: "tbnz") == reject,
                  let bit = i[5].detail?.operands, bit.count == 3,
                  bit[0].reg == flags[0].reg, bit[1].type == .immediate, bit[1].imm == 31
            else { continue }
            let failure = disasm.disassemble(in: buffer.original, at: reject, count: 1)
            let success = disasm.disassemble(in: buffer.original, at: reject - 12, count: 1)
            guard failure.count == 1, success.count == 1,
                  let subtypeRegister = failure[0].detail?.operands.first?.reg,
                  x1RegImmediate(failure[0], mnemonic: "mov", register: subtypeRegister, immediate: 0),
                  x1RegImmediate(success[0], mnemonic: "mov", register: subtypeRegister, immediate: 2),
                  let register = (0 ... 30).first(where: { ARM64Register.w($0) == load[0].reg })
            else { continue }
            hits.append((Int(i[2].address), UInt32(register)))
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private func x1BranchTarget(_ instruction: ARM64Instruction, mnemonic: String) -> Int? {
        guard instruction.mnemonic == mnemonic, let op = instruction.detail?.operands.last, op.type == .immediate else { return nil }
        return Int(exactly: op.imm)
    }

    private func x1ReturnsGrade(at offset: Int, grade: Int64) -> Bool {
        let instructions = disasm.disassemble(in: buffer.original, at: offset, count: 2)
        return instructions.count == 2 && x1RegImmediate(instructions[0], mnemonic: "mov", register: .w(0), immediate: grade)
            && instructions[1].mnemonic == "ret"
    }

    private func x1GradeTail(_ i: [ARM64Instruction]) -> Bool {
        guard let all = x1BranchTarget(i[0], mnemonic: "cbz"), i[0].detail?.operands.first?.reg == .w(1),
              x1ReturnsGrade(at: all, grade: 9),
              x1RegImmediate(i[1], mnemonic: "cmp", register: .w(1), immediate: 1),
              let v8 = x1BranchTarget(i[2], mnemonic: "b.eq"), x1ReturnsGrade(at: v8, grade: 10),
              let reject = x1BranchTarget(i[4], mnemonic: "b.ne"), x1ReturnsGrade(at: reject, grade: 0),
              x1RegImmediate(i[5], mnemonic: "tst", register: .w(2), immediate: 0x0F00_0000),
              i[6].mnemonic == "mov", let mov = i[6].detail?.operands, mov.count == 2,
              mov[0].type == .register, mov[1].type == .immediate, mov[1].imm == 11,
              i[7].mnemonic == "cinc", let cinc = i[7].detail?.operands, cinc.count == 2,
              cinc[0].reg == mov[0].reg, cinc[1].reg == mov[0].reg,
              i[8].mnemonic == "and", let result = i[8].detail?.operands, result.count == 3,
              result[0].reg == .w(0), result[1].reg == mov[0].reg, result[2].reg == .w(2),
              i[9].mnemonic == "ret"
        else { return false }
        return true
    }

    private func x1ExecPACGate(_ i: [ARM64Instruction]) -> UInt32? {
        guard i[0].mnemonic == "ldr", let load = i[0].detail?.operands, load.count == 2,
              load[0].type == .register, load[1].type == .memory, load[1].mem.disp == 8,
              i[1].mnemonic == "and", let mask = i[1].detail?.operands, mask.count == 3,
              mask[0].reg == load[0].reg, mask[1].reg == load[0].reg,
              mask[2].type == .immediate, mask[2].imm == 0x0FFF_FFFF,
              x1RegImmediate(i[2], mnemonic: "cmp", register: load[0].reg, immediate: 2),
              let disabled = x1BranchTarget(i[3], mnemonic: "b.ne"),
              i[4].mnemonic == "and", let clear = i[4].detail?.operands, clear.count == 3,
              clear[2].type == .immediate, clear[2].imm == 0x7FFF_FFFF,
              let common = x1BranchTarget(i[5], mnemonic: "b"),
              x1RegImmediate(i[6], mnemonic: "mov", register: .w(0), immediate: 86)
        else { return nil }
        let set = disasm.disassemble(in: buffer.original, at: disabled, count: 1)
        let store = disasm.disassemble(in: buffer.original, at: common, count: 1)
        guard set.count == 1, set[0].mnemonic == "orr", let ops = set[0].detail?.operands, ops.count == 3,
              ops[0].reg == clear[0].reg, ops[1].reg == clear[1].reg,
              ops[2].type == .immediate, UInt32(truncatingIfNeeded: ops[2].imm) == 0x8000_0000,
              store.count == 1, store[0].mnemonic == "str", let str = store[0].detail?.operands, str.count == 2,
              str[0].reg == clear[0].reg, str[1].type == .memory, str[1].mem.disp == 0x48
        else { return nil }
        return (0 ... 30).first(where: { ARM64Register.w($0) == load[0].reg }).map(UInt32.init)
    }
}
