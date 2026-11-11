import System
import AppleArchive
import UIKit
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
    /// A stock kernel checks the system's seal: customised after the restore and sealed again.
    var sealsAfterRestore: Bool { preset == "watchos-monolith" }

    static let all: [GuestKind] = [
        GuestKind(id: "AudioAccessory5,1", title: "HomePod mini", symbol: "homepodmini", preset: "homepod-mini", ramMB: 2048, note: nil),
        GuestKind(id: "HomeAccessory17,1", title: "HomeView", symbol: "homekit", preset: "homeview", ramMB: 3072,
                  note: "Installed the HomePod's way (restore, then vphone's installer); not tried yet."),
        GuestKind(id: "AppleTV14,1", title: "Apple TV 4K", symbol: "appletv", preset: "tvos", ramMB: 3072,
                  note: "Installed the HomePod's way (restore, then vphone's installer); not tried yet."),
        GuestKind(id: "iPhone17,3", title: "iPhone", symbol: "iphone", preset: "standard", ramMB: 4096,
                  note: "Not yet: its GPU driver comes from a cloudOS restore Monolith cannot do yet."),
        GuestKind(id: "Watch7,18", title: "Apple Watch", symbol: "applewatch", preset: "watchos-monolith", ramMB: 2048,
                  note: "New: its system is customised after the restore and sealed again by Monolith; not tried on a phone yet."),
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
    /// The download: bytes so far of how many, and how fast (bytes a second).
    @Published var downloaded: Int64 = 0
    @Published var expected: Int64 = 0
    @Published var speed: Double = 0

    var busy: Bool { phase == .running }

    static var resources: URL? { try? unpackedResources() }

    /// vphone's resources as it expects them: the app's copy, but with guest-resources unpacked from
    /// its archive (shipped packed so a sideloader's re-signing cannot touch the guest's binaries).
    nonisolated static func unpackedResources() throws -> URL? {
        guard let bundled = Bundle.main.url(forResource: "VPhoneResources", withExtension: nil) else { return nil }
        let archive = bundled.appendingPathComponent("guest-resources.aar")
        guard FileManager.default.fileExists(atPath: archive.path) else { return bundled }
        let fm = FileManager.default
        let out = root.appendingPathComponent("resources", isDirectory: true)
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let stamp = out.appendingPathComponent(".stamp"), want = "\(Bundle.main.bundleURL.path) \(size)"
        if (try? String(contentsOf: stamp, encoding: .utf8)) == want { return out }
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) where item.lastPathComponent != "guest-resources.aar" {
            try fm.copyItem(at: item, to: out.appendingPathComponent(item.lastPathComponent))
        }
        let guest = out.appendingPathComponent("guest-resources", isDirectory: true)
        try fm.createDirectory(at: guest, withIntermediateDirectories: true)
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(guest.path), flags: [.ignoreOperationNotPermitted])
        else { throw NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot open the guest resources archive."]) }
        defer { try? extract.close(); try? decode.close(); try? decompress.close(); try? file.close() }
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
        try want.write(to: stamp, atomically: true, encoding: .utf8)
        return out
    }

    /// vphone's own library: machines being made, and its download cache, in this app's storage.
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("vphone", isDirectory: true)
    }

    static func pairings(_ kind: GuestKind) -> [VPhoneFirmwarePairing] {
        if let r = resources { VPhoneResources.monolithBase = r }
        return VPhoneFirmwareCatalog.pairings(for: kind.id)
    }

    func reset() { phase = .idle; stage = 0; stepProgress = 0; resumable = Self.loadResume() }

    /// An install whose restore finished: its last steps (vphone's installer, then Monolith's machine) can
    /// run again on the same restored machine, after a failure or the app being closed, without a new
    /// download or restore.
    struct Resume: Codable, Equatable {
        let kind: String, osName: String, name: String, cpus: Int, vm: String, ecid: UInt64
    }
    @Published var resumable: Resume? = DeviceInstaller.loadResume()
    nonisolated static var resumeFile: URL { root.appendingPathComponent("resume.json") }
    nonisolated static func loadResume() -> Resume? {
        guard let data = try? Data(contentsOf: resumeFile), let r = try? JSONDecoder().decode(Resume.self, from: data),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/\(r.vm)/Disk.img").path) else { return nil }
        return r
    }
    private func saveResume(_ r: Resume?) {
        if let r, let data = try? JSONEncoder().encode(r) { try? data.write(to: Self.resumeFile) }
        else { try? FileManager.default.removeItem(at: Self.resumeFile) }
        resumable = r
    }

    /// The last steps again, on the machine the restore left.
    func resume() {
        guard !busy, let r = resumable, let kind = GuestKind.all.first(where: { $0.id == r.kind }) else { return }
        phase = .running
        stage = 3
        stepProgress = 0
        title = "\(r.osName) on this \(Device.name)"
        UIApplication.shared.isIdleTimerDisabled = true
        let grace = UIApplication.shared.beginBackgroundTask(withName: "Monolith device install") {}
        Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(grace)
            }
            do {
                guard let resources = Self.resources else { throw message("This build has no vphone resources.") }
                setenv("VPHONE_ROOT", Self.root.path, 1)
                VPhoneResources.monolithBase = resources
                let vm = Self.root.appendingPathComponent("machines/\(r.vm)", isDirectory: true)
                HengeLog.log("device-install", "retrying the last steps of \(r.name) (\(r.vm))")
                let mac = VirtualMac(name: r.name, ecid: r.ecid, seed: 0, ramMB: kind.ramMB, diskBytes: 64 << 30)
                let made = try await finish(kind, osName: r.osName, vm: vm, mac: mac, resources: resources)
                phase = .done("\(made.name) is in Devices.")
            } catch {
                HengeLog.log("device-install", "failed: \(error)")
                phase = .failed("\(error)")
            }
        }
    }

    func start(_ kind: GuestKind, _ pairing: VPhoneFirmwarePairing, name: String, cpus: Int) {
        guard !busy else { return }
        phase = .running
        stage = 0
        stepProgress = 0
        title = "\(pairing.iosName) on this \(Device.name)"
        UIApplication.shared.isIdleTimerDisabled = true // a locked screen suspends the app and cuts the restore's connection
        let grace = UIApplication.shared.beginBackgroundTask(withName: "Monolith device install") {}
        Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(grace)
            }
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
        // vphone machines only live while an install runs (a finished one moves into Monolith's),
        // so any left here are from an install that failed or was killed; so are half downloads.
        saveResume(nil)
        Self.removeInstallerWork()
        for leftover in (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("m-") {
            HengeLog.log("device-install", "removing the unfinished \(leftover.lastPathComponent)")
            try? FileManager.default.removeItem(at: leftover)
        }
        let cache = root.appendingPathComponent("ipsws", isDirectory: true)
        for partial in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        where partial.pathExtension == "partial" { try? FileManager.default.removeItem(at: partial) }
        let slug = "m-" + UUID().uuidString.prefix(8).lowercased()
        let vm = library.appendingPathComponent(slug, isDirectory: true)
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        HengeLog.log("device-install", "\(kind.title) \(pairing.iosName) as \(name): \(vm.lastPathComponent), ECID \(ecid)")

        // 1. vphone's machine, its patch preset, and the firmware: downloaded, merged, prepared.
        let watcher = Task { await watchDownload(pairing, cache: root.appendingPathComponent("ipsws", isDirectory: true)) }
        defer { watcher.cancel() }
        // vphone's GPU driver recovery: cloudOS restored in a temporary machine of this one's ROMs.
        VPhonePCCGPURecovery.restorer = { [weak self] tree, work in
            guard let self else { throw NSError(domain: "Henge", code: 3) }
            let fm = FileManager.default
            for name in ["OpenAVB.bin", "OpenSEP.bin"] {
                try fm.copyItem(at: vm.appendingPathComponent(name), to: work.appendingPathComponent(name))
            }
            try Data(count: 512 << 10).write(to: work.appendingPathComponent("SEPStorage"))
            let temp = VirtualMac(name: "cloudOS (GPU driver)", ecid: UInt64.random(in: 1 << 40 ..< 1 << 62), seed: 0,
                                  ramMB: 2048, diskBytes: 64 << 30)
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            Task { @MainActor in
                do { try await self.restore(vm: work, tree: tree, mac: temp, cpus: cpus) } catch { failure = error }
                done.signal()
            }
            done.wait()
            if let failure { throw failure }
            return work.appendingPathComponent("Disk.img")
        }
        defer { VPhonePCCGPURecovery.restorer = nil }
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

        // From here the restored machine is kept for a retry of the last steps.
        saveResume(Resume(kind: kind.id, osName: pairing.iosName, name: name, cpus: cpus, vm: slug, ecid: ecid))
        return try await finish(kind, osName: pairing.iosName, vm: vm, mac: mac, resources: resources)
    }

    /// vphone's installer's leftover work folders (each can hold a clone of a disk image).
    nonisolated static func removeInstallerWork() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for item in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("vphone-cfw.") { try? FileManager.default.removeItem(at: item) }
    }

    /// Steps 4 and 5: vphone's installer into the restored disk, then Monolith's machine.
    private func finish(_ kind: GuestKind, osName: String, vm: URL, mac: VirtualMac, resources: URL) async throws -> VirtualMac {
        // 4. vphone's installer: vphoned, its daemons and libraries, the guest patches, into the disk image.
        stage = 3
        stepProgress = 0
        Self.removeInstallerWork()
        try await off {
            let tmp = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
            if kind.sealsAfterRestore {
                // a stock kernel checks the seal: the additions are written, then the system is sealed again
                try MonolithRestoredSystem.install(vm: vm)
            } else {
                try MonolithCustomFirmware.install(bundle: vm, resources: resources, workParent: tmp)
            }
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
            try osName.write(to: made.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: vm)
        }
        made.osName = osName
        Machines.shared.add(made)
        saveResume(nil)
        HengeLog.log("device-install", "\(made.name): installed, added to Devices")
        return made
    }

    /// How much of the firmware is here: the cache's bytes on disk (vphone's downloads grow from the front)
    /// against the sizes Apple's server gives, once a second.
    private func watchDownload(_ pairing: VPhoneFirmwarePairing, cache: URL) async {
        downloaded = 0; expected = 0; speed = 0
        var urls = [pairing.iosURL, pairing.cloudosURL]
        if let ota = VPhoneFirmwareCatalog.otaRelease(source: pairing.iosURL), let base = VPhoneFirmwareCatalog.restoreBaseURL(for: ota) {
            urls.append(base)
        }
        let start = Self.bytes(in: cache)
        var total: Int64 = 0
        for string in Set(urls) {
            guard let url = URL(string: string) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request) { total += max(response.expectedContentLength, 0) }
        }
        expected = total
        var last = start, lastTime = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = Self.bytes(in: cache), t = Date()
            downloaded = max(now - start, 0)
            let rate = Double(now - last) / max(t.timeIntervalSince(lastTime), 0.5)
            speed = speed == 0 ? max(rate, 0) : speed * 0.7 + max(rate, 0) * 0.3
            last = now; lastTime = t
        }
    }

    nonisolated static func bytes(in directory: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in walk {
            sum += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return sum
    }

    private func restore(vm: URL, tree: URL, mac: VirtualMac, cpus: Int) async throws {
        var restoring = mac
        restoring.ramMB = max(mac.ramMB, 2048)
        try FileManager.default.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        let ram = GuestMemory.prepare(restoring)
        guard ram >= 2048 else { throw message("The restore needs a few more GB of free storage for the device's memory.") }
        setenv("HV_WRITE_CACHE", "0", 1)
        // vphone makes these with Virtualization.framework on a Mac; here they are Monolith's own.
        let nvram = vm.appendingPathComponent("nvram.bin"), disk = vm.appendingPathComponent("Disk.img")
        if !FileManager.default.fileExists(atPath: nvram.path) {
            guard henge_make_aux(nvram.path) == 0 else { throw message("Cannot create the auxiliary storage.") }
        }
        if !FileManager.default.fileExists(atPath: disk.path) {
            guard FileManager.default.createFile(atPath: disk.path, contents: nil) else { throw message("Cannot create the disk.") }
            let h = try FileHandle(forWritingTo: disk)
            try h.truncate(atOffset: UInt64(64) << 30)
            try h.close()
        }
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
