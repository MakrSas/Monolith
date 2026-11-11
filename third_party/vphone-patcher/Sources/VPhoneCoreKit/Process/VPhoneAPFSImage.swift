// MONOLITH: a guest's APFS disk image opened with Monolith's own APFS code, for VPhoneConfinedDirectory
// where nothing can be mounted (iOS). Changes stay in memory until commit().
import Foundation
import MonolithAPFS

public final class VPhoneAPFSImage: @unchecked Sendable {
    public let url: URL
    let container: OpaquePointer
    let lock = NSRecursiveLock()

    public init(_ url: URL, writable: Bool) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let c = writable ? apfs_open_rw(url.path, &err, err.count) : apfs_open(url.path, &err, err.count) else {
            throw VPhoneConfinedDirectoryError.system("APFS: " + String(cString: err), EIO)
        }
        self.url = url
        container = c
    }

    deinit { apfs_close(container) }

    /// The volumes, by name.
    public var volumeNames: [String] {
        (0 ..< apfs_volume_count(container)).compactMap { apfs_volume(container, $0).map { String(cString: apfs_volume_name($0)) } }
    }

    /// A volume's root directory (its live state; a sealed system's snapshot is not what is written).
    public func volume(named name: String) throws -> VPhoneConfinedDirectory {
        for i in 0 ..< apfs_volume_count(container) {
            if let v = apfs_volume(container, i), String(cString: apfs_volume_name(v)) == name {
                return VPhoneConfinedDirectory(apfs: VPhoneAPFSNode(image: self, volume: v, id: 2, path: ""))
            }
        }
        throw VPhoneConfinedDirectoryError.missing("volume \(name) in \(url.lastPathComponent)")
    }

    public func commit() throws {
        lock.lock(); defer { lock.unlock() }
        guard apfs_commit(container) == 0 else { throw failure("commit") }
    }

    func failure(_ what: String) -> VPhoneConfinedDirectoryError {
        .system("APFS \(what): " + String(cString: apfs_error(container)), EIO)
    }
}

/// One directory inside a volume of a VPhoneAPFSImage.
public struct VPhoneAPFSNode: @unchecked Sendable {
    let image: VPhoneAPFSImage
    let volume: OpaquePointer
    let id: UInt64
    let path: String

    var device: dev_t { dev_t(truncatingIfNeeded: 0x6170_0000 | (Int(bitPattern: UInt(bitPattern: volume.hashValue)) & 0xffff)) }

    func child(_ name: String) -> (id: UInt64, type: UInt16)? {
        var cid: UInt64 = 0, type: UInt16 = 0
        guard apfs_child(volume, id, name, &cid, &type) == 0 else { return nil }
        return (cid, type)
    }

    func inode(_ id: UInt64) -> ApfsInode? {
        var ino = ApfsInode()
        return apfs_inode(volume, id, &ino) == 0 ? ino : nil
    }

    func stat(of id: UInt64) -> stat? {
        guard let ino = inode(id) else { return nil }
        var s = Darwin.stat()
        s.st_mode = mode_t(ino.mode)
        s.st_uid = ino.uid
        s.st_gid = ino.gid
        s.st_size = off_t(ino.size)
        s.st_ino = ino_t(ino.id)
        s.st_dev = device
        s.st_nlink = nlink_t(truncatingIfNeeded: max(ino.nlink_or_children, 1))
        s.st_flags = ino.bsd_flags
        s.st_mtimespec = timespec(tv_sec: Int(ino.mtime / 1_000_000_000), tv_nsec: Int(ino.mtime % 1_000_000_000))
        return s
    }

    func sub(_ id: UInt64, _ name: String) -> VPhoneAPFSNode {
        VPhoneAPFSNode(image: image, volume: volume, id: id, path: path.isEmpty ? name : path + "/" + name)
    }

    func names() throws -> [(name: String, id: UInt64, type: UInt16)] {
        var list: UnsafeMutablePointer<ApfsDirEntry>?
        var count = 0
        guard apfs_list(volume, id, &list, &count) == 0 else { throw image.failure("list \(path)") }
        defer { free(list) }
        return (0 ..< count).map { i in
            var e = list![i]
            let name = withUnsafeBytes(of: &e.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (name, e.id, e.type)
        }
    }

    func read(_ id: UInt64) throws -> Data {
        guard var ino = inode(id) else { throw image.failure("inode") }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard apfs_read_file(volume, &ino, &out, &len) == 0 else { throw image.failure("read \(path)") }
        defer { free(out) }
        return Data(bytes: out!, count: len)
    }
}
