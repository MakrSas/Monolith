import Darwin
import Foundation

/// OTA adds host configuration to a normal disk/SEP/NVRAM snapshot without
/// changing ordinary snapshot semantics. The journal lives outside the machine
/// folder so guest-side phases can record progress while the VM is running.
public enum VPhoneOTAUpdate {
    /// Backups are not themselves a removal policy: a user may have installed
    /// the app again. Only absent apps/placeholders belong in a new baseline.
    public static func removedSystemAppIDs(_ response: [String: Any]) throws -> [String] {
        guard let rows = response["backups"] as? [[String: Any]] else {
            throw Failure("Missing removed-system-app inventory.")
        }
        var ids = Set<String>()
        for row in rows {
            guard let id = row["bundle_id"] as? String, id.hasPrefix("com.apple."),
                  let installed = row["installed"] as? Bool,
                  row["registered"] is Bool, row["placeholder"] is Bool else {
                throw Failure("The guest cannot report system-app placeholders; update vphoned before OTA.")
            }
            if installed { continue }
            guard row["restorable"] as? Bool == true, row["error"] == nil else {
                throw Failure("Invalid removal backup for \(id).")
            }
            ids.insert(id)
        }
        return ids.sorted()
    }

    public static func requireRemovedSystemApps(_ ids: [String], inventory: [String: Any]) throws {
        guard let rows = inventory["backups"] as? [[String: Any]] else {
            throw Failure("Missing removed-system-app verification.")
        }
        for id in ids {
            guard let row = rows.first(where: { $0["bundle_id"] as? String == id }),
                  row["registered"] as? Bool == false, row["installed"] as? Bool == false,
                  row["placeholder"] as? Bool == false, row["restorable"] as? Bool == true,
                  row["error"] == nil else {
                throw Failure("Removed system app \(id) returned after OTA or lost its backup.")
            }
        }
    }

    public enum Phase: String, Codable, Sendable {
        case captured, checkpointing, checkpointed, quiesced, preparing, prepared
        case installed, completed, committed, rollingBack, rolledBack
    }

    public struct Record: Codable, Sendable {
        public let machinePath: String
        public let snapshot: String
        public let targetBuild: String
        public let targetVersion: String
        public let source: Data
        public var phase: Phase
        public var hostFiles: [String]
        public var artifacts: [String]
        public var autoLockRestorationRequested: Bool?
        public var autoLockRebootRequested: Bool?
        public var operationID: String?
        public var networkIsolated: Bool?

        public init(bundle: VPhoneBundle, build: String, version: String, source: Data) {
            machinePath = bundle.url.resolvingSymlinksInPath().path
            snapshot = "ota-" + UUID().uuidString.lowercased()
            targetBuild = build
            targetVersion = version
            self.source = source
            phase = .captured
            hostFiles = []
            artifacts = []
        }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    private static let hostNames = [
        "config.plist", "PatchSelection.plist", "PatchPlan.plist", ".vphoned.signed",
        "AVPBooter.vresearch1.bin", "AVPSEPBooter.vresearch1.bin", "OpenAVB.bin", "OpenSEP.bin",
    ]

    public static func directory(of bundle: VPhoneBundle) -> URL {
        bundle.url.deletingLastPathComponent()
            .appendingPathComponent(".ota-updates", isDirectory: true).appendingPathComponent(bundle.name, isDirectory: true)
    }

    /// A second coordinator must not prepare or roll back the same machine.
    public static func withLock<T>(of bundle: VPhoneBundle, _ body: () throws -> T) throws -> T {
        let directory = directory(of: bundle)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A terminal journal can be archived for a fresh attempt. The lock
        // must stay at a stable path when that directory is renamed.
        let path = directory.deletingLastPathComponent().appendingPathComponent(bundle.name + ".lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open OTA lock: \(path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another OTA command owns \(bundle.name).") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public static func read(of bundle: VPhoneBundle) throws -> Record {
        let data = try Data(contentsOf: directory(of: bundle).appendingPathComponent("Update.plist"))
        let record = try PropertyListDecoder().decode(Record.self, from: data)
        guard record.machinePath == bundle.url.resolvingSymlinksInPath().path,
              (try? VPhoneMachineSnapshots.requireValidName(record.snapshot)) != nil,
              record.hostFiles.allSatisfy(hostNames.contains),
              record.artifacts.allSatisfy(isArtifactName) else {
            throw Failure("OTA journal does not describe this machine or contains invalid backup paths.")
        }
        return record
    }

    public static func write(_ record: Record, of bundle: VPhoneBundle) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let path = directory(of: bundle).appendingPathComponent("Update.plist")
        try encoder.encode(record).write(to: path, options: .atomic)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public static func capture(_ record: Record, of bundle: VPhoneBundle) throws {
        let path = directory(of: bundle).appendingPathComponent("Update.plist")
        if FileManager.default.fileExists(atPath: path.path) {
            let previous = try read(of: bundle)
            guard previous.phase == .rolledBack else {
                throw Failure("This machine already has an OTA journal. Resume or roll it back; do not overwrite its recovery state.")
            }
            let current = directory(of: bundle)
            let archived = current.deletingLastPathComponent().appendingPathComponent(bundle.name + "-" + previous.snapshot)
            try FileManager.default.moveItem(at: current, to: archived)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        }
        try write(record, of: bundle)
    }

    /// Guest version and this boot's migration result must independently
    /// agree. In particular SetupDone or an old successful result is not proof.
    public static func requireMigration(
        version: String, build: String, actualVersion: String?,
        migrationDone: Bool?, result: [String: Any]?
    ) throws {
        guard actualVersion == version, migrationDone == true,
              result?["buildVersion"] as? String == build,
              result?["success"] as? Bool == true else {
            throw Failure("Target build migration has not succeeded. Setup skip cannot satisfy this gate.")
        }
    }

    public static func requireOperation(_ operationID: String?, record: Record) throws {
        if let operationID, record.operationID != operationID {
            throw Failure("The OTA journal belongs to another coordinator operation.")
        }
    }

    public static func isolateNetwork(of bundle: VPhoneBundle) throws {
        try VPhoneBundleActivity.requireStopped(bundle)
        var record = try read(of: bundle)
        guard record.phase == .checkpointed else { throw Failure("Network isolation needs a completed source checkpoint.") }
        let current = try VPhoneBundle.load(at: bundle.url)
        let offline = VPhoneVirtualMachineManifest.NetworkConfig(mode: .off, macAddress: current.manifest.networkConfig.macAddress)
        try current.manifest.updating(networkConfig: offline).write(to: current.configURL)
        record.networkIsolated = true
        try write(record, of: bundle)
    }

    /// Once networking can resume, new guest writes must not be silently
    /// discarded by an automatic rollback. Publish that boundary durably
    /// before restoring the source network policy; repeat safely after a crash.
    public static func commit(of bundle: VPhoneBundle) throws {
        try VPhoneBundleActivity.requireStopped(bundle)
        var record = try read(of: bundle)
        guard record.phase == .completed || record.phase == .committed else {
            throw Failure("OTA can be committed only after offline verification.")
        }
        let source = try sourceManifest(of: bundle)
        let current = try VPhoneBundle.load(at: bundle.url)
        record.phase = .committed
        try write(record, of: bundle)
        try current.manifest.updating(networkConfig: source.networkConfig).write(to: current.configURL)
    }

    public static func sourceManifest(of bundle: VPhoneBundle) throws -> VPhoneVirtualMachineManifest {
        try VPhoneVirtualMachineManifest.load(from: directory(of: bundle).appendingPathComponent("host/config.plist"))
    }

    /// Called before any service or firmware changes. All large backups must
    /// use APFS clones; no full-copy fallback for Disk.img or restore trees.
    public static func checkpoint(of bundle: VPhoneBundle) throws {
        try VPhoneBundleActivity.requireStopped(bundle)
        var record = try read(of: bundle)
        guard record.phase == .captured || record.phase == .checkpointing else {
            if record.phase == .checkpointed { return }
            throw Failure("Cannot checkpoint OTA in phase \(record.phase.rawValue).")
        }
        let fm = FileManager.default
        let backup = directory(of: bundle).appendingPathComponent("host", isDirectory: true)
        if record.phase == .captured {
            record.hostFiles = hostNames.filter { fm.fileExists(atPath: bundle.url.appendingPathComponent($0).path) }
            record.artifacts = try fm.contentsOfDirectory(atPath: bundle.url.path).filter(isArtifactName).sorted()
            record.phase = .checkpointing
            try write(record, of: bundle)
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        // Each backup is individually published by rename. A power loss can
        // resume without accepting an incomplete directory as a backup.
        for name in record.hostFiles + record.artifacts {
            let destination = backup.appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) {
                try cloneTree(bundle.url.appendingPathComponent(name), to: destination)
            }
        }
        if !(try VPhoneMachineSnapshots.list(of: bundle)).contains(where: { $0.name == record.snapshot }) {
            try VPhoneMachineSnapshots.create(record.snapshot, note: "Before OTA to \(record.targetVersion) (\(record.targetBuild))", of: bundle)
        }
        record.phase = .checkpointed
        try write(record, of: bundle)
    }

    /// Clear only backed-up firmware inputs. Repeatable after an interrupted
    /// preparation. The pre-upgrade host state and snapshot remain intact.
    public static func beginPreparation(of bundle: VPhoneBundle) throws {
        try VPhoneBundleActivity.requireStopped(bundle)
        var record = try read(of: bundle)
        guard record.phase == .quiesced || record.phase == .preparing else {
            throw Failure("OTA preparation needs a checkpoint and quiesced source services.")
        }
        record.phase = .preparing
        try write(record, of: bundle)
        for name in try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter(isArtifactName) {
            try FileManager.default.removeItem(at: bundle.url.appendingPathComponent(name))
        }
    }

    /// A failed target remains inspectable. Restore the saved host state and
    /// disk/SEP/NVRAM together, retaining the snapshot and backup for retry.
    public static func rollback(of bundle: VPhoneBundle, discardOnlineWrites: Bool = false) throws {
        try VPhoneBundleActivity.requireStopped(bundle)
        var record = try read(of: bundle)
        if record.phase == .rolledBack { return }
        guard record.phase != .committed || discardOnlineWrites else {
            throw Failure("OTA was committed and the guest may have written new data online. Keep the target data; automatic rollback is refused.")
        }
        guard record.phase != .captured && record.phase != .checkpointing else {
            throw Failure("No completed checkpoint exists; firmware has not been changed.")
        }
        record.phase = .rollingBack
        try write(record, of: bundle)
        let fm = FileManager.default
        let backup = directory(of: bundle).appendingPathComponent("host")
        let failed = directory(of: bundle).appendingPathComponent("failed-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: failed, withIntermediateDirectories: false)
        // Validate the whole backup before changing any live file.
        for name in record.hostFiles + record.artifacts {
            guard fm.fileExists(atPath: backup.appendingPathComponent(name).path) else {
                throw Failure("OTA host backup is incomplete: \(name)")
            }
        }
        try VPhoneMachineSnapshots.revert(to: record.snapshot, of: bundle)
        let currentArtifacts = try fm.contentsOfDirectory(atPath: bundle.url.path).filter(isArtifactName)
        for name in Set(hostNames + currentArtifacts + record.artifacts).sorted() {
            let live = bundle.url.appendingPathComponent(name)
            if (record.hostFiles + record.artifacts).contains(name) {
                let staged = failed.appendingPathComponent(name)
                try cloneTree(backup.appendingPathComponent(name), to: staged)
                if fm.fileExists(atPath: live.path) {
                    // config.plist must always exist, including after a
                    // crash: the next CLI needs it to open this machine.
                    guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, live.path, UInt32(RENAME_SWAP)) == 0 else {
                        throw Failure("Cannot publish restored OTA host file \(name): \(String(cString: strerror(errno)))")
                    }
                } else {
                    try fm.moveItem(at: staged, to: live)
                }
            } else if fm.fileExists(atPath: live.path) {
                try fm.moveItem(at: live, to: failed.appendingPathComponent(name))
            }
        }
        record.phase = .rolledBack
        try write(record, of: bundle)
    }

    private static func isArtifactName(_ name: String) -> Bool {
        VPhoneVirtualMachineManifest.isPlainFileName(name) && !name.hasPrefix(".")
            && (name.contains("Restore") || ["FirmwareOriginals", "OTAUserland"].contains(name))
    }

    private static func cloneTree(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".ota-copy-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        // clonefile copies a whole directory tree in one call and keeps the
        // relative links in firmware frameworks as links; NOFOLLOW extends
        // that to a link at the top. Staged, then published by rename.
        try VPhoneMachineSnapshots.cloneFile(source, to: stage)
        try fm.moveItem(at: stage, to: destination)
    }
}


