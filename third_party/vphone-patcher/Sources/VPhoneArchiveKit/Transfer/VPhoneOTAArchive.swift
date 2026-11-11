import AppleArchive
import ArchiveKit
import CryptoKit
import Darwin
import Foundation
import System
import VPhoneCoreKit

/// A full OTA update, read with the system AppleArchive framework: no `ipsw`,
/// no `aea` or `aa` process, nothing from Homebrew.
///
/// Newer TV OTAs are AEA files (`AEA1`): an Apple Archive encrypted and
/// authenticated with a symmetric key that Apple does not publish and AppleDB
/// records. The archive inside is segmented: its top-level entries are
/// metadata (`TYP=M`), and each one whose `YOP` is `E` (extract) carries in its
/// `DAT` blob another, uncompressed Apple Archive holding the next run of
/// files. `YOP=M` is the segment manifest and `YOP=O` the owner and mode
/// fix-ups applied after extraction, neither of which staging needs. An
/// archive that `aea decrypt` already wrote out (`AA01`, or a `pbz*`
/// compressed one) is read the same way, without a key.
/// HomePod full OTAs may instead use ZIP, read through bundled libarchive.
///
/// Members stream from the file to their destination in fixed-size blocks,
/// so a multi-gigabyte OTA is read once and never held in memory.
public enum VPhoneOTAArchive {
    public enum Error: Swift.Error, LocalizedError {
        case missingFile(URL)
        case notAnOTA(URL)
        case invalidKey
        case keyRequired(URL)
        case wrongKey(URL)
        case unreadable(URL, String)
        case missingMember(String, URL)
        case wrongDevice(URL, productTypes: [String], expected: String)
        case wrongBuild(URL, build: String, expected: String)
        case unsupportedVersion(URL, productType: String, version: String)
        case inconsistentChunks(URL, String)
        case unexpectedSize(URL, expected: Int64, actual: Int64)
        case existingUserland(URL)
        case noSource(String)
        case deltaUpdate(URL)
        case needsNewerMacOS(URL, minimum: Int)

        public var errorDescription: String? {
            switch self {
            case let .missingFile(file):
                "OTA not found at \(file.path). Check the path and try again."
            case let .notAnOTA(file):
                "\(file.lastPathComponent) is not an OTA: choose the device's full OTA (.aea, .zip or decrypted Apple Archive)."
            case .invalidKey:
                "The OTA key must be 32 bytes in base64, as AppleDB lists it under the OTA's decryptionKey."
            case let .keyRequired(file):
                "\(file.lastPathComponent) is encrypted, and the firmware catalog has no key for it. Pass its key with --ota-key."
            case let .wrongKey(file):
                "\(file.lastPathComponent) did not decrypt with the given key. Check the key against AppleDB's entry for this OTA."
            case let .unreadable(file, reason):
                "\(file.lastPathComponent) could not be read: \(reason). Download the OTA again."
            case let .missingMember(member, file):
                "\(file.lastPathComponent) has no \(member). Choose the device's full OTA, not a delta update."
            case let .wrongDevice(file, productTypes, expected):
                "\(file.lastPathComponent) is for \(productTypes.isEmpty ? "no listed device" : productTypes.joined(separator: ", ")), not \(expected). Choose the \(expected) OTA."
            case let .wrongBuild(file, build, expected):
                "\(file.lastPathComponent) is build \(build), but the IPSW is \(expected). The OTA and the IPSW must be the same build."
            case let .unsupportedVersion(file, productType, version):
                "\(file.lastPathComponent) contains tvOS \(version) for \(productType). Apple TV 4K (4th generation) requires tvOS 27.2."
            case let .inconsistentChunks(file, reason):
                "\(file.lastPathComponent) has an inconsistent payload: \(reason). Download the OTA again."
            case let .unexpectedSize(file, expected, actual):
                "\(file.lastPathComponent) is \(actual) bytes, not the \(expected) the catalog lists. Download the OTA again."
            case let .existingUserland(folder):
                "\(folder.path) already exists. Remove it, then prepare the firmware again."
            case let .noSource(productType):
                "The firmware catalog has no OTA for \(productType) at this build. Pass the device's full OTA with --ota-source."
            case let .deltaUpdate(file):
                "\(file.lastPathComponent) requires a pristine prerequisite build. A modified vphone system needs a full OTA, without PrerequisiteBuild."
            case let .needsNewerMacOS(file, minimum):
                "\(file.lastPathComponent) is compressed with LZRAVEN, which macOS \(minimum) and later unpack; this Mac runs macOS \(VPhoneOTARelease.hostMacOSVersion). Create this machine on macOS \(minimum) or later, or choose an earlier release."
            }
        }
    }

    /// What to do with one member, by its archive path.
    public enum Disposition: Sendable {
        case skip
        /// Write it to this file, replacing whatever is there.
        case file(URL)
        /// Read it into memory and hand it to `received`. For small plists only.
        case memory
    }

    /// The largest member `Disposition.memory` takes.
    static let memoryLimit: UInt64 = 64 << 20
    /// Bytes per blob read.
    static let blockSize = 8 << 20

    private static var typKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("TYP") }
    private static var yopKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("YOP") }
    private static var patKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("PAT") }
    private static var datKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("DAT") }
    /// `TYP` and `YOP` values are one ASCII letter.
    private static let regularFile = UInt64(UInt8(ascii: "F"))
    private static let extractSegment = UInt64(UInt8(ascii: "E"))
    private static let directoryEntry = UInt64(UInt8(ascii: "D"))
    private static let symlinkEntry = UInt64(UInt8(ascii: "L"))
    private static let hardLinkEntry = UInt64(UInt8(ascii: "H"))
    private static let metadataEntry = UInt64(UInt8(ascii: "M"))
    private static let payloadEntryTypes: Set = [regularFile, directoryEntry, symlinkEntry, hardLinkEntry]

    // MARK: - Key

    /// The symmetric key from base64, with or without `aea`'s `base64:` prefix.
    public static func symmetricKey(_ text: String) throws -> SymmetricKey {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("base64:") {
            text.removeFirst("base64:".count)
        }
        guard let data = Data(base64Encoded: text), data.count == 32 else {
            throw Error.invalidKey
        }
        return SymmetricKey(data: data)
    }

    // MARK: - Reading

    /// Streams every regular file of the OTA's archive, in archive order, to
    /// where `select` sends it. `received` is called after each member that
    /// was not skipped, with its bytes for `.memory`; throwing from it stops
    /// the read before any later member is written.
    public static func readMembers(
        _ ota: URL,
        key: String?,
        select: (String) throws -> Disposition,
        received: (String, Data?) throws -> Void,
    ) throws {
        if try isZIP(ota) {
            try readZIPMembers(ota, select: select, received: received)
            return
        }
        let opened = try openArchive(ota, key: key)
        let outer = opened.archive
        var buffer = [UInt8](repeating: 0, count: blockSize)
        // AppleArchive's wrappers close their stream when released, and a
        // decoder does not keep the stream it reads: every layer stays
        // referenced until the read ends.
        try withExtendedLifetime(opened) {
            while let header = try readHeader(outer, of: ota) {
                if case .uint(_, extractSegment)? = header.field(forKey: yopKey),
                   case let .blob(_, size, _)? = header.field(forKey: datKey)
                {
                    let segment = SegmentByteStream(outer: outer, size: size)
                    guard let bytes = ArchiveByteStream.customStream(instance: segment),
                          let inner = ArchiveStream.decodeStream(readingFrom: bytes)
                    else {
                        throw Error.unreadable(ota, "an extract segment is not an Apple Archive")
                    }
                    try withExtendedLifetime((segment, bytes)) {
                        while let entry = try readHeader(inner, of: ota) {
                            try member(entry, of: inner, in: ota, buffer: &buffer, select: select, received: received)
                        }
                        try inner.close()
                        try bytes.close()
                    }
                } else {
                    // A plain archive keeps its files at the top level.
                    try member(header, of: outer, in: ota, buffer: &buffer, select: select, received: received)
                }
            }
            try outer.close()
            for stream in opened.streams.reversed() {
                try stream.close()
            }
        }
    }

    /// HomePod full OTAs still use ZIP. Their Info.plist may follow the
    /// payload physically, so visit the two identity/policy records first.
    /// libarchive seeks over skipped ZIP members; no temporary full extraction
    /// and no archive-provided pathname is ever used as a destination.
    private static func readZIPMembers(
        _ ota: URL,
        select: (String) throws -> Disposition,
        received: (String, Data?) throws -> Void
    ) throws {
        let metadata: Set = ["AssetData/Info.plist", manifestPath]
        for metadataPass in [true, false] {
            try withArchiveLocale {
                guard let reader = archive_read_new() else { throw Error.unreadable(ota, "cannot create ZIP reader") }
                defer { archive_read_free(reader) }
                archive_read_support_format_zip(reader)
                guard archive_read_open_filename(reader, ota.path, blockSize) == ARCHIVE_OK else {
                    throw Error.unreadable(ota, archiveErrorString(reader))
                }
                var seen: Set<String> = []
                var buffer = [UInt8](repeating: 0, count: blockSize)
                while true {
                    var entry: OpaquePointer?
                    let status = archive_read_next_header(reader, &entry)
                    if status == ARCHIVE_EOF { break }
                    guard status == ARCHIVE_OK, let entry,
                          let rawPath = archive_entry_pathname(entry) else {
                        throw Error.unreadable(ota, archiveErrorString(reader))
                    }
                    let path = String(cString: rawPath)
                    guard seen.insert(path).inserted else { throw Error.unreadable(ota, "duplicate ZIP member \(path)") }
                    guard metadata.contains(path) == metadataPass,
                          mode_t(archive_entry_filetype(entry)) == S_IFREG,
                          archive_entry_hardlink(entry) == nil else {
                        archive_read_data_skip(reader)
                        continue
                    }
                    let disposition = try select(path)
                    if case .skip = disposition {
                        archive_read_data_skip(reader)
                        continue
                    }
                    let declaredSize = archive_entry_size(entry)
                    guard declaredSize >= 0 else { throw Error.unreadable(ota, "negative ZIP member size") }
                    var data: Data?
                    let output: FileHandle?
                    switch disposition {
                    case .skip: preconditionFailure()
                    case .memory:
                        guard UInt64(declaredSize) <= memoryLimit else { throw Error.unreadable(ota, "\(path) exceeds the metadata limit") }
                        data = Data()
                        output = nil
                    case let .file(destination):
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                            throw Error.unreadable(ota, "cannot create \(destination.path)")
                        }
                        output = try FileHandle(forWritingTo: destination)
                    }
                    defer { try? output?.close() }
                    var total: Int64 = 0
                    while true {
                        let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                        if count == 0 { break }
                        guard count > 0 else { throw Error.unreadable(ota, archiveErrorString(reader)) }
                        total += Int64(count)
                        guard total <= declaredSize else { throw Error.unreadable(ota, "\(path) exceeds its ZIP size") }
                        let chunk = Data(buffer.prefix(Int(count)))
                        if output != nil { try output?.write(contentsOf: chunk) } else { data?.append(chunk) }
                    }
                    guard total == declaredSize else { throw Error.unreadable(ota, "\(path) is truncated") }
                    try output?.close()
                    try received(path, data)
                }
                guard archive_read_close(reader) == ARCHIVE_OK else { throw Error.unreadable(ota, archiveErrorString(reader)) }
            }
        }
    }

    private static func isZIP(_ file: URL) throws -> Bool {
        try readMagic(file) == Data([0x50, 0x4b, 0x03, 0x04])
    }

    private static func isDownloadMagic(_ data: Data) -> Bool {
        data == Data("AEA1".utf8) || data == Data([0x50, 0x4b, 0x03, 0x04])
    }

    private struct OpenedArchive {
        let archive: ArchiveStream
        /// The file, then any decryption or decompression over it.
        let streams: [ArchiveByteStream]
    }

    /// The decoded top-level archive: decrypted when the file is AEA,
    /// decompressed when it is a compressed archive.
    private static func openArchive(_ ota: URL, key: String?) throws -> OpenedArchive {
        let magic = try readMagic(ota)
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(ota.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644),
        ) else {
            throw Error.unreadable(ota, "it could not be opened")
        }
        let plain: ArchiveByteStream
        switch magic.prefix(3) {
        case Data("AEA".utf8):
            guard let key else { throw Error.keyRequired(ota) }
            let symmetric = try symmetricKey(key)
            guard let context = ArchiveEncryptionContext(from: file) else {
                throw Error.unreadable(ota, "its AEA header is damaged")
            }
            try context.setSymmetricKey(symmetric)
            guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context) else {
                throw Error.wrongKey(ota)
            }
            plain = decrypted
        case Data("pbz".utf8):
            try checkCompression(magic, of: ota)
            guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
                throw Error.unreadable(ota, "it could not be decompressed")
            }
            plain = decompressed
        case Data("AA0".utf8), Data("YAA".utf8):
            plain = file
        default:
            throw Error.notAnOTA(ota)
        }
        guard let archive = ArchiveStream.decodeStream(readingFrom: plain) else {
            throw Error.notAnOTA(ota)
        }
        return OpenedArchive(archive: archive, streams: plain === file ? [file] : [file, plain])
    }

    /// LZRAVEN (`pbzm`) came with macOS 27's libcompression: an older Mac
    /// cannot unpack a payload compressed with it.
    static let lzravenMagic = Data("pbzm".utf8)

    static func checkCompression(_ magic: Data, of file: URL) throws {
        let minimum = VPhoneOTARelease.lzravenMinimumMacOS
        guard magic.prefix(4) == lzravenMagic, VPhoneOTARelease.hostMacOS < minimum else { return }
        throw Error.needsNewerMacOS(file, minimum: minimum)
    }

    private static func readMagic(_ file: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else { throw Error.missingFile(file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4) ?? Data()
    }

    /// AppleArchive reports a failed AEA authentication or a truncated file
    /// as an error from the read; name the file it came from.
    private static func readHeader(_ stream: ArchiveStream, of ota: URL) throws -> ArchiveHeader? {
        do {
            return try stream.readHeader()
        } catch {
            throw Error.unreadable(ota, "\(error)")
        }
    }

    private static func member(
        _ header: ArchiveHeader,
        of stream: ArchiveStream,
        in ota: URL,
        buffer: inout [UInt8],
        select: (String) throws -> Disposition,
        received: (String, Data?) throws -> Void,
    ) throws {
        guard case .uint(_, regularFile)? = header.field(forKey: typKey),
              case let .string(_, path)? = header.field(forKey: patKey)
        else { return }
        let size: UInt64 = if case let .blob(_, size, _)? = header.field(forKey: datKey) { size } else { 0 }
        switch try select(path) {
        case .skip:
            return
        case let .file(destination):
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try readBlob(size, from: stream, in: ota, buffer: &buffer) { try handle.write(contentsOf: $0) }
            try handle.close()
            try received(path, nil)
        case .memory:
            guard size <= memoryLimit else {
                throw Error.unreadable(ota, "\(path) is \(size) bytes, larger than expected")
            }
            var data = Data(capacity: Int(size))
            try readBlob(size, from: stream, in: ota, buffer: &buffer) { data.append($0) }
            try received(path, data)
        }
    }

    private static func readBlob(
        _ size: UInt64,
        from stream: ArchiveStream,
        in ota: URL,
        buffer: inout [UInt8],
        consume: (Data) throws -> Void,
    ) throws {
        var left = size
        while left > 0 {
            let count = Int(min(UInt64(buffer.count), left))
            let block = try buffer.withUnsafeMutableBytes { raw in
                let slice = UnsafeMutableRawBufferPointer(rebasing: raw[0 ..< count])
                do {
                    try stream.readBlob(key: datKey, into: slice)
                } catch {
                    throw Error.unreadable(ota, "\(error)")
                }
                return Data(slice)
            }
            try consume(block)
            left -= UInt64(count)
        }
    }

    /// One extract segment's `DAT` blob, read in order from the enclosing
    /// archive as the segment's own decoder asks for it.
    private final class SegmentByteStream: ArchiveByteStreamProtocol {
        let outer: ArchiveStream
        var remaining: UInt64

        init(outer: ArchiveStream, size: UInt64) {
            self.outer = outer
            remaining = size
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            let count = Int(min(UInt64(buffer.count), remaining))
            guard count > 0 else { return 0 }
            try outer.readBlob(key: VPhoneOTAArchive.datKey, into: UnsafeMutableRawBufferPointer(rebasing: buffer[0 ..< count]))
            remaining -= UInt64(count)
            return count
        }

        func read(into _: UnsafeMutableRawBufferPointer, atOffset _: Int64) throws -> Int {
            throw Errno.notSupported
        }

        func write(from _: UnsafeRawBufferPointer) throws -> Int {
            throw Errno.notSupported
        }

        func write(from _: UnsafeRawBufferPointer, atOffset _: Int64) throws -> Int {
            throw Errno.notSupported
        }

        func seek(toOffset _: Int64, relativeTo _: FileDescriptor.SeekOrigin) throws -> Int64 {
            throw Errno.notSupported
        }

        func cancel() {}

        func close() throws {}
    }

    // MARK: - Userland

    /// The OTA's restore manifest, its device tree, and the root filesystem
    /// payload: `payloadv2/payload.NNN`, each an Apple Archive of part of
    /// the System volume with its owners, modes, flags and compression, and
    /// `payload_chunks.txt`, which numbers them.
    static let manifestPath = "AssetData/boot/BuildManifest.plist"
    static let firmwarePrefix = "AssetData/boot/"
    static let payloadPrefix = "AssetData/payloadv2/"
    public static let chunkListName = "payload_chunks.txt"
    public static let hardLinkListName = "links.txt"
    /// The VM folder's copy of the payload, which `cfw install` extracts
    /// over the restored System volume (`system-tv-exp-ota_userland`).
    public static let userlandDirectoryName = "OTAUserland"

    public struct StagedUserland: Sendable, Equatable {
        public let version: String
        public let build: String
        /// The device's own `DeviceTree.<board>.im4p`.
        public let deviceTree: URL
        /// `payload.NNN`, in order.
        public let chunks: [String]
    }

    /// Takes from `ota` what an OTA-userland guest needs: `device`'s device
    /// tree into `deviceTreeDirectory`, beside the base IPSW's, and the payload
    /// chunks with their list into `userlandDirectory`, which must not exist.
    /// The OTA must be for `device` and of `build`, the base IPSW's; that is
    /// checked from its manifest, which comes before the payload, so a wrong
    /// OTA stops before the gigabytes of chunks are written. The folder is
    /// created next to `userlandDirectory` and renamed into place complete.
    public static func stageUserland(
        from ota: URL,
        key: String?,
        device: VPhoneGuestDevice,
        build: String,
        deviceTreeDirectory: URL,
        userlandDirectory: URL,
        requireFullUpdate: Bool = false,
        progress: ((String) -> Void)? = nil,
    ) throws -> StagedUserland {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: userlandDirectory.path) else { throw Error.existingUserland(userlandDirectory) }
        let pending = userlandDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(userlandDirectory.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: pending) }

        let deviceTreeName = (device.boardDeviceTreePath as NSString).lastPathComponent
        let deviceTreeMember = firmwarePrefix + device.boardDeviceTreePath
        let deviceTree = deviceTreeDirectory.appendingPathComponent(deviceTreeName)
        var identity: (version: String, build: String)?
        var wroteDeviceTree = false
        var chunks: [String] = []
        var chunkList: Data?
        var linkList: Data?
        var checkedFullUpdate = false

        try readMembers(ota, key: key, select: { path in
            if requireFullUpdate, path == "AssetData/Info.plist" { return .memory }
            if path == manifestPath { return .memory }
            if path == deviceTreeMember {
                guard identity != nil else { throw Error.missingMember(manifestPath, ota) }
                return .file(deviceTree)
            }
            guard path.hasPrefix(payloadPrefix) else { return .skip }
            let name = String(path.dropFirst(payloadPrefix.count))
            if name == chunkListName { return .memory }
            if name == hardLinkListName { return .memory }
            guard isChunkName(name) else { return .skip }
            guard identity != nil else { throw Error.missingMember(manifestPath, ota) }
            if requireFullUpdate, !checkedFullUpdate {
                throw Error.missingMember("AssetData/Info.plist before the payload", ota)
            }
            return .file(pending.appendingPathComponent(name))
        }, received: { path, data in
            if requireFullUpdate, path == "AssetData/Info.plist" {
                try checkFullUpdateInfo(data ?? Data(), of: ota)
                checkedFullUpdate = true
            } else if path == manifestPath {
                identity = try checkManifest(data ?? Data(), of: ota, device: device, build: build)
                progress?("OTA \(identity!.version) (\(identity!.build)) for \(device.productType)")
            } else if path == deviceTreeMember {
                wroteDeviceTree = true
            } else if path == payloadPrefix + chunkListName {
                chunkList = data
            } else if path == payloadPrefix + hardLinkListName {
                linkList = data
            } else {
                let name = String(path.dropFirst(payloadPrefix.count))
                // Each chunk as it lands, so an LZRAVEN payload is refused at
                // its first chunk, before the rest is written.
                try checkCompression(readMagic(pending.appendingPathComponent(name)), of: ota)
                chunks.append(name)
                progress?(name)
            }
        })

        guard let identity else { throw Error.missingMember(manifestPath, ota) }
        guard wroteDeviceTree else { throw Error.missingMember(deviceTreeMember, ota) }
        guard let chunkList else { throw Error.missingMember(payloadPrefix + chunkListName, ota) }
        chunks.sort()
        try checkChunks(chunks, list: chunkList, of: ota)
        if requireFullUpdate {
            guard let linkList else { throw Error.missingMember(payloadPrefix + hardLinkListName, ota) }
            try validatePayloadPaths(chunks.map { pending.appendingPathComponent($0) }, hardLinks: linkList)
        }
        if let linkList {
            // A full update already parsed it while validating the payload.
            if !requireFullUpdate { _ = try parseHardLinks(linkList) }
            try linkList.write(to: pending.appendingPathComponent(hardLinkListName))
        }
        try chunkList.write(to: pending.appendingPathComponent(chunkListName))
        try fm.moveItem(at: pending, to: userlandDirectory)
        try VPhoneHostFilePermissions.makeAccessible(at: userlandDirectory)
        return StagedUserland(version: identity.version, build: identity.build, deviceTree: deviceTree, chunks: chunks)
    }

    /// The OTA's version and build, after checking that it is for `device`
    /// and of `build`, read from its manifest without going further: a wrong
    /// OTA or key is found before an IPSW is unpacked for it.
    public static func checkIdentity(
        of ota: URL,
        key: String?,
        device: VPhoneGuestDevice,
        build: String? = nil,
    ) throws -> (version: String, build: String) {
        struct Found: Swift.Error {}
        var identity: (version: String, build: String)?
        do {
            try readMembers(ota, key: key, select: { $0 == manifestPath ? .memory : .skip }, received: { _, data in
                identity = try checkManifest(data ?? Data(), of: ota, device: device, build: build)
                throw Found()
            })
        } catch is Found {}
        guard let identity else { throw Error.missingMember(manifestPath, ota) }
        return identity
    }

    /// `payload.NNN`: digits only, so no name the archive supplies can leave
    /// the folder.
    public static func isChunkName(_ name: String) -> Bool {
        guard name.hasPrefix("payload.") else { return false }
        let number = name.dropFirst("payload.".count)
        return !number.isEmpty && number.allSatisfy(\.isASCIIDigit)
    }

    /// An already modified system cannot satisfy a delta's source hashes.
    /// Reject it before staging any payload, even if its target manifest matches.
    static func checkFullUpdateInfo(_ data: Data, of ota: URL) throws {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Error.unreadable(ota, "its AssetData/Info.plist is malformed")
        }
        // OTA asset metadata has used both a flat dictionary and MobileAssetProperties.
        let properties = info["MobileAssetProperties"] as? [String: Any] ?? info
        for key in ["PrerequisiteBuild", "PrerequisiteOSVersion"] {
            if let value = properties[key] {
                if let text = value as? String, text.isEmpty { continue }
                if let list = value as? [String], list.isEmpty { continue }
                throw Error.deltaUpdate(ota)
            }
        }
    }

    /// Before a privileged extraction, inspect every chunk as one filesystem.
    /// Absolute symlink targets are normal in a guest; a member below such a
    /// link is not. No extraction is attempted until all chunks pass.
    public static func validatePayloadPaths(_ chunks: [URL], hardLinks linkList: Data? = nil) throws {
        var nodes: [String: UInt64] = [:]
        var hardLinks: [String: String] = [:]
        func canonical(_ path: String, file: URL) throws -> String {
            var path = path
            while path.hasPrefix("./") { path.removeFirst(2) }
            if path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty || path == "." { return "" }
            guard VPhoneSystemTrim.isSafeRelativePath(path) else {
                throw Error.unreadable(file, "unsafe payload path: \(path)")
            }
            return path
        }
        for chunk in chunks {
            let opened = try openArchive(chunk, key: nil)
            try withExtendedLifetime(opened) {
                defer {
                    try? opened.archive.close()
                    for stream in opened.streams.reversed() { try? stream.close() }
                }
                while let header = try readHeader(opened.archive, of: chunk) {
                    guard case let .uint(_, type)? = header.field(forKey: typKey) else {
                        throw Error.unreadable(chunk, "payload entry has no type")
                    }
                    if type == metadataEntry { continue }
                    guard payloadEntryTypes.contains(type),
                          case let .string(_, rawPath)? = header.field(forKey: patKey) else {
                        throw Error.unreadable(chunk, "payload contains an unsupported filesystem object")
                    }
                    let path = try canonical(rawPath, file: chunk)
                    if path.isEmpty {
                        guard type == directoryEntry else {
                            throw Error.unreadable(chunk, "payload replaces its extraction root")
                        }
                        continue
                    }
                    if let previous = nodes[path], previous != type {
                        throw Error.unreadable(chunk, "payload changes the type of \(path)")
                    }
                    nodes[path] = type
                    if type == hardLinkEntry {
                        guard case let .string(_, target)? = header.field(forKey: ArchiveHeader.FieldKey("LNK")) else {
                            throw Error.unreadable(chunk, "hard link has no target")
                        }
                        hardLinks[path] = try canonical(target, file: chunk)
                    }
                }
            }
        }
        let label = chunks.first ?? URL(fileURLWithPath: "payload")
        if let linkList {
            for link in try parseHardLinks(linkList) {
                guard nodes[link.source] == regularFile, nodes[link.destination] == nil else {
                    throw Error.unreadable(label, "hard link \(link.destination) needs an archived regular source and a new destination")
                }
                nodes[link.destination] = hardLinkEntry
                hardLinks[link.destination] = link.source
            }
        }
        // Each ancestor is checked once: one already seen had its whole chain
        // checked when it was first reached.
        var checkedParents = Set<String>()
        for path in nodes.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, checkedParents.insert(parent).inserted {
                if let type = nodes[parent], type != directoryEntry {
                    throw Error.unreadable(label, "payload member \(path) traverses non-directory \(parent)")
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for (path, target) in hardLinks where nodes[target] != regularFile {
            throw Error.unreadable(label, "hard link \(path) does not target an archived regular file")
        }
    }

    public struct HardLink: Equatable, Sendable {
        public let source: String
        public let destination: String
    }

    /// Full OTAs store duplicate files outside the numbered archives: '='
    /// selects an archived source and each following '+' names a hard link.
    /// Omitting this list leaves otherwise complete framework bundles broken.
    public static func parseHardLinks(_ data: Data) throws -> [HardLink] {
        let label = URL(fileURLWithPath: hardLinkListName)
        guard data.count <= memoryLimit, let text = String(data: data, encoding: .utf8) else {
            throw Error.unreadable(label, "hard-link list is too large or not UTF-8")
        }
        func path(_ raw: Substring) throws -> String {
            let value = String(raw)
            guard VPhoneSystemTrim.isSafeRelativePath(value) else {
                throw Error.unreadable(label, "unsafe hard-link path: \(value)")
            }
            return value
        }
        var source: String?
        var destinations = Set<String>()
        var links: [HardLink] = []
        for row in text.split(whereSeparator: \.isNewline) {
            switch row.first {
            case "=":
                source = try path(row.dropFirst())
            case "+":
                let destination = try path(row.dropFirst())
                guard let source, source != destination, destinations.insert(destination).inserted else {
                    throw Error.unreadable(label, "orphan, self-referencing or duplicate hard link: \(destination)")
                }
                links.append(HardLink(source: source, destination: destination))
            default:
                throw Error.unreadable(label, "unsupported hard-link record")
            }
        }
        return links
    }

    /// Called only on the private stopped-disk clone after validating chunks
    /// together with the list. Both parent walks refuse symlinks and mount
    /// crossings. The inode readback also refuses a changed source leaf.
    @discardableResult
    public static func installHardLinks(_ data: Data, in directory: VPhoneConfinedDirectory) throws -> Int {
        let links = try parseHardLinks(data)
        for link in links {
            // One confined walk per side; the source and the readback use
            // the parents already pinned.
            let from = try directory.parent(of: link.source)
            let to = try directory.parent(of: link.destination)
            let source = try from.directory.openRegularFile(from.leaf)
            guard linkat(from.directory.descriptor, from.leaf, to.directory.descriptor, to.leaf, 0) == 0 else {
                throw VPhoneConfinedDirectoryError.system(link.destination, errno)
            }
            guard try to.directory.refersTo(to.leaf, file: source) else {
                _ = try to.directory.removeItem(to.leaf)
                throw VPhoneConfinedDirectoryError.changedDuringOpen(link.source)
            }
        }
        return links.count
    }

    static func checkManifest(
        _ data: Data,
        of ota: URL,
        device: VPhoneGuestDevice,
        build expected: String?,
    ) throws -> (version: String, build: String) {
        guard let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = manifest["ProductVersion"] as? String,
              let build = manifest["ProductBuildVersion"] as? String
        else {
            throw Error.unreadable(ota, "its BuildManifest.plist is not a restore manifest")
        }
        let types = manifest["SupportedProductTypes"] as? [String] ?? []
        guard types.contains(device.productType) else {
            throw Error.wrongDevice(ota, productTypes: types, expected: device.productType)
        }
        // Check the archive's manifest, including renamed local sources.
        // The new board is admitted only for the 27.2 userland.
        if device == .appleTV18_1, version != "27.2", version != "27.2.0" {
            throw Error.unsupportedVersion(ota, productType: device.productType, version: version)
        }
        if let expected, build != expected { throw Error.wrongBuild(ota, build: build, expected: expected) }
        return (version, build)
    }

    /// `payload_chunks.txt` has one `index: size` line per chunk, numbered
    /// from 0; every listed chunk must be there and nothing else.
    static func checkChunks(_ chunks: [String], list: Data, of ota: URL) throws {
        let lines = String(decoding: list, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let indices = lines.compactMap { Int($0.split(separator: ":").first ?? "") }
        guard !chunks.isEmpty, indices.count == lines.count else {
            throw Error.inconsistentChunks(ota, "\(chunkListName) does not list the chunks")
        }
        guard indices == Array(0 ..< indices.count) else {
            throw Error.inconsistentChunks(ota, "\(chunkListName) is not numbered from 0")
        }
        let numbers = chunks.compactMap { Int($0.dropFirst("payload.".count)) }
        guard numbers == indices else {
            throw Error.inconsistentChunks(ota, "\(chunks.count) chunks for \(indices.count) listed")
        }
    }

    // MARK: - Source

    /// The OTA file to read: `source` when given, a local path read in place
    /// or an HTTP(S) URL downloaded into the cache's `ota` folder; else the
    /// catalog's `release`, downloaded there under its own name unless a copy
    /// of its listed length is already there.
    public static func resolve(
        _ source: String?,
        release: VPhoneOTARelease?,
        in cacheDirectory: URL,
        session: URLSession = URLSession(configuration: .ephemeral),
        connections: Int = VPhoneIPSWCache.defaultDownloadConnections,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil,
    ) async throws -> URL {
        let remote: URL
        let name: String
        var expectedSize: Int64?
        if let source {
            guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme != "file" else {
                let file = URL(string: source).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: file.path) else { throw Error.missingFile(file) }
                return file
            }
            guard scheme == "http" || scheme == "https" else { throw VPhoneIPSWCache.Error.unsupportedSource(source) }
            remote = url
            if let release, release.url == source {
                name = release.fileName
                expectedSize = release.size
            } else {
                name = cacheName(for: url)
            }
        } else if let release, let url = URL(string: release.url) {
            remote = url
            name = release.fileName
            expectedSize = release.size
        } else {
            throw Error.noSource(release?.productType ?? "this device")
        }

        let fm = FileManager.default
        let directory = cacheDirectory.appendingPathComponent(VPhoneOTARelease.cacheDirectoryName, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: directory)
        let cache = directory.appendingPathComponent(name)
        if try reusable(cache, size: expectedSize) {
            return cache
        }
        let pending = directory.appendingPathComponent(".\(name).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: pending) }
        guard fm.createFile(atPath: pending.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        try await VPhoneIPSWCache.download(remote, into: pending, session: session, connections: connections, progress: progress)
        let actual = try (fm.attributesOfItem(atPath: pending.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expectedSize, actual != expectedSize {
            throw Error.unexpectedSize(remote, expected: expectedSize, actual: actual)
        }
        guard try isDownloadMagic(readMagic(pending)) else { throw Error.notAnOTA(remote) }
        if fm.fileExists(atPath: cache.path) {
            try fm.removeItem(at: cache)
        }
        try fm.moveItem(at: pending, to: cache)
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return cache
    }

    /// A cached copy of the right length that starts as an AEA file. One of
    /// another length is a damaged download and is removed.
    static func reusable(_ cache: URL, size: Int64?) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cache.path) else { return false }
        let actual = (try? fm.attributesOfItem(atPath: cache.path)[.size] as? NSNumber)?.int64Value
        let magic = (try? readMagic(cache)) ?? Data()
        if let size, actual != size {
            try fm.removeItem(at: cache)
            return false
        }
        return isDownloadMagic(magic)
    }

    static func cacheName(for url: URL) -> String {
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "-._".unicodeScalars.contains(scalar)
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "ota" : safe)-\(suffix).\(url.pathExtension.lowercased() == "zip" ? "zip" : "aea")"
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
