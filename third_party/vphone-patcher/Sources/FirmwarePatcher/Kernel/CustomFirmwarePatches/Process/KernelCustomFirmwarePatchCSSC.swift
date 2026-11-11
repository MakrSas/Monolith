import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    struct CSSCHandler {
        let hook: Int
        let epilogue: Int
        let context: UInt32
        let word: UInt32
        let displacedRegister: UInt32
        let displacedImmediate: UInt16
        let pc: UInt32
        let check: Int
        let sign: Int
        let disableInterrupts: Int
        let restoreInterrupts: Int
    }

    /// Reveal from the actual kernel's undefined-instruction handler. The
    /// copyin and signed-state helpers must all resolve before any write.
    func revealCSSCHandler() -> CSSCHandler? {
        guard let range = kernTextRange,
              let anchor = buffer.findString("Undefined kernel instruction: pc=%p instr=%x") else { return nil }
        let refs = findStringRefs(anchor, in: (range.0, range.1))
        var starts = Set<Int>()
        for ref in refs {
            let low = max(range.0, ref.adrpOff - 0x800)
            let prefix = disasm.disassemble(in: buffer.original, at: low, count: (ref.adrpOff - low) / 4)
            if let start = prefix.last(where: { $0.mnemonic == "pacibsp" }) { starts.insert(Int(start.address)) }
        }
        guard starts.count == 1, let start = starts.first else { return nil }
        var i = disasm.disassemble(in: buffer.original, at: start, count: min(0x800, range.1 - start) / 4)
        if let next = i.dropFirst().firstIndex(where: { $0.mnemonic == "pacibsp" }) { i = Array(i[..<next]) }
        guard i.count > 30 else { return nil }

        func reg(_ op: ARM64Operand?) -> UInt32? {
            guard let op, op.type == .register else { return nil }
            return (0..<31).first(where: { op.reg == .x($0) || op.reg == .w($0) }).map(UInt32.init)
        }
        func load(_ item: ARM64Instruction, rt: ARM64Register, base: ARM64Register, offset: Int64) -> Bool {
            guard item.mnemonic == "ldr", let o = item.detail?.operands, o.count == 2 else { return false }
            return o[0].reg == rt && o[1].type == .memory && o[1].mem.base == base && o[1].mem.disp == offset
        }
        func target(_ item: ARM64Instruction, _ name: String) -> Int? {
            guard item.mnemonic == name, let o = item.detail?.operands.last, o.type == .immediate else { return nil }
            return Int(exactly: o.imm)
        }
        // System-register names are not exposed by ARM64Operand; use its
        // printed system operand only here, never for GPRs or memory operands.
        func stackSelect(_ item: ARM64Instruction, _ value: Int64) -> Bool {
            item.mnemonic == "msr" && item.operandString.split(separator: ",").first?.lowercased() == "spsel"
                && item.detail?.operands.last?.imm == value
        }

        // COPYIN(user PC, &instruction, 4), followed by the user/kernel gate.
        var copies: [(Int, UInt32, UInt32, UInt32)] = []
        for n in 3..<i.count - 4 where i[n].mnemonic == "bl" {
            guard let source = i[n - 3].detail?.operands, source.count == 2,
                  i[n - 3].mnemonic == "ldr", source[0].reg == .x(0), source[1].type == .memory,
                  let context = (0..<29).first(where: { source[1].mem.base == .x($0) }),
                  source[1].mem.disp >= 256, source[1].mem.disp % 8 == 0,
                  let count = i[n - 1].detail?.operands, i[n - 1].mnemonic == "mov", count.count == 2,
                  count[0].reg == .w(2), count[1].imm == 4,
                  let destination = i[n - 2].detail?.operands, i[n - 2].mnemonic == "add", destination.count == 3,
                  destination[0].reg == .x(1), destination[1].reg == .sp, destination[2].type == .immediate,
                  let loaded = i[n + 2].detail?.operands, loaded.count == 2,
                  let word = reg(loaded[0]), loaded[0].reg == .w(Int(word)),
                  load(i[n + 2], rt: .w(Int(word)), base: .sp, offset: destination[2].imm),
                  i[n + 1].mnemonic == "ldr", i[n + 1].detail?.operands.last?.mem.base == .x(context)
            else { continue }
            copies.append((n, UInt32(context), word, UInt32(source[1].mem.disp)))
        }
        guard copies.count == 1 else { return nil }
        let (copy, context, word, pc) = copies[0]
        // Restrict the ABI to the verified arm_saved_state64 layout. These are
        // structure fields, not a kernel file offset or runtime address.
        guard pc == 8 + 32 * 8 else { return nil }

        var gates: [(Int, UInt32, UInt16)] = []
        for n in copy + 3..<min(copy + 16, i.count - 1) {
            guard let o = i[n].detail?.operands, i[n].mnemonic == "tst", o.count == 2, o[1].imm == 0xc,
                  let destination = target(i[n + 1], "b.eq"),
                  let entry = i.firstIndex(where: { $0.address == UInt64(destination) }), entry + 2 < i.count,
                  i[entry].mnemonic == "mov", let move = i[entry].detail?.operands, move.count == 2,
                  let scratch = reg(move[0]), move[1].type == .immediate, move[1].imm == 0xdefe,
                  i[entry + 1].mnemonic == "movk", i[entry + 2].mnemonic == "cmp",
                  !i[(copy + 1)...n].contains(where: { $0.isCall || $0.detail?.operands.first?.reg == .x(0) || $0.detail?.operands.first?.reg == .w(0) })
            else { continue }
            gates.append((destination, scratch, UInt16(move[1].imm)))
        }
        guard gates.count == 1 else { return nil }

        // Reuse the same kernel's signed-state ABI, including its PAC-safe
        // interrupt helpers. handle_uncategorized already advances a PC for
        // recoverable debugger traps; this is the source-backed reveal anchor.
        var support: [(Int, Int, Int, Int)] = []
        for n in 4..<i.count - 12 where stackSelect(i[n], 1) {
            guard i[n + 1].mnemonic == "ldp", let pair = i[n + 1].detail?.operands, pair.count == 3,
                  pair[0].reg == .x(4), pair[1].reg == .x(5), pair[2].mem.base == .x(0), pair[2].mem.disp == Int64(pc - 16 * 8),
                  load(i[n + 2], rt: .x(7), base: .x(0), offset: Int64(pc)),
                  load(i[n + 3], rt: .w(8), base: .x(0), offset: Int64(pc + 8)),
                  load(i[n + 4], rt: .x(3), base: .x(0), offset: Int64(pc - 16)),
                  let check = target(i[n + 7], "bl"), let disable = target(i[n - 4], "bl"),
                  let exit = (n + 8..<i.count - 3).first(where: { stackSelect(i[$0], 0) }),
                  let sign = target(i[exit - 1], "bl"), let restore = target(i[exit + 3], "bl")
            else { continue }
            let checkCode = disasm.disassemble(in: buffer.original, at: check, count: 40)
            let signCode = disasm.disassemble(in: buffer.original, at: sign, count: 20)
            let restoreCode = disasm.disassemble(in: buffer.original, at: restore, count: 3)
            guard checkCode.contains(where: { $0.mnemonic == "pacga" }),
                  signCode.contains(where: { $0.mnemonic == "pacga" }),
                  restoreCode.contains(where: { $0.mnemonic == "msr" && $0.operandString.lowercased().hasPrefix("daif,") })
            else { continue }
            support.append((check, sign, disable, restore))
        }
        guard support.count == 1 else { return nil }
        let returns = i.indices.filter { n in
            guard n >= 10, i[n].mnemonic == "retab", i[n - 4].mnemonic == "ldp",
                  i[n - 4].detail?.operands.first?.reg == .x(29),
                  i[n - 3].mnemonic == "ldp", i[n - 2].mnemonic == "ldp", i[n - 1].mnemonic == "add",
                  i[n - 10].mnemonic == "ldur", i[n - 10].detail?.operands.last?.mem.base == .x(29),
                  i[n - 5].mnemonic == "b.ne", i[n - 6].mnemonic == "cmp"
            else { return false }
            return true
        }
        guard returns.count == 1 else { return nil }
        let s = support[0], g = gates[0]
        return CSSCHandler(hook: g.0, epilogue: Int(i[returns[0] - 10].address), context: context, word: word,
                           displacedRegister: g.1, displacedImmediate: g.2, pc: pc,
                           check: s.0, sign: s.1, disableInterrupts: s.2, restoreInterrupts: s.3)
    }

    func patchCSSC() throws {
        let identifier = FirmwareKernelCustomFirmwarePatchSet.cssc
        guard gate.isEnabled(identifier) else { return }
        guard let handler = revealCSSCHandler() else {
            throw PatcherError.invalidFormat("cannot validate kernel CSSC exception and signed-state paths")
        }
        // One fixed payload in persistent __TEXT_EXEC, never boot-only code.
        let sample = try csscPayload(handler, at: handler.hook)
        guard let cave = findCodeCave(size: sample.count),
              segments.contains(where: { $0.name == "__TEXT_EXEC" && UInt64(cave) >= $0.fileOffset && UInt64(cave + sample.count) <= $0.fileOffset + $0.fileSize }),
              let entry = ARM64Encoder.encodeB(from: handler.hook, to: cave)
        else { throw PatcherError.invalidFormat("no persistent executable space for kernel CSSC handler") }
        let payload = try csscPayload(handler, at: cave)
        guard payload.count == sample.count else { throw PatcherError.invalidFormat("kernel CSSC payload size changed") }
        emit(cave, payload, patchID: identifier + ".handler", virtualAddress: fileOffsetToVA(cave), description: "EL0 scalar CSSC emulator with signed-state recovery")
        emit(handler.hook, entry, patchID: identifier + ".entry", virtualAddress: fileOffsetToVA(handler.hook), description: "try CSSC before undefined-instruction triage")
    }

    func csscPayload(_ h: CSSCHandler, at base: Int) throws -> Data {
        var c = VPhoneCSSCCode.Builder()
        let frame: UInt32 = 192
        func registerOffset(_ r: UInt32) -> UInt32 { r == 30 ? 152 : r * 8 }
        func loadContext(_ c: inout VPhoneCSSCCode.Builder) {
            if h.context < 19 { c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 31, offset: registerOffset(h.context))) }
            else { c.emit(ARM64Encoder.encodeMovX(rd: 0, rm: h.context)) }
        }
        func call(_ c: inout VPhoneCSSCCode.Builder, _ target: Int) {
            c.emit(ARM64Encoder.encodeBL(from: base + c.data.count, to: target))
        }
        c.emit(ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: frame))
        for r: UInt32 in 0..<19 { c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: r, rn: 31, offset: r * 8)) }
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 30, rn: 31, offset: 152))
        c.emit(ARM64Encoder.encodeReadStatus(rt: 16))
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 16, rn: 31, offset: 160))
        // copyin return value remains in x0 on this validated user path.
        c.branch("unknown", register: 0, nonzero: true)
        loadContext(&c)
        c.emit(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 3, rn: 0, offset: 0))
        c.emit(ARM64Encoder.encodeCmpWImmediate(rn: 3, imm12: 21)) // ARM_SAVED_STATE64
        c.emit(ARM64Encoder.encodeCsetW(rd: 3, condition: .ne))
        c.branch("unknown", register: 3, nonzero: true)
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 3, rn: 0, offset: h.pc + 24))
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 3, rn: 3, lsb: 26, width: 6))
        c.branch("unknown", register: 3, nonzero: true) // EC_UNCATEGORIZED only
        c.emit(ARM64Encoder.encodeAddImm12(rd: 1, rn: 0, imm12: h.pc - 32 * 8))
        c.emit(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 0, rn: 31, offset: registerOffset(h.word)))
        c.emit(ARM64Encoder.encodeAddImm12(rd: 2, rn: 31, imm12: 168))
        let emulatorCall = c.data.count
        c.emit(ARM64.nop)
        c.branch("unknown", register: 0)

        call(&c, h.disableInterrupts)
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 31, offset: 176))
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 10, rn: 31, offset: 168))
        c.emit(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 11, rn: 31, offset: registerOffset(h.word)))
        c.emit(ARM64Encoder.encodeBitfieldExtract(rd: 11, rn: 11, lsb: 0, width: 5))
        loadContext(&c)
        c.emit(ARM64Encoder.encodeAddImm12(rd: 12, rn: 0, imm12: h.pc - 32 * 8))
        c.emit(ARM64Encoder.encodeAddSubXShifted(subtract: false, rd: 12, rn: 12, rm: 11, shift: 3))
        // Same protected sequence as MANIPULATE_SIGNED_THREAD_STATE: no stack
        // accesses between SPSel=1 and SPSel=0; verify before any state write.
        c.emit(ARM64Encoder.encodeSelectStackPointer(interruptStack: true))
        for (r, offset): (UInt32, UInt32) in [(4, h.pc - 128), (5, h.pc - 120), (7, h.pc), (3, h.pc - 16)] {
            c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: r, rn: 0, offset: offset))
        }
        c.emit(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 8, rn: 0, offset: h.pc + 8))
        c.emit(ARM64Encoder.encodeMovX(rd: 1, rm: 7))
        c.emit(ARM64Encoder.encodeMovX(rd: 2, rm: 8))
        call(&c, h.check)
        c.emit(ARM64Encoder.encodeAddImm12(rd: 1, rn: 7, imm12: 4))
        c.emit(ARM64Encoder.encodeMovX(rd: 2, rm: 8))
        for (destination, signatureRegister): (UInt32, UInt32) in [(30, 3), (16, 4), (17, 5)] {
            c.emit(ARM64Encoder.encodeCmpWImmediate(rn: 11, imm12: destination))
            c.emit(ARM64Encoder.encodeConditionalSelect(rd: signatureRegister, rn: 10, rm: signatureRegister, condition: .eq))
        }
        c.emit(ARM64Encoder.encodeCmpWImmediate(rn: 11, imm12: 31))
        c.equal("zeroDestination")
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 10, rn: 12, offset: 0))
        c.label("zeroDestination")
        c.emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 1, rn: 0, offset: h.pc))
        call(&c, h.sign)
        c.emit(ARM64Encoder.encodeSelectStackPointer(interruptStack: false))
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: 31, offset: 176))
        call(&c, h.restoreInterrupts)
        restore(&c, frame: frame)
        c.labels["return"] = h.epilogue - base
        c.branch("return")
        c.label("unknown")
        restore(&c, frame: frame)
        c.emit(ARM64Encoder.encodeMovzW(rd: h.displacedRegister, imm16: h.displacedImmediate))
        c.labels["original"] = h.hook + 4 - base
        c.branch("original")
        var code = try c.finish()
        guard let call = ARM64Encoder.encodeBL(from: emulatorCall, to: code.count) else { throw PatcherError.invalidFormat("CSSC emulator call out of range") }
        code.replaceSubrange(emulatorCall..<emulatorCall + 4, with: call)
        code += try VPhoneCSSCCode.emulator()
        return code
    }

    private func restore(_ c: inout VPhoneCSSCCode.Builder, frame: UInt32) {
        for r: UInt32 in 0..<19 where r != 16 { c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: r, rn: 31, offset: r * 8)) }
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 30, rn: 31, offset: 152))
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: 31, offset: 160))
        c.emit(ARM64Encoder.encodeWriteStatus(rt: 16))
        c.emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: 31, offset: 128))
        c.emit(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: frame))
    }
}
