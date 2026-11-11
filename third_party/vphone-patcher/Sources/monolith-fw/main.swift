// monolith-fw: Monolith's driver for vphone's firmware code. For now: a self-test of
// VPhoneConfinedDirectory on an APFS image (the operations vphone's installer makes).
import Foundation
import VPhoneCoreKit
import VPhoneInstaller
import FirmwarePatcher
import VPhonePatchKit

let args = CommandLine.arguments

/// monolith-fw new LIBRARY NAME RESOURCES [DISK_GB]: a VM folder as `vphone-cli vm new` makes it.
/// monolith-fw prepare VM_FOLDER RESOURCES IPSW CLOUDOS_IPSW [OTA] [DEVICE]
/// monolith-fw patch VM_FOLDER RESOURCES [PRESET]
func command(_ body: () throws -> Void) -> Never {
    do { try body(); print("done"); exit(0) } catch { print("error:", error); exit(1) }
}
if args.count >= 5, args[1] == "new" {
    command {
        VPhoneResources.monolithBase = URL(fileURLWithPath: args[4])
        let library = VPhoneLibrary(root: URL(fileURLWithPath: args[2]))
        let bundle = try VPhoneBundleOperations.create(.init(
            name: args[3], cpuCount: 4, memoryMB: 4096, diskSizeGB: UInt64(args.count > 5 ? Int(args[5]) ?? 64 : 64),
            romSource: VPhoneBundleOperations.defaultROMSource(), sepromSource: VPhoneBundleOperations.defaultSEPROMSource()),
            in: library)
        print("created", bundle.url.path)
    }
}
if args.count >= 6, args[1] == "prepare" {
    command {
        let resources = URL(fileURLWithPath: args[3])
        VPhoneResources.monolithBase = resources
        let vm = URL(fileURLWithPath: args[2])
        let bundle = try VPhoneLibrary(root: vm.deletingLastPathComponent()).bundle(named: vm.lastPathComponent)
        try VPhoneFirmwarePreparer.prepare(iPhoneSource: args[4], cloudOSSource: args[5],
                                           device: args.count > 7 ? args[7] : nil,
                                           otaSource: args.count > 6 && !args[6].isEmpty ? args[6] : nil,
                                           bundle: bundle, resources: VPhoneResources(base: resources))
    }
}
if args.count >= 6, args[1] == "aa-extract" { // aa-extract IMAGE VOLUME PATH ARCHIVE…: one path out of archives
    command {
        let image = try VPhoneAPFSImage(URL(fileURLWithPath: args[2]), writable: true)
        let root = try image.volume(named: args[3])
        var total = 0
        for archive in args[5...] { total += try MonolithAppleArchive.extract(URL(fileURLWithPath: archive), into: root, only: args[4]) }
        try image.commit()
        print("extracted \(total) entries")
    }
}
if args.count >= 2, args[1] == "fw" { // vphone-cli's own `fw …` commands, in this process
    VPhoneResources.monolithBase = ProcessInfo.processInfo.environment["MONOLITH_RESOURCES"].map { URL(fileURLWithPath: $0) }
    MonolithFirmwareCommands.main(Array(args.dropFirst(2)))
}
if args.count >= 4, args[1] == "cfw-install" { // cfw-install VM_FOLDER RESOURCES [env]
    do {
        try MonolithCustomFirmware.install(bundle: URL(fileURLWithPath: args[2]), resources: URL(fileURLWithPath: args[3]),
                                           workParent: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? "/private/var/tmp", environmentOnly: args.count > 4 && args[4] == "env")
        print("installed")
        exit(0)
    } catch {
        print("error:", error)
        exit(1)
    }
}
guard args.count >= 3, args[1] == "selftest" else {
    print("usage: monolith-fw selftest IMAGE [VOLUME]")
    exit(2)
}
do {
    let image = try VPhoneAPFSImage(URL(fileURLWithPath: args[2]), writable: true)
    print("volumes:", image.volumeNames)
    let root = try image.volume(named: args.count > 3 ? args[3] : image.volumeNames[0])
    let lib = try root.directory("usr/local/lib/vphone", create: true)
    try lib.writeFile("hello.dylib", contents: Data(repeating: 0x41, count: 70_000), mode: 0o755, owner: (0, 0))
    try root.writeFile("usr/local/lib/vphone/conf.plist", contents: Data("<plist/>".utf8), mode: 0o644)
    try root.createSymlink(target: "vphone/hello.dylib", at: "usr/local/lib/hello.dylib")
    try root.copyFile(from: "usr/local/lib/vphone/conf.plist", to: "usr/local/lib/vphone/conf2.plist")
    try root.rename("usr/local/lib/vphone/conf2.plist", to: "usr/local/conf-moved.plist")
    try root.setMode("usr/local/lib/vphone/hello.dylib", 0o700)
    try root.copyTree(from: root.directory("usr/local/lib/vphone"), to: "usr/local/copied")
    print("removed bytes:", try root.removeItem("usr/local/copied/hello.dylib"))
    print("entries:", try lib.entries().sorted())
    print("link:", try root.readLink("usr/local/lib/hello.dylib") ?? "-")
    print("conf:", String(decoding: try root.readData("usr/local/conf-moved.plist"), as: UTF8.self))
    print("mode:", String(try root.status("usr/local/lib/vphone/hello.dylib")!.st_mode, radix: 8))
    try image.commit()
    print("committed")
} catch {
    print("error:", error)
    exit(1)
}
