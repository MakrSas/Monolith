import Foundation

// MARK: - VPhoneBootROM

/// The boot ROM a machine starts from: the file `romImages.avpBooter` names.
///
/// New machines run OpenAVB, an open-source ROM compatible with AVPBooter that
/// ships in `VPhone.bundle/Contents/Resources/OpenAVB/`. Machines created
/// before it keep Apple's `AVPBooter.vresearch1.bin`, which `fw patch` patches
/// to skip the image digest check. OpenAVB has no such check, so it needs no
/// patch; instead, before iBSS goes over DFU, the restore uploads the image's
/// sizes and digests (see `Research/Firmware/openavb_boot_rom.md`).
public enum VPhoneBootROM: String, CaseIterable, Sendable {
    case openAVB = "openavb"
    case apple

    /// The file name a machine folder keeps this ROM under.
    public var fileName: String {
        switch self {
        case .openAVB: "OpenAVB.bin"
        case .apple: "AVPBooter.vresearch1.bin"
        }
    }

    public var displayName: String {
        switch self {
        case .openAVB: "OpenAVB"
        case .apple: "AVPBooter"
        }
    }

    // MARK: - Recognition

    /// The prefix of every OpenAVB console line. OpenAVB keeps it from the
    /// project's former name so the image and host tooling stay unchanged,
    /// and Apple's ROM does not contain it.
    static let openAVBMarker = Data("OpenBootROM:".utf8)

    /// Which ROM these bytes are. Anything that is not OpenAVB is treated as
    /// Apple's, which is what every ROM was before OpenAVB.
    public static func kind(of image: Data) -> VPhoneBootROM {
        image.range(of: openAVBMarker) != nil ? .openAVB : .apple
    }

    /// The ROM at `url`, or nil when it cannot be read.
    public static func kind(at url: URL) -> VPhoneBootROM? {
        guard let image = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return kind(of: image)
    }

    /// The ROM a machine folder boots: what its manifest names, or nil when
    /// the manifest names none (vphone-vm then uses the framework's built-in
    /// ROM) or the file cannot be read.
    public static func kind(ofMachineAt url: URL) -> VPhoneBootROM? {
        guard let manifest = try? VPhoneVirtualMachineManifest.load(from: url.appendingPathComponent("config.plist")),
              let name = manifest.romImages?.avpBooter,
              VPhoneVirtualMachineManifest.isPlainFileName(name)
        else { return nil }
        return kind(at: url.appendingPathComponent(name))
    }

    // MARK: - Sources

    /// Apple's ROM, from Virtualization.framework.
    public static let appleSource = URL(fileURLWithPath:
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin")

    /// The OpenAVB image in this bundle's resources. A source build outside the
    /// bundle reads the checked-in copy.
    public static func openAVBSource(resources: VPhoneResources = .resolve()) -> URL {
        let bundled = resources.base.appendingPathComponent("OpenAVB/OpenAVB.bin")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return resources.base.appendingPathComponent(
            "VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/OpenAVB.bin")
    }

    /// Where `vm new` copies this ROM from.
    public func source(resources: VPhoneResources = .resolve()) -> URL {
        switch self {
        case .openAVB: Self.openAVBSource(resources: resources)
        case .apple: Self.appleSource
        }
    }
}

