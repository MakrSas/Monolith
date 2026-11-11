// MONOLITH: VPhoneConfinedDirectory on a volume of an APFS image (VPhoneAPFSImage), through Monolith's own
// APFS code: what vphone does to a mounted guest volume, done to the image itself. Paths are walked one
// component at a time and a symbolic link on the way is refused, as in the descriptor-based code.
import Foundation
import MonolithAPFS

extension VPhoneConfinedDirectory {
    private static let typeDirectory: UInt16 = 4, typeFile: UInt16 = 8, typeLink: UInt16 = 10

    private func fail(_ node: VPhoneAPFSNode, _ what: String) -> VPhoneConfinedDirectoryError {
        node.image.failure(what)
    }

    /// The node at a relative path's parent, and the leaf.
    private func walk(_ node: VPhoneAPFSNode, _ components: ArraySlice<String>, create: Bool, mode: mode_t,
                      relative: String) throws -> VPhoneAPFSNode {
        var current = node
        for name in components {
            if let c = current.child(name) {
                if c.type == Self.typeLink { throw VPhoneConfinedDirectoryError.symbolicLink(relative) }
                guard c.type == Self.typeDirectory else { throw VPhoneConfinedDirectoryError.notDirectory(relative) }
                current = current.sub(c.id, name)
            } else if create {
                var id: UInt64 = 0
                guard apfs_mkdir(current.volume, current.id, name, UInt16(mode & 0o7777), 0, 0, &id) == 0 else {
                    throw fail(node, "mkdir \(relative)")
                }
                current = current.sub(id, name)
            } else {
                throw VPhoneConfinedDirectoryError.missing(relative)
            }
        }
        return current
    }

    func apfsDirectory(_ node: VPhoneAPFSNode, _ relative: String, create: Bool, mode: mode_t) throws -> VPhoneConfinedDirectory {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let c = try Self.components(of: relative)
        return VPhoneConfinedDirectory(apfs: try walk(node, c[...], create: create, mode: mode, relative: relative))
    }

    func apfsParent(_ node: VPhoneAPFSNode, _ relative: String, create: Bool, mode: mode_t) throws
        -> (directory: VPhoneConfinedDirectory, leaf: String)
    {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let c = try Self.components(of: relative)
        let dir = try walk(node, c.dropLast(), create: create, mode: mode, relative: relative)
        return (VPhoneConfinedDirectory(apfs: dir), c[c.count - 1])
    }

    private func leaf(_ node: VPhoneAPFSNode, _ relative: String, create: Bool = false)
        throws -> (dir: VPhoneAPFSNode, name: String, entry: (id: UInt64, type: UInt16)?)
    {
        let c = try Self.components(of: relative)
        let dir = try walk(node, c.dropLast(), create: create, mode: 0o755, relative: relative)
        return (dir, c[c.count - 1], dir.child(c[c.count - 1]))
    }

    func apfsMetadata(_ node: VPhoneAPFSNode) throws -> stat {
        guard let s = node.stat(of: node.id) else { throw fail(node, "stat \(node.path)") }
        return s
    }

    func apfsStatus(_ node: VPhoneAPFSNode, _ relative: String) throws -> stat? {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let l: (dir: VPhoneAPFSNode, name: String, entry: (id: UInt64, type: UInt16)?)
        do { l = try leaf(node, relative) } catch VPhoneConfinedDirectoryError.missing { return nil }
        guard let e = l.entry else { return nil }
        return node.stat(of: e.id)
    }

    func apfsReadLink(_ node: VPhoneAPFSNode, _ relative: String) throws -> String? {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        guard let e = try leaf(node, relative).entry, e.type == Self.typeLink else { return nil }
        var buffer = [CChar](repeating: 0, count: 1025)
        guard apfs_readlink(node.volume, e.id, &buffer, buffer.count) == 0 else { throw fail(node, "readlink \(relative)") }
        return String(cString: buffer)
    }

    func apfsReadData(_ node: VPhoneAPFSNode, _ relative: String) throws -> Data {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        guard let e = try leaf(node, relative).entry else { throw VPhoneConfinedDirectoryError.missing(relative) }
        guard e.type == Self.typeFile else { throw VPhoneConfinedDirectoryError.notRegularFile(relative) }
        return try node.read(e.id)
    }

    /// A regular file as a descriptor: its contents in an unlinked temporary file.
    func apfsOpen(_ node: VPhoneAPFSNode, _ relative: String, requireOwner owner: uid_t?) throws -> VPhoneConfinedFile {
        let data = try apfsReadData(node, relative)
        var meta = try apfsStatus(node, relative) ?? stat()
        if let owner, meta.st_uid != owner { throw VPhoneConfinedDirectoryError.foreignOwner(relative, meta.st_uid) }
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("apfs.XXXXXX").path
        var name = Array(template.utf8CString)
        let fd = mkstemp(&name)
        guard fd >= 0 else { throw VPhoneConfinedDirectoryError.system("mkstemp", errno) }
        unlink(name)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        lseek(fd, 0, SEEK_SET)
        meta.st_size = off_t(data.count)
        return VPhoneConfinedFile(descriptor: fd, metadata: meta)
    }

    func apfsWrite(_ node: VPhoneAPFSNode, _ relative: String, _ data: Data, mode: mode_t,
                   owner: (uid: uid_t, gid: gid_t)?) throws {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let l = try leaf(node, relative)
        if let e = l.entry, e.type != Self.typeFile {
            guard apfs_unlink(node.volume, l.dir.id, l.name) == 0 else { throw fail(node, "replace \(relative)") }
        }
        let r = data.withUnsafeBytes {
            apfs_write_file(node.volume, l.dir.id, l.name, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                            UInt16(mode & 0o7777), owner?.uid ?? 0, owner?.gid ?? 0)
        }
        guard r == 0 else { throw fail(node, "write \(relative)") }
        if let owner, let e = l.dir.child(l.name) {
            guard apfs_chmod(node.volume, e.id, UInt16(mode & 0o7777), owner.uid, owner.gid) == 0 else { throw fail(node, "chown \(relative)") }
        }
    }

    func apfsOverwrite(_ node: VPhoneAPFSNode, _ relative: String, _ data: Data) throws {
        guard let s = try apfsStatus(node, relative), s.st_mode & S_IFMT == S_IFREG else {
            throw VPhoneConfinedDirectoryError.missing(relative)
        }
        try apfsWrite(node, relative, data, mode: s.st_mode & 0o7777, owner: (s.st_uid, s.st_gid))
    }

    func apfsCopy(_ node: VPhoneAPFSNode, _ file: VPhoneConfinedFile, _ relative: String, mode: mode_t) throws {
        lseek(file.descriptor, 0, SEEK_SET)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(file.descriptor, &buffer, buffer.count)
            if n < 0 { throw VPhoneConfinedDirectoryError.system("read", errno) }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        if try apfsStatus(node, relative) != nil { throw VPhoneConfinedDirectoryError.system(relative, EEXIST) }
        try apfsWrite(node, relative, data, mode: mode, owner: nil)
    }

    func apfsSymlink(_ node: VPhoneAPFSNode, _ target: String, _ relative: String) throws {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let l = try leaf(node, relative)
        if l.entry != nil { _ = try apfsRemove(node, relative) }
        guard apfs_symlink(node.volume, l.dir.id, l.name, target, 0, 0) == 0 else { throw fail(node, "symlink \(relative)") }
    }

    func apfsChmod(_ node: VPhoneAPFSNode, _ relative: String, mode: mode_t?, owner: (uid_t, gid_t)?) throws {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        guard let e = try leaf(node, relative).entry, let s = node.stat(of: e.id) else { throw VPhoneConfinedDirectoryError.missing(relative) }
        guard apfs_chmod(node.volume, e.id, UInt16((mode ?? s.st_mode) & 0o7777), owner?.0 ?? UInt32.max, owner?.1 ?? UInt32.max) == 0 else {
            throw fail(node, "chmod \(relative)")
        }
    }

    func apfsSetOwnPermissions(_ node: VPhoneAPFSNode, mode: mode_t, owner: (uid: uid_t, gid: gid_t)?) throws {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        guard apfs_chmod(node.volume, node.id, UInt16(mode & 0o7777), owner?.uid ?? UInt32.max, owner?.gid ?? UInt32.max) == 0 else {
            throw fail(node, "chmod \(node.path)")
        }
    }

    /// A file, link or whole tree; the bytes of the files removed.
    func apfsRemove(_ node: VPhoneAPFSNode, _ relative: String) throws -> UInt64 {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let l: (dir: VPhoneAPFSNode, name: String, entry: (id: UInt64, type: UInt16)?)
        do { l = try leaf(node, relative) } catch VPhoneConfinedDirectoryError.missing { return 0 }
        guard let e = l.entry else { return 0 }
        return try removeTree(l.dir, l.name, e)
    }

    private func removeTree(_ dir: VPhoneAPFSNode, _ name: String, _ e: (id: UInt64, type: UInt16)) throws -> UInt64 {
        var bytes: UInt64 = 0
        if e.type == Self.typeDirectory {
            let sub = dir.sub(e.id, name)
            for c in try sub.names() { bytes += try removeTree(sub, c.name, (c.id, c.type)) }
        } else if e.type == Self.typeFile, let s = dir.stat(of: e.id) {
            bytes = UInt64(max(s.st_size, 0))
        }
        guard apfs_unlink(dir.volume, dir.id, name) == 0 else { throw fail(dir, "remove \(dir.path)/\(name)") }
        return bytes
    }

    func apfsRename(_ node: VPhoneAPFSNode, _ source: String, _ destination: String, _ target: VPhoneAPFSNode?) throws {
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        guard let target, target.volume == node.volume else { throw VPhoneConfinedDirectoryError.system(source, EXDEV) }
        let from = try leaf(node, source), to = try leaf(target, destination)
        guard from.entry != nil else { throw VPhoneConfinedDirectoryError.missing(source) }
        guard apfs_rename(node.volume, from.dir.id, from.name, to.dir.id, to.name) == 0 else { throw fail(node, "rename \(source)") }
    }

    /// One file from here to target (either side may be an APFS image or a real directory).
    func apfsCopyFile(_ source: String, _ destination: String, _ target: VPhoneConfinedDirectory) throws {
        let data = try readData(source)
        let mode = try status(source).map { $0.st_mode & 0o7777 } ?? 0o600
        if try target.status(destination) != nil { throw VPhoneConfinedDirectoryError.system(destination, EEXIST) }
        try target.writeFile(destination, contents: data, mode: mode)
    }

    /// A whole tree: links as links, files with their modes, owners as they were unless owner says.
    func apfsCopyTree(from source: VPhoneConfinedDirectory, to relative: String, owner: (uid: uid_t, gid: gid_t)?,
                      clearSetID: Bool) throws {
        let (parent, leaf) = try self.parent(of: relative, create: true)
        let root = try source.metadata()
        let destination = try parent.directory(leaf, create: true, mode: root.st_mode & 0o7777)
        try copyEntries(from: source, into: destination, owner: owner, clearSetID: clearSetID)
    }

    private func copyEntries(from source: VPhoneConfinedDirectory, into destination: VPhoneConfinedDirectory,
                             owner: (uid: uid_t, gid: gid_t)?, clearSetID: Bool) throws {
        for name in try source.entries() {
            guard let s = try source.status(name) else { continue }
            let who = owner ?? (s.st_uid, s.st_gid)
            var mode = s.st_mode & 0o7777
            if clearSetID { mode &= ~mode_t(S_ISUID | S_ISGID) }
            switch s.st_mode & S_IFMT {
            case S_IFDIR:
                let sub = try destination.directory(name, create: true, mode: mode)
                try copyEntries(from: try source.directory(name), into: sub, owner: owner, clearSetID: clearSetID)
                try sub.setPermissions(mode: mode, owner: who)
            case S_IFLNK:
                if let target = try source.readLink(name) { try destination.createSymlink(target: target, at: name) }
            case S_IFREG:
                try destination.writeFile(name, contents: try source.readData(name), mode: mode, owner: who)
            default:
                throw VPhoneConfinedDirectoryError.unsupportedFileType(name)
            }
        }
    }

    /// MONOLITH: another name for a file (a hard link), for APFS-image directories.
    public func apfsHardLink(_ source: String, to destination: String) throws {
        guard let node = apfs else { throw VPhoneConfinedDirectoryError.system(source, ENOTSUP) }
        node.image.lock.lock(); defer { node.image.lock.unlock() }
        let from = try leaf(node, source), to = try leaf(node, destination)
        guard let e = from.entry, e.type == Self.typeFile else { throw VPhoneConfinedDirectoryError.notRegularFile(source) }
        guard to.entry == nil else { throw VPhoneConfinedDirectoryError.system(destination, EEXIST) }
        guard apfs_link(node.volume, e.id, to.dir.id, to.name) == 0 else { throw fail(node, "link \(destination)") }
    }
}
