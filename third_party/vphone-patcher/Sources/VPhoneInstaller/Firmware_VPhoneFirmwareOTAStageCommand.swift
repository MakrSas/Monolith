import ArgumentParser
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit
import FirmwarePatcher // MONOLITH: was VPhoneRestore, for the restore tree only

/// Stage a full OTA for the opt-in, host-driven System-volume update.
/// This command never runs a restore or writes Disk.img / SEPStorage.
struct VPhoneFirmwareOTAStageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ota-stage",
        abstract: "Stage a full OTA for an experimental data-preserving system update",
        discussion: """
        Stop the VM and take a disk/SEP/NVRAM snapshot first. Prepare and patch the
        target firmware, then stage its full OTA here. Allow system-exp-ota_userland
        and run cfw install, which updates System, kernel and TXM together. Never run restore
        on the installed guest: that erases its data. This is an experimental
        offline OTA payload install, not Apple's softwareupdated protocol.
        """
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "Stopped VM name") var name: String
    @Option(help: "Local full OTA (.aea or decrypted Apple Archive)", transform: URL.init(fileURLWithPath:))
    var source: URL?
    @Option(help: "AEA symmetric key in base64") var key: String?
    @Option(help: "Expected target build, e.g. 24A446") var build: String
    @Flag(help: "Only verify the paths in an already staged payload; do not stage or install it") var verifyStaged = false

    func run() throws {
        let bundle = try lib.library.bundle(named: name)
        try VPhoneBundleActivity.requireStopped(bundle)
        guard let device = VPhoneGuestDevice.named(bundle.manifest.guestProductType ?? ""),
              device.family == .iPad || device.family == .iPhone else {
            throw ValidationError("ota-stage needs a configured iPhone or iPad guest.")
        }
        let fm = FileManager.default
        // The same single iPhone*_Restore tree `restore` and `cfw install` use.
        let tree = try FirmwarePipeline(vmDirectory: bundle.url).findRestoreDirectory() // MONOLITH
        guard let manifest = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: tree.appendingPathComponent("iPhone-BuildManifest.plist")), format: nil
        ) as? [String: Any], manifest["ProductBuildVersion"] as? String == build else {
            throw ValidationError("The prepared target IPSW restore tree does not match --build. Prepare the target before staging the OTA.")
        }
        guard (try VPhoneMachineSnapshots.list(of: bundle)).isEmpty == false else {
            throw ValidationError("Take a stopped VM snapshot first; Disk.img, SEPStorage and NVRAM must roll back together.")
        }
        let userland = bundle.url.appendingPathComponent(VPhoneOTAArchive.userlandDirectoryName)
        if verifyStaged {
            let chunks = try fm.contentsOfDirectory(at: userland, includingPropertiesForKeys: nil)
                .filter { VPhoneOTAArchive.isChunkName($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !chunks.isEmpty else { throw ValidationError("No OTA payload is staged.") }
            let links = try Data(contentsOf: userland.appendingPathComponent(VPhoneOTAArchive.hardLinkListName))
            try VPhoneOTAArchive.validatePayloadPaths(chunks, hardLinks: links)
            print("[+] Verified payload paths across \(chunks.count) staged chunks; guest disk untouched.")
            return
        }
        guard let source else { throw ValidationError("--source is required unless --verify-staged is used.") }
        let flash = tree.appendingPathComponent("Firmware/all_flash")
        let staged = try VPhoneOTAArchive.stageUserland(
            from: source, key: key, device: device, build: build,
            deviceTreeDirectory: flash, userlandDirectory: userland,
            requireFullUpdate: true,
            progress: { print("[ota] \($0)") }
        )
        let metadata: [String: String] = [
            "Device": device.productType, "Version": staged.version, "Build": staged.build,
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: userland.appendingPathComponent("Upgrade.plist"), options: .atomic)
        print("[+] Full OTA staged: \(staged.version) (\(staged.build)), \(staged.chunks.count) payload chunks. Guest disk untouched.")
    }
}
