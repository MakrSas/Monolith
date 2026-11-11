// monolith-fw: Monolith's driver for vphone's firmware code. For now: a self-test of
// VPhoneConfinedDirectory on an APFS image (the operations vphone's installer makes).
import Foundation
import VPhoneCoreKit
import VPhoneInstaller

let args = CommandLine.arguments
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
