// Native KDK extraction: recover inputs, export executables, and reconstruct
// bundle metadata. The destination appears only after all entries succeed.
import CryptoKit
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

enum KDKExtraction {
    /// Included in extraction and mix cache keys. Bump when output changes.
    static let revision = "native-kdk-1"

    static func extract(_ payload: Data, to parent: URL, known: [UInt64: [String]] = [:],
                        progress: (String) -> Void = { _ in }) throws -> URL
    {
        let collection = try KDKKernelCollection(payload)
        let recovery = try KDKRecovery(collection)
        let infos = try collection.prelinkInfo()
        guard let first = collection.entries.first(where: { $0.identifier != "com.apple.kernel" }),
              let info = infos.first(where: { $0["CFBundleIdentifier"] as? String == first.identifier }),
              let version = info["DTPlatformVersion"] as? String,
              let build = info["DTPlatformBuild"] as? String,
              let platform = info["DTPlatformName"] as? String
        else {
            throw PatcherError.invalidFormat("kernelcache lacks KDK platform metadata")
        }
        let name = "KDK_\(version)_\(build).kdk"
        let destination = try child(parent, name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw PatcherError.invalidFormat("KDK already exists: \(destination.path)") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".kdk-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        progress("Recovering references from \(collection.entries.count) fileset images")
        let references = try recovery.recover()
        let symbols = try recovery.synthesizeSymbols(references: references, known: known)
        // Unlike an exploratory exporter, the production mix must not silently
        // leave unresolved absolute pointers pointing into the old collection.
        guard symbols.unresolved.isEmpty else {
            let examples = symbols.unresolved.prefix(5).map { "\($0.0) -> 0x\(String($0.1, radix: 16))" }.joined(separator: ", ")
            throw PatcherError.invalidFormat("native KDK has \(symbols.unresolved.count) unresolved imports: \(examples)")
        }
        let library = staging.appending(path: "System/Library"), extensions = library.appending(path: "Extensions")
        var identity = build + version
        if let uuid = collection.commands.first(where: { $0.command == KDKMachO.lcUUID }) {
            identity = uuidString(Array(uuid.bytes[8 ..< 24])).uppercased()
        }
        var systemInfo = ["BuildID": buildID(identity), "ProductBuildVersion": build,
                          "ProductUserVisibleVersion": version, "ProductVersion": version]
        if let product = ["macosx": "macOS", "iphoneos": "iPhoneOS", "watchos": "Watch OS", "appletvos": "Apple TVOS", "xros": "xrOS"][platform] {
            systemInfo["ProductName"] = product
        }
        try writePlist(systemInfo, to: library.appending(path: "CoreServices/SystemVersion.plist"))
        for entry in collection.entries {
            var image = recovery.images[entry.identifier]!
            let output: URL
            let base: UInt64
            if entry.identifier == "com.apple.kernel" {
                guard let thread = collection.unixThread,
                      image.commands.filter({ $0.command == KDKMachO.lcUnixThread }).count == 1,
                      let index = image.commands.firstIndex(where: { $0.command == KDKMachO.lcUnixThread })
                else {
                    throw PatcherError.invalidFormat("expected one kernel and collection LC_UNIXTHREAD")
                }
                image.commands[index] = thread
                base = collection.baseAddress
                output = library.appending(path: "Kernels/kernel")
            } else {
                guard let info = infos.first(where: { $0["CFBundleIdentifier"] as? String == entry.identifier }) else {
                    throw PatcherError.invalidFormat("missing prelink metadata for \(entry.identifier)")
                }
                let paths = try bundleLayout(extensions, identifier: entry.identifier, info: info)
                guard let executable = paths.executable else { throw PatcherError.invalidFormat("no executable path for \(entry.identifier)") }
                base = 0
                output = executable
                try writePlist(standaloneInfo(info), to: paths.plist)
            }
            var writer = try KDKImageExport(collection: collection, image: image, baseAddress: base,
                                            symbols: (symbols.exports[entry.identifier] ?? []) + (symbols.imports[entry.identifier] ?? []),
                                            references: references[entry.identifier] ?? [], addressOnlyBinds: true)
            try write(writer.export(), to: output)
            progress("Exported \(entry.identifier)")
        }
        for info in infos where info["_PrelinkExecutableRelativePath"] == nil {
            guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
            let paths = try bundleLayout(extensions, identifier: id, info: info)
            try writePlist(standaloneInfo(info), to: paths.plist)
        }
        try pseudoExtensions(extensions, kernel: recovery.images["com.apple.kernel"]!, collection: collection, infos: infos)
        try VPhoneHostFilePermissions.makeAccessible(at: staging)
        try fm.moveItem(at: staging, to: destination)
        progress("Created \(name)")
        return destination
    }

    struct BundlePaths { var bundle: URL
        var plist: URL
        var executable: URL?
    }

    static func child(_ root: URL, _ relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw PatcherError.invalidFormat("unsafe KDK relative path: \(relative)")
        }
        return root.appending(path: relative)
    }

    static func bundleLayout(_ extensions: URL, identifier: String, info: [String: Any]) throws -> BundlePaths {
        let prefix = "/System/Library/Extensions/"
        var relative = identifier + ".kext"
        if let path = info["_PrelinkBundlePath"] as? String, path.hasPrefix(prefix) {
            relative = String(path.dropFirst(prefix.count))
        }
        let bundle = try child(extensions, relative)
        var executable = info["_PrelinkExecutableRelativePath"] as? String ?? ""
        var contents = executable.hasPrefix("Contents/")
        if executable.isEmpty {
            if let platform = info["DTPlatformName"] as? String {
                contents = platform == "macosx"
            } else {
                contents = (info["CFBundleSupportedPlatforms"] as? [String] ?? []).contains("MacOSX")
            }
            if let name = info["CFBundleExecutable"] as? String, !name.isEmpty {
                executable = (contents ? "Contents/MacOS/" : "") + name
            }
        }
        return try .init(bundle: bundle, plist: bundle.appending(path: contents ? "Contents/Info.plist" : "Info.plist"),
                         executable: executable.isEmpty ? nil : child(bundle, executable))
    }

    static func standaloneInfo(_ info: [String: Any]) -> [String: Any] {
        info.filter { !$0.key.hasPrefix("_Prelink") && !["_InfoPlistDigest", "OSBundleUUID", "CFBundleNumericVersion"].contains($0.key) }
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func writePlist(_ plist: [String: Any], to url: URL) throws {
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: url)
    }

    static func uuidString(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0 ..< 4].joined(), hex[4 ..< 6].joined(), hex[6 ..< 8].joined(), hex[8 ..< 10].joined(), hex[10 ..< 16].joined()].joined(separator: "-")
    }

    static func buildID(_ identity: String) -> String {
        // UUID v5, OID namespace, identical to google/uuid.NewSHA1.
        var namespace = UUID(uuidString: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")!.uuid
        var material = withUnsafeBytes(of: &namespace) { Data($0) }
        material += Data(identity.utf8)
        var hash = Array(Insecure.SHA1.hash(data: material).prefix(16))
        hash[6] = (hash[6] & 15) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return uuidString(hash)
    }

    static func pseudoExtensions(_ extensions: URL, kernel: KDKImage, collection: KDKKernelCollection, infos: [[String: Any]]) throws {
        var sets: [String: [String]] = [:]
        if let section = kernel.sections.first(where: { $0.segmentName == "__LINKINFO" && $0.name == "__symbolsets" }) {
            let plist = try collection.plist(at: section.address, count: section.size)
            for set in plist["SymbolsSets"] as? [[String: Any]] ?? [] {
                let id = set["CFBundleIdentifier"] as? String ?? ""
                for symbol in set["Symbols"] as? [[String: Any]] ?? [] {
                    if let name = symbol["SymbolName"] as? String, !name.isEmpty {
                        sets[id, default: []].append(name)
                    }
                }
            }
        }
        var version = ""
        for info in infos {
            guard info["OSKernelResource"] as? Bool == true, let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty, info["_PrelinkExecutableRelativePath"] == nil else { continue }
            let id = info["CFBundleIdentifier"] as? String ?? ""
            if version.isEmpty {
                version = info["CFBundleVersion"] as? String ?? ""
            }
            let paths = try bundleLayout(extensions, identifier: id, info: info)
            let uuid = info["OSBundleUUID"] as? Data
            try write(pseudoMachO(uuid: uuid?.count == 16 ? Array(uuid!) : [], symbols: sets[id] ?? []), to: child(paths.bundle, executable))
        }
        let system = extensions.appending(path: "System.kext/Info.plist")
        if version.isEmpty || FileManager.default.fileExists(atPath: system.path) {
            return
        }
        try writePlist([
            "CFBundleDevelopmentRegion": "English", "CFBundleGetInfoString": "System Resource Pseudoextension, Apple Inc, " + version,
            "CFBundleIdentifier": "com.apple.kernel", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "System Resource Pseudoextension",
            "CFBundlePackageType": "KEXT", "CFBundleShortVersionString": version, "CFBundleSignature": "????", "CFBundleVersion": version,
            "OSBundleAllowUserLoad": true, "OSBundleCompatibleVersion": version, "OSBundleRequired": "Root", "OSKernelResource": true,
        ], to: system)
    }

    static func pseudoMachO(uuid: [UInt8], symbols: [String]) -> Data {
        var strings: [UInt8] = [0x20, 0], table: [UInt8] = []
        for name in symbols.sorted() {
            table.appendLE(UInt32(strings.count))
            table += [1, 0]
            table.appendLE(UInt16(0))
            table.appendLE(UInt64(0))
            strings += name.utf8
            strings.append(0)
        }
        strings.pad(to: 8)
        let size = UInt64(table.count + strings.count)
        var output = KDKMachO.Header(magic: KDKMachO.magic64, cpuType: 0x0100_000C, cpuSubtype: 2, fileType: 0xB,
                                     commandCount: 3, commandsSize: 120, flags: 2, reserved: 0).bytes
        KDKMachO.write(.init(command: KDKMachO.lcSegment64, commandSize: 72, name: "__LINKEDIT", address: 0,
                             memorySize: KDKImageExport.aligned(size), fileOffset: 0x1000, fileSize: size,
                             maxProtection: 1, initialProtection: 1, sectionCount: 0, flags: 4, sections: []), to: &output)
        for word: UInt32 in [KDKMachO.lcSymtab, 24, 0x1000, UInt32(symbols.count), 0x1000 + UInt32(table.count), UInt32(strings.count), KDKMachO.lcUUID, 24] {
            output.appendLE(word)
        }
        output += uuid.prefix(16)
        output.padTo(32 + 120)
        output.padTo(0x1000)
        output += table
        output += strings
        return Data(output)
    }
}
