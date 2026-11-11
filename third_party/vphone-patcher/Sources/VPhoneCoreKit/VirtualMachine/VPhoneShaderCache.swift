#if os(macOS) // MONOLITH: not built for iOS (the patchers do not use it)
import Darwin
import Foundation

/// Durable host GPU cache in the machine folder. Apple's sandboxed services
/// use a working copy in their Darwin cache directory; no paths are redirected.
public enum VPhoneShaderCache {
    private static let ecidFile = ".host-ecid"

    /// Hold the ECID lock until device teardown. A second launch must never
    /// replace the working directory while an existing VM is using it.
    public final class Session: Sendable {
        public let cacheURL: URL
        private let workingURL: URL
        private let descriptor: Int32

        fileprivate init(cacheURL: URL, workingURL: URL, descriptor: Int32) {
            self.cacheURL = cacheURL
            self.workingURL = workingURL
            self.descriptor = descriptor
        }

        public func checkpoint() throws {
            try VPhoneShaderCache.checkpoint(machineDirectory: cacheURL.deletingLastPathComponent(), frameworkCache: workingURL)
        }

        deinit { close(descriptor) }
    }

    public static func prepare(machineDirectory: URL, ecid: UInt64) throws -> Session {
        try session(machineDirectory: machineDirectory, ecid: ecid, frameworkCache: frameworkCache(ecid: ecid))
    }

    static func session(machineDirectory: URL, ecid: UInt64, frameworkCache: URL) throws -> Session {
        let descriptor = try lock(frameworkCache)
        do {
            let cache = try prepare(machineDirectory: machineDirectory, ecid: ecid, frameworkCache: frameworkCache)
            return Session(cacheURL: cache, workingURL: frameworkCache, descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Also called by the parent CLI after vphone-vm exits, so its final copy
    /// includes writes completed while Virtualization tears down the devices.
    public static func checkpoint(machineDirectory: URL) throws {
        let cache = machineDirectory.appendingPathComponent("ShaderCache", isDirectory: true)
        guard try kind(cache) != nil else { return }
        guard try kind(cache) == S_IFDIR,
              let text = try? String(contentsOf: cache.appendingPathComponent(ecidFile), encoding: .utf8),
              let ecid = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw invalid("ShaderCache has no valid host ECID", at: cache) }
        let working = try frameworkCache(ecid: ecid)
        let descriptor = try lock(working)
        defer { close(descriptor) }
        try checkpoint(machineDirectory: machineDirectory, frameworkCache: working)
    }

    @discardableResult
    static func prepare(machineDirectory: URL, ecid: UInt64, frameworkCache: URL) throws -> URL {
        let fm = FileManager.default
        let cache = machineDirectory.appendingPathComponent("ShaderCache", isDirectory: true)
        let cacheKind = try kind(cache)
        guard cacheKind == nil || cacheKind == S_IFDIR else {
            throw invalid("ShaderCache must be a real directory", at: cache)
        }
        let hostKind = try kind(frameworkCache)
        guard hostKind == nil || hostKind == S_IFDIR else {
            throw invalid("The framework cache must be a real directory", at: frameworkCache)
        }
        if cacheKind == nil {
            // Import an unmanaged cache once. A managed working copy already
            // has this marker; a missing machine snapshot then means reset.
            let managed = try kind(frameworkCache.appendingPathComponent(ecidFile)) != nil
            if hostKind == S_IFDIR && !managed {
                try snapshot(from: frameworkCache, to: cache)
            } else {
                try fm.createDirectory(at: cache, withIntermediateDirectories: false)
            }
        }
        // Keep whole snapshots together. Never merge independently warmed
        // functions.list/functions.data files or rewrite per-program identities.
        try Data("\(ecid)\n".utf8).write(to: cache.appendingPathComponent(ecidFile), options: .atomic)
        try snapshot(from: cache, to: frameworkCache)
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return cache
    }

    static func checkpoint(machineDirectory: URL, frameworkCache: URL) throws {
        let cache = machineDirectory.appendingPathComponent("ShaderCache", isDirectory: true)
        // Respect deletion during a running session. The next prepare clears
        // the surviving managed working copy instead of importing it again.
        guard try kind(cache) != nil else { return }
        guard try kind(frameworkCache) != nil else { return }
        try snapshot(from: frameworkCache, to: cache)
    }

    /// Copy to a sibling first, then replace the complete directory. A failed
    /// copy leaves the prior snapshot intact. copyItem preserves symlinks as
    /// links; the permissions walker never follows them.
    private static func snapshot(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard try kind(source) == S_IFDIR else {
            throw invalid("Shader cache snapshot source must be a real directory", at: source)
        }
        let destinationKind = try kind(destination)
        guard destinationKind == nil || destinationKind == S_IFDIR else {
            throw invalid("Shader cache snapshot destination must be a real directory", at: destination)
        }
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".ShaderCache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: pending) }
        try fm.copyItem(at: source, to: pending)
        try VPhoneHostFilePermissions.makeAccessible(at: pending)
        if destinationKind == nil {
            try fm.moveItem(at: pending, to: destination)
        } else {
            _ = try fm.replaceItemAt(destination, withItemAt: pending, options: .usingNewMetadataOnly)
        }
    }

    private static func frameworkCache(ecid: UInt64) throws -> URL {
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 0 else { throw POSIXError(.ENOENT) }
        var path = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &path, length) == length else { throw POSIXError(.ENOENT) }
        let directory = String(decoding: path.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("com.apple.paravirtualizedgraphics-\(ecid)", isDirectory: true)
    }

    private static func lock(_ working: URL) throws -> Int32 {
        let url = working.appendingPathExtension("vphone-lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o777)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1
        else {
            close(descriptor)
            throw invalid("Shader cache lock must be a regular file with one link", at: url)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = CocoaError(.fileLocking, userInfo: [
                NSLocalizedDescriptionKey: "Shader cache is in use; stop the existing VM before launching it again",
                NSFilePathErrorKey: url.path,
            ])
            close(descriptor)
            throw error
        }
        guard fchmod(descriptor, 0o777) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func kind(_ url: URL) throws -> mode_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & S_IFMT
    }

    private static func invalid(_ message: String, at url: URL) -> CocoaError {
        CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: message, NSFilePathErrorKey: url.path])
    }
}


#endif // MONOLITH
