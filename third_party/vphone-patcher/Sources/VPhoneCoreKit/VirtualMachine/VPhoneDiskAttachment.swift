#if os(macOS) // MONOLITH: not built for iOS (the patchers do not use it)
import Foundation
import Virtualization

/// How `vphone-vm` attaches a disk image file to the guest.
public enum VPhoneDiskAttachment {
    /// Spelled out rather than left to `init(url:readOnly:)`, whose defaults
    /// are caching `.automatic` and synchronization `.full` (read back on
    /// macOS 27.0.1). With `.automatic` or `.uncached` on a sparse image, guest
    /// RAM came back zeroed in 2 MiB runs whenever the host compressor was
    /// compressing guest memory, at pressure level normal as well as warning
    /// and critical; a zeroed dirty page written back leaves a zero block in
    /// the image. `.cached` lost nothing under the same load. See
    /// Research/Host/disk_caching_mode.md.
    public static let cachingMode: VZDiskImageCachingMode = .cached

    /// `.full` keeps the guest's flushes reaching permanent storage, as the
    /// default did.
    public static let synchronizationMode: VZDiskImageSynchronizationMode = .full

    public static func make(url: URL, readOnly: Bool) throws -> VZDiskImageStorageDeviceAttachment {
        try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: readOnly,
            cachingMode: cachingMode,
            synchronizationMode: synchronizationMode,
        )
    }
}

#endif // MONOLITH
