import Foundation

public enum VPhoneArm64eX1Lowering {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public static func replacement(for instruction: ARM64Instruction) throws -> Data? {
        let name = instruction.mnemonic
        let ops = instruction.detail?.operands ?? []
        switch name {
        case "pacibsppc", "pacnbibsppc": return ARM64.pacibsp
        case "paciasppc", "pacnbiasppc": return ARM64.paciasp
        case "retabsppc", "retabsppcr": return ARM64.retab
        case "retaasppc", "retaasppcr": return ARM64.retaa
        case "autibsppc", "autibsppcr": return ARM64.autibsp
        case "autiasppc", "autiasppcr": return ARM64.autiasp
        case "autia171615": return ARM64.autia1716
        case "autib171615": return ARM64.autib1716
        case "addpt", "subpt":
            guard ops.count == 3, ops.allSatisfy({ $0.type == .register }),
                  let rd = register(ops[0].reg, allowSP: true),
                  let rn = register(ops[1].reg, allowSP: true),
                  let rm = register(ops[2].reg, allowSP: false),
                  [.none, .lsl].contains(ops[2].shift.type), ops[2].shift.amount <= 7
            else { throw Failure("unsupported scalar \(name) operands at \(instruction.address)") }
            let shift = ops[2].shift.amount
            let replacement = rd == 31 || rn == 31
                ? ARM64Encoder.encodeAddSubXExtended(subtract: name == "subpt", rd: rd, rn: rn, rm: rm, shift: shift)
                : ARM64Encoder.encodeAddSubXShifted(subtract: name == "subpt", rd: rd, rn: rn, rm: rm, shift: shift)
            guard let replacement else { throw Failure("unencodable \(name) at \(instruction.address)") }
            return replacement
        case "maddpt", "msubpt":
            guard ops.count == 4, ops.allSatisfy({ $0.type == .register }),
                  let rd = register(ops[0].reg, allowSP: false), let rn = register(ops[1].reg, allowSP: false),
                  let rm = register(ops[2].reg, allowSP: false), let ra = register(ops[3].reg, allowSP: false),
                  let replacement = ARM64Encoder.encodeMaddSubX(subtract: name == "msubpt", rd: rd, rn: rn, rm: rm, ra: ra)
            else { throw Failure("unsupported scalar \(name) at \(instruction.address)") }
            return replacement
        case "madpt", "mlapt", "pacib171615", "pacia171615":
            throw Failure("X1 compatibility does not lower \(name) at \(instruction.address)")
        default: return nil
        }
    }

    private static func register(_ register: ARM64Register, allowSP: Bool) -> UInt32? {
        if allowSP && register == .sp || !allowSP && register == .xzr { return 31 }
        return (0 ... 30).first(where: { ARM64Register.x($0) == register }).map(UInt32.init)
    }
}
