// MONOLITH: a restored device's system customised after the restore, sealed again.
//
// For guests whose kernel stays stock (the watch), the seal must hold. The VM is restored from the stock
// image; this writes vphone's restore-image additions into Disk.img's System volume, patches the dyld
// shared cache where they need it, seals the volume again with Monolith's own APFS code, and puts the new
// root hash and a static trust cache listing the added code into Preboot, where the patched iBoot stages
// read them.
import FirmwarePatcher
import Foundation
import VPhoneCoreKit

public enum MonolithRestoredSystem {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The additions a watch gets (vphone's watchos preset, restore image part).
    public static let watchAdditions: Set<String> = [
        FirmwareRestoreImagePatchSet.gpuDriver,
        FirmwareRestoreImagePatchSet.mobileActivation,
        FirmwareRestoreImagePatchSet.vphoned,
        FirmwareRestoreImagePatchSet.virtualBluetooth,
        FirmwareRestoreImagePatchSet.watchAudio,
    ]

    public static func install(vm: URL, additions: Set<String> = watchAdditions) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: vm.path)
        guard let tree = names.filter({ $0.hasSuffix("_Restore") }).sorted().last.map({ vm.appendingPathComponent($0) }) else {
            throw Failure(description: "No prepared restore tree in \(vm.lastPathComponent).")
        }
        let manifest = try Data(contentsOf: tree.appendingPathComponent("BuildManifest.plist"))
        let patcher = CryptexFilesystemPatcher(buildManiest: manifest, restoreDir: tree)

        let image = try VPhoneAPFSImage(vm.appendingPathComponent("Disk.img"), writable: true)
        print("[monolith] reading the restored seal…")
        let oldRoot = try image.sealedRootHash(volume: "System")
        let system = try image.volume(named: "System")

        let added = try patcher.applyOntoRestoredSystem(system, enabled: additions)
        print("[monolith] \(added.count) cdhash(es) for the static trust cache")

        if additions.contains(FirmwareRestoreImagePatchSet.watchAudio) {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("monolith-dyld-\(UUID().uuidString)")
            let dyld = try MonolithDisk.materialize(try system.directory("System/Library/Caches/com.apple.dyld"), into: work)
            do {
                let cache = try DyldSharedCacheChunkSet(directory: work, architecture: "arm64e")
                _ = try CustomFirmwareWatchAudioBudget.patchCache(in: cache)
                try dyld.writeBack()
            } catch {
                try? FileManager.default.removeItem(at: work)
                print("  [!] watch audio budget not applied: \(error)")
            }
        }

        print("[monolith] sealing System again…")
        let newRoot = try image.reseal(volume: "System")
        print("[monolith] root hash \(oldRoot.hex) -> \(newRoot.hex)")

        let preboot = try image.volume(named: "Preboot")
        var updated = 0
        for name in try preboot.entries() where name.count >= 64 {
            let firmware = "\(name)/usr/standalone/firmware"
            guard try preboot.exists("\(firmware)/root_hash.img4") else { continue }
            let rootHash = "\(firmware)/root_hash.img4"
            try preboot.writeFile(rootHash, contents: CryptexFilesystemPatcher.rootHash(preboot.readData(rootHash), replacing: oldRoot, with: newRoot),
                                  mode: 0o644, owner: (0, 0))
            let trustCache = "\(firmware)/FUD/StaticTrustCache.img4"
            if try preboot.exists(trustCache) {
                try preboot.writeFile(trustCache, contents: patcher.staticTrustCache(preboot.readData(trustCache), adding: added),
                                      mode: 0o644, owner: (0, 0))
            }
            updated += 1
        }
        guard updated > 0 else { throw Failure(description: "No boot root_hash in Preboot to give the new seal.") }
        try image.commit()
        // iBoot boots the snapshot named after the root hash it is given; the restore's names the old one.
        // Set aside, the live volume boots, which the kernel checks against the new root hash.
        try VPhoneAPFSSnapshot.rename(imageAt: vm.appendingPathComponent("Disk.img"))
        print("[monolith] System sealed again; Preboot updated (\(updated))")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
