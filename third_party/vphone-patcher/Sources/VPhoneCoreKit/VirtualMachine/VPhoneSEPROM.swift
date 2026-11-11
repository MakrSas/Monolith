import Foundation

// MARK: - VPhoneSEPROM

/// The SEP boot ROM a machine starts its SEP core from: the file
/// `romImages.avpSEPBooter` names.
///
/// New machines run OpenSEP, an open-source ROM compatible with AVPSEPBooter
/// that ships in `VPhone.bundle/Contents/Resources/OpenSEP/`. Machines created
/// before it keep Apple's `AVPSEPBooter.vresearch1.bin`. Neither is patched:
/// both load the personalised SEP firmware the restore sends and hand over to
/// it (see `Research/Firmware/opensep_sep_rom.md`).
public enum VPhoneSEPROM: String, CaseIterable, Sendable {
    case openSEP = "opensep"
    case apple

    /// The file name a machine folder keeps this ROM under.
    public var fileName: String {
        switch self {
        case .openSEP: "OpenSEP.bin"
        case .apple: "AVPSEPBooter.vresearch1.bin"
        }
    }

    public var displayName: String {
        switch self {
        case .openSEP: "OpenSEP"
        case .apple: "AVPSEPBooter"
        }
    }

    // MARK: - Recognition

    /// The version string Apple's SEP ROM carries (`AVPSEPBooter-9…` in the
    /// macOS 26 image). OpenSEP prints nothing and carries no string of its
    /// own, so the rule is the other way round from `VPhoneBootROM`: a ROM
    /// with Apple's version string is Apple's, and any other is OpenSEP.
    static let appleMarker = Data("AVPSEPBooter-".utf8)

    /// Which SEP ROM these bytes are.
    public static func kind(of image: Data) -> VPhoneSEPROM {
        image.range(of: appleMarker) != nil ? .apple : .openSEP
    }

    /// The SEP ROM at `url`, or nil when it cannot be read.
    public static func kind(at url: URL) -> VPhoneSEPROM? {
        guard let image = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return kind(of: image)
    }

    /// The SEP ROM a machine folder boots: what its manifest names, or nil
    /// when the manifest names none (vphone-vm then uses the framework's
    /// built-in ROM) or the file cannot be read.
    public static func kind(ofMachineAt url: URL) -> VPhoneSEPROM? {
        guard let manifest = try? VPhoneVirtualMachineManifest.load(from: url.appendingPathComponent("config.plist")),
              let name = manifest.romImages?.avpSEPBooter,
              VPhoneVirtualMachineManifest.isPlainFileName(name)
        else { return nil }
        return kind(at: url.appendingPathComponent(name))
    }

    // MARK: - Sources

    /// Apple's SEP ROM, from Virtualization.framework.
    public static let appleSource = URL(fileURLWithPath:
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPSEPBooter.vresearch1.bin")

    /// The OpenSEP image in this bundle's resources. A source build outside
    /// the bundle reads the checked-in copy.
    public static func openSEPSource(resources: VPhoneResources = .resolve()) -> URL {
        let bundled = resources.base.appendingPathComponent("OpenSEP/OpenSEP.bin")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return resources.base.appendingPathComponent(
            "VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/OpenSEP.bin")
    }

    /// Where `vm new` copies this ROM from.
    public func source(resources: VPhoneResources = .resolve()) -> URL {
        switch self {
        case .openSEP: Self.openSEPSource(resources: resources)
        case .apple: Self.appleSource
        }
    }
}


