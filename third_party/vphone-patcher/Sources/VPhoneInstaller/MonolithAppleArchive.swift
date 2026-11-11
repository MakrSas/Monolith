// MONOLITH: `aa extract -d DIR -i ARCHIVE` without the aa tool: an Apple Archive (compressed or not)
// read with AppleArchive.framework, its directories, files and links written through a
// VPhoneConfinedDirectory (so straight into a guest volume of an APFS image).
import AppleArchive
import Foundation
import System
import VPhoneCoreKit

public enum MonolithAppleArchive {
    struct Failure: Error, CustomStringConvertible { let description: String }

    public static func extract(_ archive: URL, into root: VPhoneConfinedDirectory, only: String) throws -> Int {
        try extract(archive, into: root, filter: { $0 == only || $0.hasPrefix(only + "/") })
    }

    static func extract(_ archive: URL, into root: VPhoneConfinedDirectory, filter: ((String) -> Bool)? = nil) throws -> Int {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed)
        else { throw Failure(description: "\(archive.lastPathComponent): not an Apple Archive") }
        defer { try? decoder.close(); try? decompressed.close(); try? file.close() }
        var count = 0
        while let header = try decoder.readHeader() {
            func string(_ key: String) -> String? {
                if case let .string(_, value) = header.field(forKey: ArchiveHeader.FieldKey(key)) { return value }
                return nil
            }
            func uint(_ key: String) -> UInt64? {
                if case let .uint(_, value) = header.field(forKey: ArchiveHeader.FieldKey(key)) { return value }
                return nil
            }
            guard let type = uint("TYP") else { continue }
            let path = string("PAT") ?? ""
            let mode = mode_t(uint("MOD") ?? 0o644) & 0o7777
            let owner = (uid_t(uint("UID") ?? 0), gid_t(uint("GID") ?? 0))
            var data = Data()
            if case let .blob(_, size, _) = header.field(forKey: ArchiveHeader.FieldKey("DAT")) {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(size), alignment: 16)
                defer { buffer.deallocate() }
                try decoder.readBlob(key: ArchiveHeader.FieldKey("DAT"), into: buffer)
                data = Data(buffer)
            }
            if let filter, !filter(path) { continue }
            if path.isEmpty { // the archive's root: the directory itself
                if type == UInt64(Character("D").asciiValue!) { try root.setPermissions(mode: mode, owner: owner) }
                continue
            }
            switch Character(UnicodeScalar(UInt8(truncatingIfNeeded: type))) {
            case "D":
                let directory = try root.directory(path, create: true, mode: mode)
                try directory.setPermissions(mode: mode, owner: owner)
            case "F":
                let (parent, leaf) = try root.parent(of: path, create: true)
                try parent.writeFile(leaf, contents: data, mode: mode, owner: owner)
            case "L":
                try root.createSymlink(target: string("LNK") ?? "", at: path)
            default:
                throw Failure(description: "\(path): entry type \(type) is not extracted here")
            }
            count += 1
        }
        return count
    }
}
