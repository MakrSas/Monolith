import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCoreKit

// MARK: - --rom

/// `--rom` of `vm new` and `vm config`: `openavb`, `apple`, or a ROM file.
enum VPhoneBootROMOption {
    static var help: ArgumentHelp {
        "Boot ROM: openavb (the bundle's OpenAVB, the default for new machines), apple (Virtualization.framework's AVPBooter), or a ROM file"
    }

    /// What `vm new` copies into the new machine. An Apple ROM is patched by
    /// the `fw patch` that follows, as it always was.
    static func source(for argument: String?) -> URL {
        switch argument?.lowercased() {
        case nil, VPhoneBootROM.openAVB.rawValue: VPhoneBootROM.openAVBSource()
        case VPhoneBootROM.apple.rawValue: VPhoneBootROM.appleSource
        default: URL(fileURLWithPath: argument ?? "")
        }
    }

    /// Makes `argument` the boot ROM of an existing machine.
    ///
    /// `apple` takes the Apple ROM already in the folder when there is one: it
    /// carries the digest patch `fw patch` applied. Otherwise the framework's
    /// copy comes in and is patched here, because the machine's boot chain is
    /// resealed and an unpatched AVPBooter refuses it, and the restore tree
    /// `fw patch` needs is usually gone by now.
    static func install(_ argument: String, in bundle: VPhoneBundle) throws -> VPhoneBundle {
        guard argument.lowercased() == VPhoneBootROM.apple.rawValue else {
            return try VPhoneBundleOperations.installBootROM(from: source(for: argument), in: bundle)
        }
        let kept = bundle.url.appendingPathComponent(VPhoneBootROM.apple.fileName)
        if VPhoneBootROM.kind(at: kept) == .apple {
            return try VPhoneBundleOperations.installBootROM(from: kept, in: bundle)
        }
        let installed = try VPhoneBundleOperations.installBootROM(from: VPhoneBootROM.appleSource, in: bundle)
        let patcher = try AVPBooterPatcher(data: Data(contentsOf: kept), verbose: false)
        try patcher.apply()
        try patcher.patchedData.write(to: kept, options: .atomic)
        try VPhoneHostFilePermissions.makeAccessible(at: kept)
        return installed
    }

    /// `OpenAVB (OpenAVB.bin)`, for listings.
    static func describe(_ bundle: VPhoneBundle) -> String {
        guard let name = bundle.manifest.romImages?.avpBooter else {
            return "Virtualization.framework built-in"
        }
        let kind = VPhoneBootROM.kind(ofMachineAt: bundle.url)
        return "\(kind?.displayName ?? "unreadable") (\(name))"
    }
}

// MARK: - --seprom

/// `--seprom` of `vm new` and `vm config`: `opensep`, `apple`, or a ROM file.
enum VPhoneSEPROMOption {
    static var help: ArgumentHelp {
        "SEP ROM: opensep (the bundle's OpenSEP, the default for new machines), apple (Virtualization.framework's AVPSEPBooter), or a ROM file"
    }

    /// What `vm new` copies into the new machine.
    static func source(for argument: String?) -> URL {
        switch argument?.lowercased() {
        case nil, VPhoneSEPROM.openSEP.rawValue: VPhoneSEPROM.openSEPSource()
        case VPhoneSEPROM.apple.rawValue: VPhoneSEPROM.appleSource
        default: URL(fileURLWithPath: argument ?? "")
        }
    }

    /// Makes `argument` the SEP ROM of an existing machine. Neither ROM is
    /// patched, so `apple` is a fresh copy from the framework either way.
    static func install(_ argument: String, in bundle: VPhoneBundle) throws -> VPhoneBundle {
        try VPhoneBundleOperations.installSEPROM(from: source(for: argument), in: bundle)
    }

    /// `OpenSEP (OpenSEP.bin)`, for listings.
    static func describe(_ bundle: VPhoneBundle) -> String {
        guard let name = bundle.manifest.romImages?.avpSEPBooter else {
            return "Virtualization.framework built-in"
        }
        let kind = VPhoneSEPROM.kind(ofMachineAt: bundle.url)
        return "\(kind?.displayName ?? "unreadable") (\(name))"
    }
}
