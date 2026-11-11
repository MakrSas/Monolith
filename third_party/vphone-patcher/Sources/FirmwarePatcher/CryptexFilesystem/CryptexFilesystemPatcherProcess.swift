// CryptexFilesystemPatcherProcess.swift — Subprocess execution for the filesystem patcher.
//
// Split out of CryptexFilesystemPatcher.swift. Every external tool the merge drives —
// diskutil, ipsw, aa, cryptexctl, apfs_sealvolume — runs through runProcess, and ProcessError
// is what it throws. What no longer runs through it: tar (VPhoneArchiveKit), and chmod, chown, ln
// and find (CryptexFilesystemPatcherFileOps.swift).
//
// There used to be a `sudo: Bool` parameter here that spawned `/usr/bin/whoami` and matched
// "root" in its output. Nothing ever passed it — it was dead on every call site — and the
// question it asked is `geteuid()`, which needs no process and no string match. The live root
// check is VPhoneVirtualMachineCreator's, before any of this runs.

import Foundation
import VPhoneCoreKit
import VPhoneSign

enum ProcessError: Error {
    case failed(Int32, String)
    case notExecutable(String)
}

extension CryptexFilesystemPatcher {
    func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        output: URL? = nil,
    ) throws -> String {
        // MONOLITH: `codesign -f -s - BUNDLE` on a guest volume in an APFS image: sealed in-process
        if launchPath == "/usr/bin/codesign", let last = arguments.last, let (root, relative) = Self.monolithResolve(last) {
            try MonolithBundleSeal.seal(system: root, bundle: relative,
                                        preserveEntitlements: arguments.contains { $0.hasPrefix("--preserve-metadata") })
            return ""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        if let output {
            let outFile = try FileHandle(forWritingTo: output)
            process.standardOutput = outFile
            process.standardError = outFile
        } else {
            process.standardOutput = outPipe
            process.standardError = outPipe
        }

        try process.run()
        let output = output == nil
            ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            : nil
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(process.terminationStatus, output ?? "")
        }
        return output ?? ""
    }
}

extension CryptexFilesystemPatcher {
    /// MONOLITH: a path on a guest volume standing in for a mount (VPhoneConfinedDirectory.monolithMounts),
    /// as a mount path or as an image directory's own `apfs:IMAGE#/...` path: that volume and the path in it.
    static func monolithResolve(_ path: String) -> (VPhoneConfinedDirectory, String)? {
        for (mount, root) in VPhoneConfinedDirectory.monolithMounts {
            if path == mount || path.hasPrefix(mount + "/") {
                return (root, String(path.dropFirst(mount.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
            if let base = try? root.path, path.hasPrefix(base) {
                return (root, String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
        }
        return nil
    }

    /// MONOLITH: a Mach-O on a guest volume set to a platform and signed ad hoc again, through a host copy.
    func monolithRetarget(_ root: VPhoneConfinedDirectory, _ relative: String, platform: UInt32) throws {
        var data = try root.readData(relative)
        try MachOBuildPlatform.set(platform, in: &data)
        let file = try createTmpDir().appending(path: "payload")
        try data.write(to: file)
        try VPhoneSigner.sign(fileAt: file, options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc))
        try root.replaceFile(relative, fromFileAt: file, mode: 0o755, owner: (0, 0))
    }
}
