import Foundation

/// Preconditions for paired standalone/cache dyld updates. A caller must let
/// failures escape the install, discarding its private disk clone. Continuing
/// after a failed step could commit half of the pair with an incorrect receipt.
public enum CustomFirmwareTVTPROInstallation {
    public enum Failure: Error, CustomStringConvertible {
        case privateCloneRequired
        case missingUndo
        case invalidBackup
        case missingBackup

        public var description: String {
            switch self {
            case .privateCloneRequired:
                "tvOS guest updates require an APFS disk clone; place the VM and work directory on the same APFS volume. The original disk was not modified."
            case .missingUndo:
                "TV dyld cache undo record is missing; refusing a paired change."
            case .invalidBackup:
                "TV standalone dyld backup is not a regular file; refusing a paired change."
            case .missingBackup:
                "TV standalone dyld backup is missing for an existing patch; refusing to capture patched bytes as original."
            }
        }
    }

    public static func requirePrivateClone(_ cloned: Bool) throws {
        guard cloned else { throw Failure.privateCloneRequired }
    }

    public static func validateBackup(
        priorApplied: Bool, hasUndo: Bool, backupExists: Bool, backupIsRegular: Bool,
    ) throws {
        if priorApplied, !hasUndo { throw Failure.missingUndo }
        if backupExists, !backupIsRegular { throw Failure.invalidBackup }
        if priorApplied || hasUndo, !backupIsRegular { throw Failure.missingBackup }
    }

    /// Cache restoration and standalone restoration precede retirement of the
    /// undo record. Errors propagate to the caller's disk-clone transaction.
    public static func restorePair(
        restoreCache: () throws -> Void,
        restoreStandalone: () throws -> Void,
        retireUndo: () throws -> Void,
    ) throws {
        try restoreCache()
        try restoreStandalone()
        try retireUndo()
    }
}
