import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// Root patches a snapshot below a private directory, never the caller's
/// writable VM tree. Only firmware inputs enter it; guest disks stay in place.
/// Publication walks the pinned original directory and replaces file leaves,
/// so a caller swapping a path for a symlink cannot redirect root's writes.
public struct FirmwarePatchWorkspace {
    public let root: URL
    public let machine: URL
    let source: VPhoneConfinedDirectory
    let parent: VPhoneConfinedDirectory
    let privateMachine: VPhoneConfinedDirectory
    let owner: (uid: uid_t, gid: gid_t)
    let treeNames: [String]

    public init(machine: URL, workParent: String) throws {
        parent = try VPhoneConfinedDirectory.pin(absolutePath: workParent, requireOwner: geteuid())
        let mode = try parent.metadata().st_mode
        guard mode & 0o077 == 0 || mode & 0o1777 == 0o1777 else {
            throw PatcherError.invalidFormat("The firmware work parent must be private or sticky.")
        }
        source = try VPhoneConfinedDirectory.pin(absolutePath: machine.path)
        let user = VPhoneInvokingUser.current
        owner = (user?.uid ?? getuid(), user?.gid ?? getgid())
        guard try source.metadata().st_uid == owner.uid else {
            throw PatcherError.invalidFormat("The VM directory must belong to the invoking user.")
        }
        var template = Array("\(workParent)/vphone-fw.XXXXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let path else {
            throw PatcherError.invalidFormat("Could not create a private firmware work directory.")
        }
        root = URL(fileURLWithPath: path, isDirectory: true)
        self.machine = root.appending(path: "machine", directoryHint: .isDirectory)
        let work = try VPhoneConfinedDirectory.pin(absolutePath: path, requireOwner: geteuid())
        privateMachine = try work.directory("machine", create: true, mode: 0o700)
        do {
            let entries = try source.entries()
            treeNames = entries.filter { $0.contains("Restore") || $0 == VPhoneBundleOperations.firmwareOriginalsDirectoryName }
            let roots = entries.filter {
                $0 == "config.plist" || $0 == "PatchSelection.plist" || $0 == Self.presetFileName || $0 == "OpenAVB.bin" || Self.isAppleROM($0)
            }
            for name in treeNames + roots {
                try Self.copyInput(name, from: source, into: privateMachine, owner: owner.uid)
            }
        } catch {
            try? parent.removeItem(root.lastPathComponent)
            throw error
        }
    }

    /// A VM's copy of a preset given to `--preset` as a file.
    public static let presetFileName = "PatchPreset.plist"

    static func isAppleROM(_ name: String) -> Bool {
        name.hasPrefix("AVPBooter") && name.hasSuffix(".bin")
    }

    /// No symbolic links, hard links, special files or other users' files are
    /// admitted. APFS clones avoid copying multi-gigabyte restore images.
    static func copyInput(_ name: String, from source: VPhoneConfinedDirectory, into target: VPhoneConfinedDirectory, owner: uid_t) throws {
        guard let info = try source.status(name), info.st_uid == owner || info.st_uid == 0 else {
            throw PatcherError.invalidFormat("Firmware input \(name) belongs to another user.")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let input = try source.directory(name)
            let output = try target.directory(name, create: true, mode: 0o700)
            for child in try input.entries() {
                // Executable seal tools are downloaded independently into the
                // private snapshot, never trusted from a user-owned VM.
                if child == ".tools" { continue }
                try copyInput(child, from: input, into: output, owner: owner)
            }
        case S_IFREG:
            let input = try source.openRegularFile(name, requireOwner: info.st_uid, requireSingleLink: true)
            if try !target.clone(input, to: name) {
                try target.copy(input, to: name)
            }
            try target.setMode(name, 0o600)
        default:
            throw PatcherError.invalidFormat("Firmware input \(name) must be a real file or directory, not a link.")
        }
    }

    public func publish() throws {
        let names = try privateMachine.entries().filter {
            treeNames.contains($0) || $0 == VPhoneBundleOperations.firmwareOriginalsDirectoryName
                || $0 == "PatchSelection.plist" || $0 == "PatchPlan.plist" || $0 == Self.presetFileName || Self.isAppleROM($0)
        }
        for name in names {
            try publish(name, from: privateMachine, to: source, relative: name)
        }
        // A named --preset dropped the VM's preset copy.
        if !names.contains(Self.presetFileName), try source.status(Self.presetFileName) != nil {
            try source.removeItem(Self.presetFileName)
        }
    }

    func publish(_ name: String, from input: VPhoneConfinedDirectory, to output: VPhoneConfinedDirectory, relative: String) throws {
        if try input.isDirectory(name) {
            let sourceChild = try input.directory(name)
            let targetChild = try output.directory(name, create: true, mode: 0o777)
            try targetChild.setPermissions(mode: 0o777, owner: owner)
            for child in try sourceChild.entries() {
                try publish(child, from: sourceChild, to: targetChild, relative: relative + "/" + child)
            }
        } else {
            // The input path is below the private work root; replaceFile still
            // rejects symlink leaves. The destination is descriptor-relative.
            try output.replaceFile(name, fromFileAt: machine.appending(path: relative), mode: 0o777, owner: owner)
        }
    }

    public func remove() throws {
        // Confined removal refuses to cross a mount left by a failed detach.
        try parent.removeItem(root.lastPathComponent)
    }
}
