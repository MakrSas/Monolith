// MONOLITH: the restore image's guest additions made after the restore instead of before it.
//
// vphone builds a watch's system image on a Mac (mount, patch, mtree, apfs_sealvolume) and restores that.
// Monolith restores the stock image, which the device seals as Apple's, then writes the same additions
// into the restored System volume of Disk.img with its own APFS code, seals the volume again
// (VPhoneAPFSImage.reseal) and gives the boot chain the new root hash and a static trust cache that
// lists what was added. The patched iBoot stages load both without checking their manifest.

import Foundation
import Img4tool
import VPhoneCoreKit
import VPhonePatchKit

public extension CryptexFilesystemPatcher {
    /// Writes the enabled additions (FirmwareRestoreImagePatchSet ids) into `system`, a restored System
    /// volume. The dyld shared cache patch (watch audio budget) is the caller's: it needs the cache as
    /// files. Returns the cdhashes the static trust cache must list for what changed.
    func applyOntoRestoredSystem(_ system: VPhoneConfinedDirectory, enabled: Set<String>) throws -> [Data] {
        let mount = "/monolith-restored-system-\(UUID().uuidString)"
        VPhoneConfinedDirectory.monolithMounts[mount] = system
        defer { VPhoneConfinedDirectory.monolithMounts[mount] = nil }
        var machOs: [String] = []
        var signatures: [String] = []
        func on(_ id: String) -> Bool { enabled.contains(id) && applies(id) }

        if on(FirmwareRestoreImagePatchSet.gpuDriver) {
            print("- Adding the GPU driver…")
            try addGpuDriver(targetMount: mount)
            let bundle = "System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
            machOs += ["\(bundle)/AppleParavirtGPUMetalIOGPUFamily", "\(bundle)/libAppleParavirtCompilerPluginIOGPUFamily.dylib"]
        }
        if on(FirmwareRestoreImagePatchSet.mobileActivation) {
            print("- Patching mobile activation…")
            try patchMobileActivation(targetMount: mount)
            machOs.append("usr/libexec/mobileactivationd")
        }
        if on(FirmwareRestoreImagePatchSet.vphoned) {
            print("- Adding vphoned…")
            try addVphoned(targetMount: mount)
            try injectLaunchDaemons(targetMount: mount)
            machOs.append("usr/bin/vphoned")
            if try system.exists("usr/lib/vphone/libswiftCompatibilitySpan.dylib") {
                machOs.append("usr/lib/vphone/libswiftCompatibilitySpan.dylib")
            }
            signatures.append(CustomFirmwareDetachedSignature.launchdCacheSignaturePath)
        }
        if on(FirmwareRestoreImagePatchSet.launchdCacheLoader) {
            try patchLaunchdCacheLoader(targetMount: mount)
            machOs.append("usr/libexec/launchd_cache_loader")
        }
        if on(FirmwareRestoreImagePatchSet.virtualBluetooth) {
            try editGuestFile(CustomFirmwareBluetoothVirtualController.relativePath, targetMount: mount, mode: 0o644) { file in
                try CustomFirmwareBluetoothVirtualController.patch(at: file)
            }
            print("  [+] \(CustomFirmwareBluetoothVirtualController.feature) on")
        }
        if on(FirmwareRestoreImagePatchSet.watchAudio) {
            print("- Adding the watch speaker…")
            try addWatchAudio(targetMount: mount)
            machOs += ["System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver/VPhoneVirtIOSound",
                       "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"]
        }
        if on(FirmwareRestoreImagePatchSet.debugserver) {
            try patchDebugserver(targetMount: mount)
        }
        if on(FirmwareRestoreImagePatchSet.launchdJetsam) {
            try patchLaunchdJetsam(targetMount: mount)
            machOs.append("sbin/launchd")
        }

        var hashes: [Data] = []
        for path in machOs where try system.exists(path) {
            hashes += TrustCache.cdHashes(ofMachO: try system.readData(path))
        }
        for path in signatures where try system.exists(path) {
            hashes += try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: system.readData(path)).map { $0.cdhash }
        }
        var seen = Set<Data>()
        return hashes.filter { seen.insert($0).inserted }
    }

    /// The Preboot static trust cache (an IMG4) with `adding` listed too: sorted as the kernel searches
    /// it, re-signed binaries in the launch-constraint category their originals had.
    func staticTrustCache(_ prebootIMG4: Data, adding: [Data]) throws -> Data {
        let container = try CustomFirmwarePostRestoreDeviceTree.Container(prebootIMG4)
        let im4p = try IM4P(container.im4pBytes)
        let original = try TrustCache(payload: im4p.payload())
        var entries = original.entries
        let have = Set(entries.map(\.cdHash))
        let hashType = entries.first?.hashType ?? 2
        for hash in adding where !have.contains(hash) {
            entries.append(.init(cdHash: hash, hashType: hashType, flags: 0))
        }
        entries.sort { $0.cdHash.lexicographicallyPrecedes($1.cdHash) }
        let cache = TrustCache(version: max(original.version, 2), uuid: original.uuid, entries: entries)
            .withConstraintCategories(from: [original], inherited: resignedCDHashes)
        let payload = try IM4P(fourcc: im4p.fourcc, description: im4p.description, payload: cache.payload).data
        return try CustomFirmwarePostRestoreDeviceTree.firmwareReplacingPayload(
            prebootIMG4: prebootIMG4, patchedComponent: payload, expectedFourcc: im4p.fourcc,
        ) ?? prebootIMG4
    }

    /// The Preboot root_hash (an IMG4 holding an isys) naming `newHash` where it named `oldHash`.
    static func rootHash(_ prebootIMG4: Data, replacing oldHash: Data, with newHash: Data) throws -> Data {
        let container = try CustomFirmwarePostRestoreDeviceTree.Container(prebootIMG4)
        let im4p = try IM4P(container.im4pBytes)
        var payload = try im4p.payload()
        guard im4p.fourcc == "isys", let range = payload.range(of: oldHash) else {
            throw PatcherError.invalidFormat("the Preboot root_hash does not hold the volume's root hash")
        }
        payload.replaceSubrange(range, with: newHash)
        let rebuilt = try IM4P(fourcc: im4p.fourcc, description: im4p.description, payload: payload).data
        return try CustomFirmwarePostRestoreDeviceTree.firmwareReplacingPayload(
            prebootIMG4: prebootIMG4, patchedComponent: rebuilt, expectedFourcc: "isys",
        ) ?? prebootIMG4
    }
}
