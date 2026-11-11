import ArgumentParser
import Foundation
import VPhoneCoreKit

/// Check the running source before stopping it for a full OTA. The encrypted
/// Data volume's launchd overrides cannot be checked by the host installer.
struct VPhoneFirmwareOTAPreflightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ota-preflight",
        abstract: "Inspect a running guest's migration state and service dependencies before OTA",
        discussion: """
        Read-only. A trimmed source can retain disabled migration dependencies on
        its Data volume. Save the service profile, take a stopped disk/SEP/NVRAM
        snapshot, and temporarily restore profile-owned services before upgrading.
        User-owned overrides are reported separately and are never changed here.
        Reapply the saved profile only after real migration and UI verification.
        """
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "Running source VM name") var name: String

    func run() throws {
        let bundle = try lib.library.bundle(named: name)
        func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            try VPhoneFirmwareOTACommand.guestCall(bundle, method, params, timeout: 15,
                                                   note: "Run ota-preflight while the source is running and responsive.")
        }

        let profile = try call("services.profile")
        let disabled = try call("services.disabled")
        let setup = try call("setup.status")
        let migration = try call("settings.get", ["domain": "com.apple.migration"])
        let lastResult = VPhoneFirmwareOTACommand.migrationResult(migration)
        let record = profile["record"] as? [String: Any] ?? [:]
        let managedDisabled = (profile["disabled"] as? [String] ?? []).sorted()
        let externallyDisabled = VPhoneFirmwareOTACommand.externallyDisabledDependencies(profile: profile, disabled: disabled)
        let migrationDone = setup["data_migration_done"] as? Bool
        var removed: [String] = []
        var removalError: String?
        do {
            removed = try VPhoneOTAUpdate.removedSystemAppIDs(call("apps.removed_system"))
        } catch {
            removalError = error.localizedDescription
        }
        // The same gate fw ota capture applies, so a ready report is accepted there.
        let ready = managedDisabled.isEmpty && externallyDisabled.isEmpty
            && removalError == nil
            && VPhoneFirmwareOTACommand.sourceFinishedMigration(setup: setup, migration: migration)
        let report: [String: Any] = [
            "machine": bundle.name,
            "ready_for_ota_experiment": ready,
            "service_profile_record": record,
            "profile_owned_disabled": managedDisabled,
            "externally_disabled_dependencies": externallyDisabled,
            "removed_system_apps": removed,
            "removed_system_apps_error": removalError.map { $0 as Any } ?? NSNull(),
            "data_migration_done": migrationDone.map { $0 as Any } ?? NSNull(),
            "last_migration_result": lastResult.map { $0 as Any } ?? NSNull(),
            "notes": [
                "A completed migration with success=false is a failure, even when setup.status says data_migration_done=true.",
                "This check changes no service overrides or migration results and does not attest target-OS compatibility.",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !ready { throw ExitCode.failure }
    }
}
