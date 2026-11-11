import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// Change the native tunable's initial data, not its callers or protection
    /// checks. The descriptor and startup registration follow kern/startup.h.
    /// Kernel-cache rebase targets are image-relative; next/PAC bits stay intact.
    @discardableResult
    func patchTVTPROPagers() -> Bool {
        guard let offset = Self.tvTPROPagersDefault(in: buffer.data, segments: segments) else {
            log("  [-] sprr_tpro_pagers tunable not uniquely validated")
            return false
        }
        let old = buffer.readU32(at: offset)
        log("  [.] sprr_tpro_pagers default at 0x\(String(offset, radix: 16)): \(old) -> 0")
        emit(offset, Data(repeating: 0, count: 4),
             patchID: FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers,
             virtualAddress: fileOffsetToVA(offset),
             description: "sprr_tpro_pagers integer tunable default \(old) -> 0 (data)")
        return true
    }

    static func tvTPROPagersDefault(in data: Data, segments: [MachOSegmentInfo]) -> Int? {
        guard data.count >= 24 else { return nil }
        let name = Data("sprr_tpro_pagers\0".utf8)
        guard let nameRange = data.range(of: name),
              data.range(of: name, in: nameRange.upperBound..<data.count) == nil,
              nameRange.lowerBound == 0 || data[nameRange.lowerBound - 1] == 0
        else { return nil }

        func word(_ offset: Int) -> UInt64 { data.loadLE(UInt64.self, at: offset) }
        func target(_ raw: UInt64) -> Int? {
            // DYLD_CHAINED_PTR_64_KERNEL_CACHE: target:30, cacheLevel:2,
            // diversity:16, addrDiv:1, key:2, next:12, isAuth:1.
            guard raw & 0xC000_0000 == 0 else { return nil }
            let value = Int(raw & 0x3FFF_FFFF)
            return value < data.count ? value : nil
        }
        func contains(_ offset: Int, count: Int, names: Set<String>) -> Bool {
            segments.contains { segment in
                names.contains(segment.name) && UInt64(offset) >= segment.fileOffset &&
                    UInt64(offset) - segment.fileOffset <= segment.fileSize &&
                    UInt64(count) <= segment.fileSize - (UInt64(offset) - segment.fileOffset)
            }
        }
        // Fileset outer __DATA contains the embedded kernel's __KLDDATA.
        guard contains(nameRange.lowerBound, count: name.count, names: ["__KLDDATA", "__DATA"]) else { return nil }
        var candidates: [Int] = []
        for descriptor in stride(from: 0, through: data.count - 24, by: 8) {
            guard target(word(descriptor)) == nameRange.lowerBound,
                  // Integer, four bytes, neither bool nor string.
                  word(descriptor + 16) == 4,
                  contains(descriptor, count: 24, names: ["__KLDDATA", "__DATA"]),
                  let variable = target(word(descriptor + 8)), variable % 4 == 0,
                  variable <= data.count - MemoryLayout<UInt32>.size,
                  contains(variable, count: 4, names: ["__DATA", "__DATA_CONST"]),
                  data.loadLE(UInt32.self, at: variable) <= 1
            else { continue }
            // A real STARTUP_SUB_TUNABLES registration must point at the spec
            // and an executable initializer. Reject stray descriptor-shaped data.
            let registrations = stride(from: 0, through: data.count - 24, by: 8).filter { entry in
                guard word(entry) == 1, target(word(entry + 16)) == descriptor,
                      let callback = target(word(entry + 8))
                else { return false }
                return contains(entry, count: 24, names: ["__KLDDATA", "__DATA"]) &&
                    contains(callback, count: 4, names: ["__TEXT_EXEC", "__TEXT_BOOT_EXEC"])
            }
            if registrations.count == 1 { candidates.append(variable) }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
