import Foundation
import VPhoneCoreKit
import VPhoneInstaller

/// A device other than a Mac that Monolith installs the way vphone-cli does, all on this phone: Apple's
/// firmware downloaded, prepared and patched by vphone's code, restored by Monolith's engine, then vphone's
/// installer writing the guest system through Monolith's own APFS code.
struct GuestKind: Identifiable, Hashable {
    let id: String          // the product type vphone knows it by
    let title: String
    let symbol: String
    let preset: String      // vphone's patch preset
    let ramMB: Int
    let note: String?       // why it is not offered yet, or what to expect
    var available: Bool { note == nil || !note!.hasPrefix("Not yet") }

    static let all: [GuestKind] = [
        GuestKind(id: "AudioAccessory5,1", title: "HomePod mini", symbol: "homepodmini", preset: "homepod-mini", ramMB: 2048, note: nil),
        GuestKind(id: "Watch7,18", title: "Apple Watch", symbol: "applewatch", preset: "watchos", ramMB: 2048,
                  note: "Installed this way on a Mac; not tried from the phone yet."),
        GuestKind(id: "AppleTV14,1", title: "Apple TV 4K", symbol: "appletv", preset: "tvos", ramMB: 3072,
                  note: "Installed this way on a Mac; not tried from the phone yet."),
        GuestKind(id: "iPhone17,3", title: "iPhone", symbol: "iphone", preset: "standard", ramMB: 4096,
                  note: "Not yet: its GPU driver comes from a cloudOS restore Monolith cannot do yet."),
    ]
}

@MainActor
final class DeviceInstaller: ObservableObject {
    static let shared = DeviceInstaller()

    enum Phase: Equatable { case idle, running, done(String), failed(String) }
    static let stages = ["Download and prepare", "Patch the boot chain", "Restore", "Install the system", "Finish"]

    @Published var phase = Phase.idle
    @Published var stage = 0
    @Published var stepProgress = 0.0
    @Published var title = ""

    var busy: Bool { phase == .running }

    static var resources: URL? { Bundle.main.url(forResource: "VPhoneResources", withExtension: nil) }

    /// vphone's own library: machines being made, and its download cache, in this app's storage.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("vphone", isDirectory: true)
    }

    static func pairings(_ kind: GuestKind) -> [VPhoneFirmwarePairing] {
        if let r = resources { VPhoneResources.monolithBase = r }
        return VPhoneFirmwareCatalog.pairings(for: kind.id)
    }

    func reset() { phase = .idle; stage = 0; stepProgress = 0 }

    func start(_ kind: GuestKind, _ pairing: VPhoneFirmwarePairing, name: String, cpus: Int) {
        guard !busy else { return }
        phase = .running
        stage = 0
        stepProgress = 0
        title = "\(pairing.iosName) on this \(Device.name)"
        Task {
            do {
                let mac = try await run(kind, pairing, name: name, cpus: cpus)
                phase = .done("\(mac.name) is in Devices.")
            } catch {
                HengeLog.log("device-install", "failed: \(error)")
                phase = .failed("\(error)")
            }
        }
    }

    private func run(_ kind: GuestKind, _ pairing: VPhoneFirmwarePairing, name: String, cpus: Int) async throws -> VirtualMac {
        guard let resources = Self.resources else { throw message("This build has no vphone resources (scripts/package_ipa.sh copies them).") }
        guard JITBootstrap.ready else { throw message("Turn on JIT first: the restore runs the device's own restore system.") }
        let root = Self.root
        let library = root.appendingPathComponent("machines", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        setenv("VPHONE_ROOT", root.path, 1) // vphone's IPSW cache goes here too
        VPhoneResources.monolithBase = resources
        let slug = "m-" + UUID().uuidString.prefix(8).lowercased()
        let vm = library.appendingPathComponent(slug, isDirectory: true)
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        HengeLog.log("device-install", "\(kind.title) \(pairing.iosName) as \(name): \(vm.lastPathComponent), ECID \(ecid)")

        // 1. vphone's machine, its patch preset, and the firmware: downloaded, merged, prepared.
        try await off {
            let bundle = try VPhoneBundleOperations.create(.init(
                name: slug, cpuCount: UInt(cpus), memoryMB: UInt64(kind.ramMB), diskSizeGB: 64,
                romSource: VPhoneBundleOperations.defaultROMSource(), sepromSource: VPhoneBundleOperations.defaultSEPROMSource()),
                in: VPhoneLibrary(root: library))
            let identity = try PropertyListSerialization.data(fromPropertyList: ["ECID": ecid], format: .binary, options: 0)
            try bundle.manifest.updating(machineIdentifier: identity, networkConfig: bundle.manifest.networkConfig).write(to: bundle.configURL)
            try MonolithFirmwareCommands.run(["set-patches", "-l", library.path, slug, "--preset", kind.preset])
            try MonolithFirmwareCommands.run(["prepare", "-l", library.path, slug, "--device", kind.id,
                                              "-i", pairing.iosURL, "-c", pairing.cloudosURL])
        }
        // 2. The boot chain and kernel, patched.
        stage = 1
        try await off { try MonolithFirmwareCommands.run(["patch", "-l", library.path, slug]) }

        // 3. The restore: Monolith's engine boots OpenAVB in DFU, idevicerestore restores the prepared tree.
        stage = 2
        let tree = try await off { try FirmwarePipelineLocator.restoreTree(vm) }
        let mac = VirtualMac(name: name, ecid: ecid, seed: 0, ramMB: kind.ramMB, diskBytes: 64 << 30)
        try await restore(vm: vm, tree: tree, mac: mac, cpus: cpus)
        // The OS image was only the restore's: its gigabytes go before the system is written.
        for file in (try? FileManager.default.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "aea" || file.pathExtension == "dmg" {
            if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 1 << 30 { try? FileManager.default.removeItem(at: file) }
        }

        // 4. vphone's installer: vphoned, its daemons and libraries, the guest patches, into the disk image.
        stage = 3
        stepProgress = 0
        try await off {
            let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
            try MonolithCustomFirmware.install(bundle: vm, resources: resources, workParent: tmp)
        }

        // 5. Monolith's own machine: the same files under its names.
        stage = 4
        var made = mac
        let config = try? VPhoneLibrary(root: vm.deletingLastPathComponent()).bundle(named: vm.lastPathComponent)
        if let screen = config?.manifest.screenConfig { made.screenWidth = screen.width; made.screenHeight = screen.height }
        try await off {
            let fm = FileManager.default
            try fm.createDirectory(at: made.directory, withIntermediateDirectories: true)
            for (from, to) in [("OpenAVB.bin", made.rom), ("OpenSEP.bin", made.sepROM), ("nvram.bin", made.aux),
                               ("SEPStorage", made.sepStorage), ("Disk.img", made.disk)] {
                try? fm.removeItem(at: to)
                try fm.moveItem(at: vm.appendingPathComponent(from), to: to)
            }
            try pairing.iosName.write(to: made.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: vm)
        }
        made.osName = pairing.iosName
        Machines.shared.add(made)
        HengeLog.log("device-install", "\(made.name): installed, added to Devices")
        return made
    }

    private func restore(vm: URL, tree: URL, mac: VirtualMac, cpus: Int) async throws {
        var restoring = mac
        restoring.ramMB = max(mac.ramMB, 2048)
        try FileManager.default.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        let ram = GuestMemory.prepare(restoring)
        guard ram >= 2048 else { throw message("The restore needs a few more GB of free storage for the device's memory.") }
        setenv("HV_WRITE_CACHE", "0", 1)
        henge_vm_set_sep(vm.appendingPathComponent("OpenSEP.bin").path, vm.appendingPathComponent("SEPStorage").path)
        let work = vm.appendingPathComponent("restore-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(vm.appendingPathComponent("OpenAVB.bin").path, vm.appendingPathComponent("Disk.img").path,
                                  vm.appendingPathComponent("nvram.bin").path, mac.ecid, tree.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            stepProgress = henge_install_progress()
            let step = Int(henge_install_step())
            if step == 100 { break }
            if step == 101 { throw message("The restore failed. The log (Settings, or Documents/henge.log) says why.") }
            if henge_vm_state() == 2 {
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("The device stopped during the restore (\(String(cString: henge_vm_exit_reason()))).")
            }
        }
        if henge_vm_state() == 1 { henge_vm_stop() }
        for _ in 0..<60 where henge_vm_state() == 1 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: mac.directory) // made again with the finished files
    }

    /// Long synchronous work (vphone's code) off the main thread.
    private func off<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// The prepared restore tree of a vphone machine.
enum FirmwarePipelineLocator {
    static func restoreTree(_ vm: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: vm.path)
        guard let name = names.filter({ $0.hasSuffix("_Restore") }).sorted().last else {
            throw NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: "No prepared restore tree in \(vm.lastPathComponent)."])
        }
        return vm.appendingPathComponent(name, isDirectory: true)
    }
}
