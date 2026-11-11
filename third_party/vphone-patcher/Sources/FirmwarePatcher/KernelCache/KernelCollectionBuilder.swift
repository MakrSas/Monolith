// KernelCollectionBuilder.swift — Link a staged volume into an IMG4 kernelcache.
//
// kmutil only gathers the inputs; the layout comes from the kernel collection
// builder in the host's dyld shared cache. The builder of macOS 26.4 and later
// puts the kernel's `__TEXT_EXEC` after the kexts ("kernel-last"), macOS 15 and
// 26.0–26.3 put it first ("kernel-first"), and a kernel only boots in the layout
// Apple linked it with. Every iOS 26.4+ base is kernel-last, so the host links
// it when it runs macOS 26.4 or later; the iOS 18 bases are kernel-first.
//
// When the host's builder has the other layout, a Mac (or macOS VM) running one
// with the right layout links the volume over ssh (`RemoteKernelCollectionBuilder`):
//
//   VPHONE_KMUTIL_SSH=user@host       the ssh destination (key or password)
//   VPHONE_KMUTIL_SSH_PASSWORD=...    optional: the password for ssh and sudo
//
// kmutil reads only kexts owned by root:wheel. Others it skips without a word
// and takes the host's own from /System/Library/Extensions, so the link runs as
// root on a volume chowned to root, here or on the remote Mac.

import Foundation
import VPhonePatchKit

enum KernelCollectionBuilder {
    /// The flags of Apple's boot kernel collections: strip all, IMG4 with split
    /// read-only and executable tags.
    static let createFlags = ["-a", "arm64e", "-n", "boot", "-s", "all", "-z", "-x"]
    static let packageFlags = ["--compress", "--img4-encode", "--split-ro-rx-tags"]

    static let sshEnvironmentVariable = "VPHONE_KMUTIL_SSH"
    static let sshPasswordEnvironmentVariable = "VPHONE_KMUTIL_SSH_PASSWORD"

    /// Where a base is linked.
    enum Location {
        case host
        case remote(RemoteKernelCollectionBuilder)
    }

    static func layout(forMacOS version: OperatingSystemVersion) -> KernelCacheBase.BuilderLayout {
        let atLeast264 = version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
        return atLeast264 ? .kernelLast : .kernelFirst
    }

    static func layout(forMacOS version: String) -> KernelCacheBase.BuilderLayout {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return layout(forMacOS: OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0,
        ))
    }

    /// The host when its builder has the base's layout, else the ssh builder
    /// `VPHONE_KMUTIL_SSH` names, once its macOS is checked. Refuses before
    /// anything is extracted when neither can link `base`.
    static func location(
        for base: KernelCacheBase,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws -> Location {
        let host = ProcessInfo.processInfo.operatingSystemVersion
        let hostLayout = layout(forMacOS: host)
        if hostLayout == base.builderLayout {
            return .host
        }
        guard let destination = environment[sshEnvironmentVariable], !destination.isEmpty else {
            let needed = base.builderLayout == .kernelLast ? "macOS 26.4 or later" : "macOS 15, or 26.0 to 26.3"
            throw PatcherError.invalidFormat(
                "the iOS \(base.productVersion) kernelcache must be linked \(base.builderLayout.rawValue), "
                    + "and the kmutil of macOS \(host.majorVersion).\(host.minorVersion) links \(hostLayout.rawValue). "
                    + "Link it on a Mac or macOS VM running \(needed) with Remote Login on: "
                    + "\(sshEnvironmentVariable)=<user>@<host> (and \(sshPasswordEnvironmentVariable)=<password> without ssh keys "
                    + "and passwordless sudo) vphone-cli fw kernelcache <vm>",
            )
        }
        let remote = RemoteKernelCollectionBuilder(destination: destination, password: environment[sshPasswordEnvironmentVariable])
        let version = try remote.macOSVersion()
        guard layout(forMacOS: version) == base.builderLayout else {
            throw PatcherError.invalidFormat(
                "\(destination) runs macOS \(version), whose kmutil links \(layout(forMacOS: version).rawValue); "
                    + "the iOS \(base.productVersion) kernelcache must be linked \(base.builderLayout.rawValue)",
            )
        }
        return .remote(remote)
    }

    /// kmutil's arguments for the volume at `volume`, writing `<volume>.kc` beside it.
    static func kmutilArguments(volume: String, kernel: String, identifiers: [String]) -> [String] {
        var arguments = ["create"] + createFlags + ["-R", volume, "-k", kernel, "-r", "\(volume)/System/Library/Extensions"]
        for identifier in identifiers {
            arguments += ["-b", identifier]
        }
        // -B is relative to the volume root.
        let name = (volume as NSString).lastPathComponent
        return arguments + packageFlags + ["-B", "/../\(name).kc"]
    }

    /// Link the volume at `volume` on this Mac and return kmutil's IMG4 kernelcache.
    static func link(volume: URL, kernel: URL, identifiers: [String], log: URL) throws -> Data {
        try KernelCacheMixer.run("/usr/sbin/chown", ["-R", "0:0", volume.path], log: log)
        let output = volume.deletingLastPathComponent().appending(path: "\(volume.lastPathComponent).kc")
        try? FileManager.default.removeItem(at: output)
        try KernelCacheMixer.run(
            "/usr/bin/kmutil", kmutilArguments(volume: volume.path, kernel: kernel.path, identifiers: identifiers), log: log,
        )
        return try Data(contentsOf: output)
    }
}

/// Links a staged volume with the kmutil of another Mac, over the system ssh.
///
/// The volume is uploaded as a tar into a fresh directory in the remote
/// `/private/var/tmp`, renamed so its absolute path has the length the base
/// needs (`KernelCacheMixer.buildRootLength`); there root owns it, takes the
/// write bits kmutil skips a kext for, and links it. The result comes back
/// over the same connection and the directory is removed.
///
/// A password is passed to ssh through `SSH_ASKPASS` and to sudo on its
/// standard input, so nothing but the system's ssh is needed.
struct RemoteKernelCollectionBuilder {
    let destination: String
    let password: String?

    func macOSVersion() throws -> String {
        let output = try run(command: "sw_vers -productVersion")
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Links `staged` (a staged volume whose kernel is at `kernel`, relative to
    /// it) and returns kmutil's IMG4 kernelcache. kmutil's output goes to `log`.
    func link(staged: URL, kernel: String, identifiers: [String], pathLength: Int, work: URL, log: URL) throws -> Data {
        let directory = "/private/var/tmp/vphone-kc-\(UUID().uuidString.prefix(8).lowercased())"
        let nameLength = pathLength - directory.count - 1
        guard (1 ... 255).contains(nameLength) else {
            throw PatcherError.invalidFormat("a kernelcache volume path of \(pathLength) characters does not fit below \(directory)")
        }
        let name = String(repeating: "b", count: nameLength)
        let archive = work.appending(path: "volume.tar")
        try? FileManager.default.removeItem(at: archive)
        try KernelCacheMixer.run(
            "/usr/bin/tar",
            ["-C", staged.deletingLastPathComponent().path, "-cf", archive.path, "-s", ",^\(staged.lastPathComponent),\(name),", staged.lastPathComponent],
            log: log,
        )
        defer { try? FileManager.default.removeItem(at: archive) }

        print("  [kc] uploading the volume to \(destination):\(directory)")
        try run(command: "mkdir -m 700 \(directory) && tar -C \(directory) -xf -", input: .file(archive))
        defer { _ = try? sudo("rm -rf \(directory)") }

        let volume = "\(directory)/\(name)"
        let kmutil = KernelCollectionBuilder.kmutilArguments(volume: volume, kernel: "\(volume)/\(kernel)", identifiers: identifiers)
            .map(Self.quote).joined(separator: " ")
        print("  [kc] linking with the kmutil of \(destination)")
        try sudo(
            "chown -R root:wheel \(volume) && chmod -R go-w \(volume) && /usr/bin/kmutil \(kmutil) && chown \"$SUDO_UID\" \(volume).kc",
            log: log,
        )
        let output = work.appending(path: "remote.kc")
        try run(command: "cat \(volume).kc", output: output)
        defer { try? FileManager.default.removeItem(at: output) }
        return try Data(contentsOf: output)
    }

    // MARK: - ssh

    enum Input {
        case none
        case file(URL)
        case data(Data)
    }

    /// Runs `command` as root on the remote Mac; with a password, sudo reads it
    /// from its standard input.
    @discardableResult
    func sudo(_ command: String, log: URL? = nil) throws -> Data {
        if let password {
            return try run(command: "sudo -S -p '' sh -c \(Self.quote(command))", input: .data(Data((password + "\n").utf8)), log: log)
        }
        return try run(command: "sudo -n sh -c \(Self.quote(command))", log: log)
    }

    /// Runs `command` on the remote Mac and returns its standard output, or
    /// writes it to `output`. With `log`, both streams go there instead.
    @discardableResult
    func run(command: String, input: Input = .none, output: URL? = nil, log: URL? = nil) throws -> Data {
        var options = ["-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "StrictHostKeyChecking=accept-new"]
        var environment = ProcessInfo.processInfo.environment
        var askpass: URL?
        if let password {
            let script = try Self.askpassScript()
            askpass = script
            environment["SSH_ASKPASS"] = script.appending(path: "askpass").path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["VPHONE_KMUTIL_SSH_ASKPASS_SECRET"] = password
            options += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "NumberOfPasswordPrompts=1"]
        } else {
            options += ["-o", "BatchMode=yes"]
        }
        defer { askpass.map { try? FileManager.default.removeItem(at: $0) } }

        var executable = "/usr/bin/ssh"
        var arguments = options + [destination, command]
        // Under sudo, connect as the invoking user, with their keys and known hosts.
        if geteuid() == 0, let user = environment["SUDO_USER"], !user.isEmpty, user != "root" {
            if let askpass, let uid = environment["SUDO_UID"].flatMap(UInt32.init) {
                _ = chown(askpass.path, uid, gid_t(0))
                _ = chown(askpass.appending(path: "askpass").path, uid, gid_t(0))
            }
            let kept = "SSH_ASKPASS,SSH_ASKPASS_REQUIRE,VPHONE_KMUTIL_SSH_ASKPASS_SECRET"
            arguments = ["-u", user, "-H", "--preserve-env=\(kept)", executable] + arguments
            executable = "/usr/bin/sudo"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let (collected, errors) = try Self.capture(process, input: input, output: output, log: log)
        guard process.terminationStatus == 0 else {
            var detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let log, let text = try? String(contentsOf: log, encoding: .utf8) {
                detail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            }
            throw PatcherError.invalidFormat("ssh \(destination) `\(command.prefix(80))` failed with exit code \(process.terminationStatus): \(detail)")
        }
        return collected
    }

    /// Keep stderr and stdin in private files. Reading two pipes sequentially
    /// can deadlock when ssh fills stderr before it closes stdout; feeding a
    /// large stdin before draining stdout has the same problem.
    static func capture(_ process: Process, input: Input = .none, output: URL? = nil, log: URL? = nil) throws -> (Data, Data) {
        let scratch = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdout = Pipe()
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        let errorFile = scratch.appending(path: "stderr")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        if let log {
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            handles.append(handle)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            let errors = try FileHandle(forWritingTo: errorFile)
            handles.append(errors)
            process.standardError = errors
            if let output {
                FileManager.default.createFile(atPath: output.path, contents: nil)
                let handle = try FileHandle(forWritingTo: output)
                handles.append(handle)
                process.standardOutput = handle
            } else {
                process.standardOutput = stdout
            }
        }
        switch input {
        case .none:
            process.standardInput = FileHandle.nullDevice
        case let .file(url):
            let handle = try FileHandle(forReadingFrom: url)
            handles.append(handle)
            process.standardInput = handle
        case let .data(data):
            let url = scratch.appending(path: "stdin")
            try data.write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            handles.append(handle)
            process.standardInput = handle
            // Keep the data available through the descriptor only.
            try FileManager.default.removeItem(at: url)
        }
        try process.run()
        let collected = output == nil && log == nil ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        return (collected, log == nil ? try Data(contentsOf: errorFile) : Data())
    }

    private static func privateDirectory() throws -> URL {
        var template = Array("/private/var/tmp/vphone-ssh.XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let path else {
            throw PatcherError.invalidFormat("could not create a private directory for ssh: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A private directory holding a script that prints the password from the
    /// environment, so the script and command arguments contain no password.
    static func askpassScript() throws -> URL {
        let directory = try privateDirectory()
        let script = directory.appending(path: "askpass")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$VPHONE_KMUTIL_SSH_ASKPASS_SECRET\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)
        return directory
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
