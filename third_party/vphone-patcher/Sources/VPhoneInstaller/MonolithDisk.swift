// MONOLITH: the installer's disk plumbing (diskutil image attach / info / apfs list, mount_apfs, umount,
// eject) answered by Monolith's own APFS code instead of macOS. The installer asks the same questions
// and gets answers in the same form; volumes it "mounts" are VPhoneAPFSImage volumes, and eject writes
// the changes. On iOS this is the only way; on a Mac, MONOLITH_APFS=1 (or monolith-fw) selects it.
import Foundation
import MonolithAPFS
import VPhoneCoreKit

final class MonolithDisk: @unchecked Sendable {
    static let shared = MonolithDisk()

    var enabled: Bool = {
        #if os(macOS)
        ProcessInfo.processInfo.environment["MONOLITH_APFS"] == "1"
        #else
        true
        #endif
    }()

    private var image: VPhoneAPFSImage?
    private var mounted: [String: Int] = [:] // mount point's name -> volume index
    private let whole = "/dev/disk90", container = "disk91"

    /// The answer to a tool the installer runs, or nil to run the real one.
    func answer(_ path: String, _ arguments: [String]) throws -> String? {
        guard enabled else { return nil }
        let tool = URL(fileURLWithPath: path).lastPathComponent
        switch (tool, arguments.first ?? "") {
        case ("diskutil", "image") where arguments.count >= 2 && arguments[1] == "attach":
            let url = URL(fileURLWithPath: arguments.last!)
            image = try VPhoneAPFSImage(url, writable: true)
            mounted = [:]
            print("[monolith] \(url.lastPathComponent): \(image!.volumeNames.joined(separator: ", "))")
            return "\(whole)\tGUID_partition_scheme\n\(whole)s1\tApple_APFS\n"
        case ("diskutil", "info"):
            return try plist(["APFSContainerReference": container])
        case ("diskutil", "apfs"):
            guard let image else { throw failure("no image attached") }
            let volumes = image.volumeNames.enumerated().map { i, name -> [String: Any] in
                ["DeviceIdentifier": "\(container)s\(i + 1)", "Name": name, "Roles": roles(image.volumeRole(i))]
            }
            return try plist(["Containers": [[
                "ContainerReference": container,
                "PhysicalStores": [["DeviceIdentifier": "disk90s1"]],
                "Volumes": volumes,
            ]]])
        case ("mount_apfs", _):
            guard let device = arguments.dropLast().last, let mountPoint = arguments.last,
                  let n = Int(device.split(separator: "s").last ?? "") else { throw failure("mount_apfs \(arguments)") }
            mounted[URL(fileURLWithPath: mountPoint).lastPathComponent] = n - 1
            return ""
        case ("umount", _), ("diskutil", "unmountDisk"):
            return ""
        case ("diskutil", "eject"):
            if let image {
                try image.commit()
                print("[monolith] \(image.url.lastPathComponent): changes written")
            }
            image = nil
            mounted = [:]
            return ""
        default:
            return nil
        }
    }

    /// A directory of a guest volume as plain files in the host's work folder, for code that opens them
    /// by path; writeBack() puts every file it changed (by modification time) back.
    struct Materialized {
        let url: URL
        let source: VPhoneConfinedDirectory
        let stamps: [String: Date]

        func writeBack() throws {
            var written = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                let file = url.appendingPathComponent(name)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
                if let stamp = stamps[name], let now = attributes[.modificationDate] as? Date, now == stamp { continue }
                let mode = (try source.status(name)).map { $0.st_mode & 0o7777 } ?? 0o644
                let owner = (try source.status(name)).map { ($0.st_uid, $0.st_gid) } ?? (0, 0)
                try source.writeFile(name, contents: Data(contentsOf: file, options: .alwaysMapped), mode: mode, owner: owner)
                written += 1
            }
            try? FileManager.default.removeItem(at: url)
            if written > 0 { print("[monolith] \(written) changed file(s) written back from \(url.lastPathComponent)") }
        }
    }

    static func materialize(_ source: VPhoneConfinedDirectory, into url: URL) throws -> Materialized {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var stamps: [String: Date] = [:]
        for name in try source.entries() {
            guard let s = try source.status(name), s.st_mode & S_IFMT == S_IFREG else { continue }
            let file = url.appendingPathComponent(name)
            try source.readData(name).write(to: file)
            chmod(file.path, s.st_mode & 0o7777 | 0o600)
            stamps[name] = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        }
        return Materialized(url: url, source: source, stamps: stamps)
    }

    /// A "mounted" volume's root, by its mount point's name (system, xart, preboot).
    func volume(mountedAs name: String) throws -> VPhoneConfinedDirectory? {
        guard enabled else { return nil }
        guard let image, let index = mounted[name] else { throw failure("\(name) is not mounted") }
        return try image.volume(named: image.volumeNames[index])
    }

    private func roles(_ role: UInt16) -> [String] {
        switch role {
        case 0x1: ["System"]
        case 0x2: ["User"]
        case 0x4: ["Recovery"]
        case 0x8: ["VM"]
        case 0x10: ["Preboot"]
        case 0x40: ["Data"]
        case 0xc0: ["Update"]
        case 0x100: ["xART"]
        case 0x140: ["Hardware"]
        default: []
        }
    }

    private func plist(_ object: Any) throws -> String {
        String(decoding: try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
    }

    private func failure(_ what: String) -> Error {
        VPhoneConfinedDirectoryError.system("monolith disk: \(what)", EINVAL)
    }
}
