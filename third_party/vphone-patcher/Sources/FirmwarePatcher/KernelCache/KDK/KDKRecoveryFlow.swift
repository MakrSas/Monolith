import Foundation
import VPhonePatchKit

extension KDKRecovery {
    final class FlowContext {
        let code: KDKCode
        let functions: [KDKFunction]
        let starts: [UInt64]
        var returnSites: [UInt64: [UInt64]] = [:]
        var viaReturn = Set<UInt64>()
        var adrpFunction: UInt64 = 0
        let panicAddresses: Set<UInt64>
        init(code: KDKCode, functions: [KDKFunction], symbols: [KDKSymbol]) {
            self.code = code
            self.functions = functions.filter { code.section.contains($0.start) }.sorted { $0.start < $1.start }
            starts = self.functions.map(\.start)
            panicAddresses = Set(symbols.filter { $0.name == "_panic" }.map(\.value))
            for off in stride(from: 0, to: max(0, code.bytes.count - 3), by: 4) {
                let word = code.bytes.le(UInt32.self, off), pc = code.section.address + UInt64(off)
                if ARM64Inst.isBL(word), let target = KDKInstruction.branch(word, pc), code.section.contains(target) {
                    returnSites[target, default: []].append(pc + 4)
                }
            }
        }

        func function(_ address: UInt64) -> KDKFunction? {
            let i = starts.upperBound(address) - 1
            return i >= 0 && functions[i].contains(address) ? functions[i] : nil
        }
    }

    func recoverOff12(_ image: KDKImage, _ code: KDKCode, _ adrps: [UInt64: UInt64]) -> [KDKReference] {
        let context = FlowContext(code: code, functions: functions[image.identifier] ?? [], symbols: image.symbols)
        var result: [KDKReference] = []
        for source in adrps.keys.sorted() {
            let register = ARM64Inst.rd(code.word(source)!)
            context.viaReturn.removeAll(keepingCapacity: true)
            context.adrpFunction = context.function(source)?.start ?? 0
            var returns: [UInt64: Bool] = [:], visited: [UInt64: Set<UInt32>] = [:]
            let usages = track(context, at: source + 4, register: register, target: adrps[source]!, returns: &returns, visited: &visited)
            let function = (functions[image.identifier] ?? []).first { $0.contains(source) }
            for (consumer, target) in usages {
                if let function, !function.contains(consumer), !context.viaReturn.contains(consumer) {
                    continue
                }
                result.append(.init(kind: 6, source: consumer, target: target, extra: source))
            }
        }
        return result
    }

    func track(_ context: FlowContext, at address: UInt64, register: UInt32, target: UInt64,
               returns: inout [UInt64: Bool], visited: inout [UInt64: Set<UInt32>]) -> [UInt64: UInt64]
    {
        let code = context.code
        var result: [UInt64: UInt64] = [:]
        // Keep the reader position separate: the reference's failed jump-table
        // recognizer rewinds its reader. Preserve this until differential tests
        // justify changing that behavior in both implementations.
        var reader = address
        for i in 0 ..< 10000 {
            guard let word = code.word(reader) else { break }
            reader += 4
            let pc = address + UInt64(i) * 4
            if visited[pc, default: []].contains(register) {
                break
            }
            visited[pc, default: []].insert(register)
            if let offset = ARM64Encoder.decodePageOffset(word) {
                if ARM64Inst.rn(word) == register {
                    result[pc] = target &+ UInt64(offset)
                }
            } else if KDKInstruction.ret(word) {
                if let function = context.function(pc), function.start == context.adrpFunction {
                    for site in context.returnSites[function.start] ?? [] {
                        let usages = track(context, at: site, register: register, target: target, returns: &returns, visited: &visited)
                        for (source, target) in usages {
                            result[source] = target
                            context.viaReturn.insert(source)
                        }
                    }
                }
                break
            } else if KDKInstruction.brk(word) {
                break
            } else if ARM64Inst.isBL(word) || KDKInstruction.blr(word) || KDKInstruction.authCall(word) {
                if register < 8 {
                    break
                }
                guard ARM64Inst.isBL(word), let callee = KDKInstruction.branch(word, pc) else {
                    if register >= 19, register <= 28 {
                        continue
                    }
                    break
                }
                let (written, known) = calleeWrites(code, at: callee, register: register)
                if written || (!known && register <= 18) {
                    break
                }
                var returnVisited = Set<UInt64>()
                if !mayReturn(context, at: callee, returns: &returns, visited: &returnVisited) {
                    break
                }
                continue
            } else if KDKInstruction.br(word) {
                if followJumpTable(context, word: word, reader: &reader, register: register, target: target,
                                   result: &result, returns: &returns, visited: &visited)
                {
                    break
                }
            } else if KDKInstruction.authJump(word) {
                break
            } else if !KDKInstruction.linear(word) {
                if let branch = KDKInstruction.branch(word, pc), code.word(branch) != nil {
                    let usages = track(context, at: branch, register: register, target: target, returns: &returns, visited: &visited)
                    result.merge(usages) { _, new in new }
                }
                if KDKInstruction.b(word) {
                    break
                }
                continue
            } else if word & 0x7FE0_FFE0 == 0x2A00_03E0, ARM64Inst.rm(word) == register {
                let usages = track(context, at: pc + 4, register: ARM64Inst.rd(word), target: target, returns: &returns, visited: &visited)
                result.merge(usages) { _, new in new }
            }
            if KDKInstruction.writes(word, register) {
                break
            }
        }
        return result
    }

    func calleeWrites(_ code: KDKCode, at start: UInt64, register: UInt32) -> (Bool, Bool) {
        var pc = start
        for _ in 0 ..< 64 {
            guard let word = code.word(pc) else { return (false, false) }
            if KDKInstruction.ret(word) {
                return (false, true)
            }
            if !KDKInstruction.linear(word) || KDKInstruction.authJump(word) || KDKInstruction.authCall(word) {
                return (false, false)
            }
            let stack = word & 0x0A00_0000 == 0x0800_0000 && ARM64Inst.rn(word) == 31
            if stack, KDKInstruction.store(word) || KDKInstruction.storePair(word),
               ARM64Inst.rd(word) == register || (KDKInstruction.storePair(word) && (word >> 10) & 31 == register)
            {
                return (false, false)
            }
            if !stack, KDKInstruction.writes(word, register) {
                return (true, true)
            }
            pc += 4
        }
        return (false, false)
    }

    func followJumpTable(_ context: FlowContext, word branch: UInt32, reader: inout UInt64, register: UInt32, target: UInt64,
                         result: inout [UInt64: UInt64], returns: inout [UInt64: Bool], visited: inout [UInt64: Set<UInt32>]) -> Bool
    {
        func back(_ n: UInt64) -> Bool {
            guard reader >= context.code.section.address + n * 4 else { return false }
            reader -= n * 4
            return true
        }
        func read() -> UInt32? {
            let word = context.code.word(reader)
            if word != nil {
                reader += 4
            }
            return word
        }
        let branchRegister = ARM64Inst.rn(branch)
        guard back(2), let add = read(), KDKInstruction.add(add), branchRegister == ARM64Inst.rd(add) else { return false }
        let offsetRegister = ARM64Inst.rm(add)
        guard back(2) else { return false }
        let adrAddress = reader
        guard back(1), let load = read(), load & 0xFFE0_FC00 == 0xB8A0_7800, offsetRegister == ARM64Inst.rd(load) else { return false }
        let baseRegister = ARM64Inst.rn(load), indexRegister = ARM64Inst.rm(load)
        guard back(2), let tableAdd = read(), KDKInstruction.add(tableAdd), baseRegister == ARM64Inst.rd(tableAdd) else { return false }
        let tableOffset = UInt64(ARM64Encoder.decodePageOffset(tableAdd) ?? 0)
        guard back(2), let adrp = read(), ARM64Inst.isADRP(adrp), ARM64Inst.rn(tableAdd) == ARM64Inst.rd(adrp) else { return false }
        // The pinned reference passes the reader's post-instruction address.
        let table = KDKInstruction.adrp(adrp, reader) &+ tableOffset
        guard back(3), let compare = read(), compare & 0x7F80_001F == 0x7100_001F, indexRegister == ARM64Inst.rn(compare) else { return false }
        let count = UInt64((compare >> 10) & 0xFFF) << (((compare >> 22) & 1) == 1 ? 12 : 0)
        guard context.code.word(table) != nil else { return true }
        reader = table
        for _ in 0 ..< count {
            guard let raw = read() else { break }
            let destination = adrAddress &+ UInt64(bitPattern: Int64(Int32(bitPattern: raw)))
            guard context.code.word(destination) != nil else { continue }
            let usages = track(context, at: destination, register: register, target: target, returns: &returns, visited: &visited)
            result.merge(usages) { _, new in new }
        }
        return true
    }

    func mayReturn(_ context: FlowContext, at start: UInt64, returns: inout [UInt64: Bool], visited: inout Set<UInt64>) -> Bool {
        if let known = returns[start] {
            return known
        }
        if context.panicAddresses.contains(start) {
            returns[start] = false
            return false
        }
        if context.code.word(start) == nil {
            let result = foreignMayReturn(start, depth: 0)
            returns[start] = result
            return result
        }
        var pc = start
        for _ in 0 ..< 1000 {
            guard let word = context.code.word(pc) else { break }
            if !visited.insert(pc).inserted {
                return false
            }
            if KDKInstruction.ret(word) || KDKInstruction.brk(word) || KDKInstruction.authJump(word) {
                returns[start] = true
                return true
            } else if ARM64Inst.isBL(word) || KDKInstruction.blr(word) {
                guard ARM64Inst.isBL(word), let callee = KDKInstruction.branch(word, pc) else { return true }
                if !mayReturn(context, at: callee, returns: &returns, visited: &visited) {
                    returns[start] = false
                    return false
                }
            } else if !KDKInstruction.linear(word) {
                guard let target = KDKInstruction.branch(word, pc) else { return true }
                if mayReturn(context, at: target, returns: &returns, visited: &visited) {
                    returns[start] = true
                    return true
                }
                if KDKInstruction.b(word) {
                    returns[start] = false
                    return false
                }
            }
            pc += 4
        }
        return true
    }

    func foreignMayReturn(_ start: UInt64, depth: Int) -> Bool {
        if let known = foreignReturns[start] {
            return known
        }
        let index = allFunctionStarts.upperBound(start) - 1
        guard index >= 0, allFunctions[index].start == start, depth <= 8 else { return true }
        let function = allFunctions[index]
        foreignReturns[start] = true // recursion assumes returning until proven otherwise
        var result = false, seen = Set<UInt64>(), work = [start]
        while !work.isEmpty, !result {
            var pc = work.removeLast()
            while !result {
                guard function.contains(pc), seen.insert(pc).inserted else { break }
                let codeIndex = allCodeStarts.upperBound(pc) - 1
                guard codeIndex >= 0, let word = allCode[codeIndex].word(pc) else { result = true
                    break
                }
                if KDKInstruction.ret(word) {
                    result = true
                } else if KDKInstruction.brk(word) {
                    break
                } else if KDKInstruction.br(word) || KDKInstruction.authJump(word) {
                    result = true
                } else if ARM64Inst.isBL(word) {
                    if let target = KDKInstruction.branch(word, pc), !foreignMayReturn(target, depth: depth + 1) {
                        break
                    }
                    pc += 4
                    continue
                } else if KDKInstruction.b(word) {
                    let target = KDKInstruction.branch(word, pc)!
                    if !function.contains(target) {
                        result = foreignMayReturn(target, depth: depth + 1)
                        break
                    }
                    pc = target
                    continue
                } else {
                    if let target = KDKInstruction.branch(word, pc) {
                        work.append(target)
                    }
                    pc += 4
                    continue
                }
                break
            }
        }
        foreignReturns[start] = result
        return result
    }
}
