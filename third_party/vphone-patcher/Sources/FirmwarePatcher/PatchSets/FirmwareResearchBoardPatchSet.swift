// FirmwareResearchBoardPatchSet.swift — Manifest for the research board fallback.
//
// The guest boots the vphone600 device tree and SEP firmware, but only the
// 26.1–26.4 beta cloudOS releases carry a vphone600ap identity. Every other
// cloudOS ships the research board alone, vresearch101ap, and `fw prepare` then
// takes its components instead (`FirmwareManifest.generate`). The patches here
// turn those into what vphone600 would have been: the device tree
// (DeviceTreeResearchBoardConversion.swift), SEPD (SEPResearchBoardPatcher.swift)
// and the kernelcache (KernelCacheMixer.swift).
//
// Every shipped preset names this set. On a cloudOS with vphone600 components
// its patches are not applicable (`FirmwarePipeline.resolveFirmwareApplicability`)
// and write nothing, so the fallback costs the other presets nothing and needs
// no version gate. They are boot-essential where they apply.

import Foundation
import VPhonePatchKit

public enum FirmwareResearchBoardPatchSet {
    public static let identifier = "com.vphone.patchset.research.board"

    /// The research board's device tree, rewritten as the vphone600 one.
    public static let deviceTreeConversion = "devicetree-boot-vresearch101_conversion"
    /// The research board's SEPD, answering one operation as vphone600's does.
    public static let sepDispatch = "sep-boot-vresearch101_sepd_dispatch"
    /// The research board's kernelcache, rebuilt with the iPhone virtualisation kexts.
    public static let kernelMix = "kernel-boot-vresearch101_kext_mix"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Research Board",
        summary: "Converts a cloudOS without vphone600 components from the research board",
        patches: [
            VPhonePatchDeclaration(
                identifier: deviceTreeConversion,
                title: "vphone600 device tree",
                summary: "Gives the research board's device tree the vphone600 identity, product properties and nodes, so a cloudOS without vphone600ap boots an iPhone userland. Runs before every other device tree patch.",
                target: .firmware(.deviceTree),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: kernelMix,
                title: "Virtualisation kexts",
                summary: "Rebuilds the research board's kernelcache with the paravirtual GPU, touch, audio and other iPhone virtualisation kexts of the 26.4 beta vphone600 kernelcache, from a recipe for that release. Extracts the KDK natively; linking it with kmutil needs root.",
                target: .firmware(.kernelcache),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: sepDispatch,
                title: "vphone600 SEPD dispatch",
                summary: "Sends SEPD operation 0x31 to the handler vphone600's SEP uses for it, and recomputes the FIPS HMAC the change invalidates.",
                target: .firmware(.sep),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.research.board"],
    )
}
