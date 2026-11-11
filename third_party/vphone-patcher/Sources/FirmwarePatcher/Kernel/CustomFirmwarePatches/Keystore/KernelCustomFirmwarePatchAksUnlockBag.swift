// KernelCustomFirmwarePatchAksUnlockBag.swift — CFW kernel patch: let the
// AppleSEPKeyStore keybag-unlock handler accept iOS 27's 5-scalar call.
//
// An iOS 26.6-or-newer userland's keybag unlock always sends inputScalarCount == 5
// (scalars[3] = flags & 1, scalars[4] = flags) — 26.5 and earlier send 4 — but the
// 26.4-kernel handler accepts only 3 or 4:
//
//     bti  j
//     ldr  w8, [x19, #0x28]      ; scalarInputCount
//     cmp  w8, #3 ; b.eq <count3>
//     cmp  w8, #4 ; b.ne <BadArgument>
//     ldr  w8, [x19, #0x50]      ; structureInputCount
//     cbnz w8, <BadArgument>
//     ldr  x8, [x19, #0x20]      ; scalars
//     ldr  x9, [x8, #0x18]       ; scalars[3]
//     cmp  x9, #0 ; cset w25, ne ; b <join>
//
// so every iOS 27 unlock returns kIOReturnBadArgument and escrow-bag unlock (what
// `backup2 encryption` needs) fails. The count-4 path reads only scalars[3], which
// iOS 27 fills with the same flag bit, so a count of 5 is routed to it unchanged.
//
// The `cmp w8, #4` is redirected into a cave that accepts 4 or 5 (both to the
// original count-4 path) and otherwise branches to the handler's own BadArgument.
//
// Anchor: the 13-word count-dispatch block, matched by its fixed words with the
// four branch words masked (opcode + condition kept, imm wildcarded). The
// BadArgument and count-4 targets are read from the anchor's own branches, so no
// absolute offset is baked in. The `cset w25, ne` word is part of the fixed match
// and is what makes the block unique among the keystore handlers that share this
// 3/4-count preamble — see the review note in the commit that introduced this.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// (mask, value) per anchor word, in VA order from the handler's `bti j`.
    /// 0xFFFFFFFF pins the word; 0xFF00001F keeps a b.cond/cbnz opcode and
    /// condition while wildcarding imm19; 0xFC000000 keeps a `b` opcode.
    private static let aksAnchor: [(mask: UInt32, value: UInt32)] = [
        (0xFFFF_FFFF, 0xD503_249F), // 0  bti j
        (0xFFFF_FFFF, 0xB940_2A68), // 1  ldr w8,[x19,#0x28]  (scalarInputCount)
        (0xFFFF_FFFF, 0x7100_0D1F), // 2  cmp w8,#3
        (0xFF00_001F, 0x5400_0000), // 3  b.eq <count3>
        (0xFFFF_FFFF, 0x7100_111F), // 4  cmp w8,#4            (redirect site)
        (0xFF00_001F, 0x5400_0001), // 5  b.ne <BadArgument>
        (0xFFFF_FFFF, 0xB940_5268), // 6  ldr w8,[x19,#0x50]  (structInputCount)
        (0xFF00_001F, 0x3500_0008), // 7  cbnz w8,<BadArgument>
        (0xFFFF_FFFF, 0xF940_1268), // 8  ldr x8,[x19,#0x20]  (scalars)
        (0xFFFF_FFFF, 0xF940_0D09), // 9  ldr x9,[x8,#0x18]   (scalars[3])
        (0xFFFF_FFFF, 0xF100_013F), // 10 cmp x9,#0
        (0xFFFF_FFFF, 0x1A9F_07F9), // 11 cset w25,ne
        (0xFC00_0000, 0x1400_0000), // 12 b <join>
    ]

    @discardableResult
    func patchAksUnlockBagCount5() -> Bool {
        log("\n[CFW]AppleSEPKeyStore aks_unlock_bag: accept scalarInputCount 5 (iOS 26.6+ userland)")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }

        var hits: [Int] = []
        var off = ks
        while off + Self.aksAnchor.count * 4 <= ke {
            if anchorMatches(at: off) {
                hits.append(off)
            }
            off += 4
        }
        guard hits.count == 1 else {
            log("  [-] count-dispatch anchor not found uniquely (\(hits.count))")
            return false
        }
        let anchor = hits[0]

        let site = anchor + 0x10 // cmp w8,#4
        let count4 = anchor + 0x18 // count-4 path entry (ldr w8,[x19,#0x50])
        guard let (bad, _) = jbDecodeBranchTarget(at: anchor + 0x14), // b.ne <BadArgument>
              let (cbnzBad, _) = jbDecodeBranchTarget(at: anchor + 0x1C), // cbnz w8,<BadArgument>
              bad == cbnzBad
        else {
            log("  [-] could not decode BadArgument target")
            return false
        }

        guard let cave = findCodeCave(size: 24) else {
            log("  [-] no code cave")
            return false
        }

        // site/cave/count4/bad are all in __TEXT_EXEC, so a branch delta computed
        // in file-offset space equals the VA-space delta. Replacement bytes come
        // from the keystone-verified ARM64Encoder helpers; Lok = cave + 0x14.
        let lok = cave + 0x14
        guard let cmp4 = ARM64Encoder.encodeCmpWImmediate(rn: 8, imm12: 4),
              let eq4 = ARM64Encoder.encodeBCond(from: cave + 0x04, to: lok, condition: .eq),
              let cmp5 = ARM64Encoder.encodeCmpWImmediate(rn: 8, imm12: 5),
              let eq5 = ARM64Encoder.encodeBCond(from: cave + 0x0C, to: lok, condition: .eq),
              let bBad = ARM64Encoder.encodeB(from: cave + 0x10, to: bad),
              let bCount4 = ARM64Encoder.encodeB(from: lok, to: count4),
              let redirect = ARM64Encoder.encodeB(from: site, to: cave)
        else {
            log("  [-] branch encoding failed")
            return false
        }

        emit(
            site,
            redirect,
            patchID: "kernel-cfw-aks_unlock_bag.redirect",
            virtualAddress: fileOffsetToVA(site),
            description: "cmp w8,#4 -> b cave [aks_unlock_bag accept scalarInputCount 5]",
        )
        emit(
            cave,
            cmp4 + eq4 + cmp5 + eq5 + bBad + bCount4,
            patchID: "kernel-cfw-aks_unlock_bag.cave",
            virtualAddress: fileOffsetToVA(cave),
            description: "scalarInputCount 4 or 5 -> count-4 path, else BadArgument",
        )
        return true
    }

    // MARK: - Private helpers

    private func anchorMatches(at off: Int) -> Bool {
        for (i, w) in Self.aksAnchor.enumerated() where (buffer.readU32(at: off + i * 4) & w.mask) != w.value {
            return false
        }
        return true
    }
}
