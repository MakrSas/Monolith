// KernelCacheVolumeCopy.swift — A staged volume where only root can reach it.
//
// The volume kmutil links is staged by the user (`fw kernelcache`, which runs
// `ipsw`), and linked by root, which reads every file in it into a kernelcache
// the user receives. So root does not link the staged folder: it copies it into
// a fresh directory of its own, walking it by descriptor and recreating no link
// but the KDK's own pointer to the volume's extensions. Nothing a user puts in
// the stage can make kmutil read a file outside it, and nothing can change
// under kmutil once the copy is made.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

struct KernelCacheVolumeCopy {
    /// The private directory, removed by `remove()`.
    let root: URL
    let volume: URL
    let kernel: URL

    /// The one symbolic link a staged volume has, and where it points.
    static func allowedLink(kdk: String) -> (path: String, target: String) {
        ("Library/Developer/KDKs/\(kdk)/System/Library/Extensions", "../../../../../../System/Library/Extensions")
    }

    /// `pathLength` is the length the volume's absolute path must have
    /// (`KernelCacheMixer.buildRootLength`); the volume's name makes it up.
    init(staged: URL, kdk: String, pathLength: Int) throws {
        var template = Array("/private/var/tmp/vphone-kc.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            throw PatcherError.invalidFormat("could not create a private directory for the kernelcache link: \(String(cString: strerror(errno)))")
        }
        root = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        let nameLength = pathLength - root.path.count - 1
        guard (1 ... 255).contains(nameLength) else {
            try? FileManager.default.removeItem(at: root)
            throw PatcherError.invalidFormat("a kernelcache volume path of \(pathLength) characters does not fit below \(root.path)")
        }
        let name = String(repeating: "b", count: nameLength)
        volume = root.appending(path: name)
        kernel = volume.appending(path: "Library/Developer/KDKs/\(kdk)/System/Library/Kernels/kernel")
        do {
            // Refuses a symbolic link anywhere on the way to the stage.
            let source = try VPhoneConfinedDirectory.pin(absolutePath: staged.path)
            let owner = try source.metadata().st_uid
            guard owner == 0 || owner == VPhoneInvokingUser.current?.uid else {
                throw PatcherError.invalidFormat("the staged kernelcache volume belongs to user \(owner), not to the invoking user")
            }
            let destination = try VPhoneConfinedDirectory.pin(absolutePath: root.path, requireOwner: 0)
            try destination.copyTree(from: source, to: name, requireSourceOwner: owner, owner: (0, 0))
            try Self.checkLinks(in: volume, kdk: kdk)
            try Self.normaliseModes(in: volume)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: kernel.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw PatcherError.fileNotFound("the kernel in the staged kernelcache volume")
            }
        } catch {
            remove()
            throw error
        }
    }

    /// Fails on any symbolic link but the KDK's link to the extensions.
    static func checkLinks(in volume: URL, kdk: String) throws {
        let allowed = allowedLink(kdk: kdk)
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: volume.path) else {
            throw PatcherError.fileNotFound(volume.path)
        }
        while let relative = walk.nextObject() as? String {
            let path = volume.appending(path: relative).path
            guard try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard relative == allowed.path, try fm.destinationOfSymbolicLink(atPath: path) == allowed.target else {
                throw PatcherError.invalidFormat("the staged kernelcache volume links \(relative) outside itself")
            }
        }
    }

    /// kmutil skips a kext with a group- or world-writable file as silently as
    /// one it does not own, and the caches the stage reads from are shared with
    /// mode 0777. The copy is root's own, so its modes are set here: 0755 for
    /// directories and executables, 0644 for the rest.
    static func normaliseModes(in volume: URL) throws {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: volume.path) else {
            throw PatcherError.fileNotFound(volume.path)
        }
        for case let relative as String in walk {
            let path = volume.appending(path: relative).path
            let attributes = try fm.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else { continue }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            let wanted: UInt16 = type == .typeDirectory || mode & 0o111 != 0 ? 0o755 : 0o644
            if mode != wanted {
                try fm.setAttributes([.posixPermissions: NSNumber(value: wanted)], ofItemAtPath: path)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
