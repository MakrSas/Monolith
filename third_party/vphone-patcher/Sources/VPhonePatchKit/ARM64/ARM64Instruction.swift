// ARM64Instruction.swift — PatchKit's decoded-instruction model.
//
// Patches match on these types, never on a disassembler's own. The fields are
// the ones the patchers read: mnemonic and operand text for logs and anchors,
// and typed operands for every semantic check. ARM64Disassembler fills them.

import Foundation

public struct ARM64Instruction: Sendable, CustomStringConvertible {
    /// False for bytes the disassembler skipped as data.
    public let isDecoded: Bool
    public let address: UInt64
    public let size: UInt16
    public let bytes: [UInt8]
    public let mnemonic: String
    public let operandString: String
    /// Operand detail; nil only when the disassembler produced none.
    public let detail: ARM64InstructionDetail?
    public let isJump: Bool
    public let isCall: Bool
    public let isReturn: Bool

    public init(
        isDecoded: Bool,
        address: UInt64,
        size: UInt16,
        bytes: [UInt8],
        mnemonic: String,
        operandString: String,
        detail: ARM64InstructionDetail?,
        isJump: Bool,
        isCall: Bool,
        isReturn: Bool,
    ) {
        self.isDecoded = isDecoded
        self.address = address
        self.size = size
        self.bytes = bytes
        self.mnemonic = mnemonic
        self.operandString = operandString
        self.detail = detail
        self.isJump = isJump
        self.isCall = isCall
        self.isReturn = isReturn
    }

    public var description: String {
        let addr = String(format: "0x%llx", address)
        if operandString.isEmpty {
            return "\(addr): \(mnemonic)"
        }
        return "\(addr): \(mnemonic) \(operandString)"
    }
}

public struct ARM64InstructionDetail: Sendable {
    /// The condition a conditional instruction tests; nil when it tests none.
    public let conditionCode: ARM64Condition?
    public let updatesFlags: Bool
    public let postIndex: Bool
    public let operands: [ARM64Operand]
    public internal(set) var writeback = false

    public init(conditionCode: ARM64Condition?, updatesFlags: Bool, postIndex: Bool, operands: [ARM64Operand]) {
        self.conditionCode = conditionCode
        self.updatesFlags = updatesFlags
        self.postIndex = postIndex
        self.operands = operands
    }
}

public enum ARM64OperandType: Sendable {
    case register
    case immediate
    case memory
    case other
}

public struct ARM64Operand: Sendable {
    public let type: ARM64OperandType
    /// Meaningful when `type` is `.register`.
    public let reg: ARM64Register
    /// Meaningful when `type` is `.immediate`.
    public let imm: Int64
    /// Meaningful when `type` is `.memory`.
    public let mem: ARM64MemoryOperand
    public let shift: ARM64OperandShift
    public internal(set) var writesRegister = false

    // Keep the original initializer's symbol for already-built patch bundles.
    public init(type: ARM64OperandType, reg: ARM64Register, imm: Int64, mem: ARM64MemoryOperand) {
        self.init(type: type, reg: reg, imm: imm, mem: mem, shift: .init(type: .none, amount: 0))
    }

    public init(type: ARM64OperandType, reg: ARM64Register, imm: Int64, mem: ARM64MemoryOperand, shift: ARM64OperandShift) {
        self.type = type
        self.reg = reg
        self.imm = imm
        self.mem = mem
        self.shift = shift
    }
}

public enum ARM64ShiftType: UInt32, Sendable {
    case none = 0, lsl = 1, msl = 2, lsr = 3, asr = 4, ror = 5
    case unsupported = 0xFFFF_FFFF
}

public struct ARM64OperandShift: Sendable {
    public let type: ARM64ShiftType
    public let amount: UInt32

    public init(type: ARM64ShiftType, amount: UInt32) {
        self.type = type
        self.amount = amount
    }
}

public struct ARM64MemoryOperand: Sendable, Hashable {
    public let base: ARM64Register
    /// `.invalid` when the address has no index register.
    public let index: ARM64Register
    public let disp: Int32

    public init(base: ARM64Register, index: ARM64Register, disp: Int32) {
        self.base = base
        self.index = index
        self.disp = disp
    }
}

/// A register as the disassembler identifies it. The raw value is an opaque
/// identifier, stable within one PatchKit build: compare registers, use them as
/// keys, and build known ones with `x(_:)`, `w(_:)` and the named constants.
public struct ARM64Register: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String {
        name ?? "reg#\(rawValue)"
    }
}
