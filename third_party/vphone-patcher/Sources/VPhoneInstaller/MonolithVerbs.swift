// MONOLITH: vphone's installer runs its own executable for each `cfw <verb>` patch step. An iOS app can
// run no process, so the same verbs (vphone's own ArgumentParser commands) are parsed and run here, in
// this process, with their standard output captured as the child's would have been.
import ArgumentParser
import Foundation

struct MonolithCFWVerbs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cfw",
        subcommands: [
            VPhoneCustomFirmwareCryptexPathsCommand.self,
            VPhoneCustomFirmwareInjectDaemonsCommand.self,
            VPhoneCustomFirmwareInjectDaemonCommand.self,
            VPhoneCustomFirmwarePatchDropbearPlistCommand.self,
            VPhoneCustomFirmwareInjectDylibCommand.self,
            VPhoneCustomFirmwarePatchBuildVersionCommand.self,
            VPhoneCustomFirmwarePatchLocationdCohortingCommand.self,
            VPhoneCustomFirmwarePatchTVSetupCommand.self,
            VPhoneCustomFirmwarePatchVirtualBluetoothCommand.self,
            VPhoneCustomFirmwarePatchJetsamDisableAllowedCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioGraphConfigurationsCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioSpeakerRawCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioMicrophoneChainsCommand.self,
            VPhoneCustomFirmwarePatchVirtualAudioMicrophoneGainCommand.self,
            VPhoneCustomFirmwarePatchCampoEntitlementsCommand.self,
            VPhoneCustomFirmwarePatchPostRestoreDeviceTreeCommand.self,
            VPhoneCustomFirmwarePatchBoardAudioCommand.self,
            VPhoneCustomFirmwarePatchHomePodAudioProductCommand.self,
            VPhoneCustomFirmwarePatchHomePodCryptexClassCommand.self,
            VPhoneCustomFirmwarePatchVisionOSVirtualProductCommand.self,
            VPhoneCustomFirmwarePatchIPhoneProductCommand.self,
            VPhoneCustomFirmwarePatchDriverKitCommand.self,
            VPhoneCustomFirmwarePatchFoldableVMSubtypeCommand.self,
            VPhoneCustomFirmwarePatchFoldableProductIdCommand.self,
            VPhoneCustomFirmwarePatchFoldableDisplaysCommand.self,
            VPhoneCustomFirmwarePatchHapticsCommand.self,
            VPhoneCustomFirmwarePatchIOS16EphemeralCommand.self,
            VPhoneCustomFirmwarePatchMicrophoneArrayCommand.self,
        ] + VPhoneCustomFirmwareMachOVerbs.all + VPhoneCustomFirmwareDyldSharedCacheVerbs.all,
    )

    /// `cfw <verb> args…` in this process; what it printed.
    static func run(_ arguments: [String]) throws -> String {
        var command = try parseAsRoot(arguments)
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var output = Data()
        let reader = Thread { output = pipe.fileHandleForReading.readDataToEndOfFile() }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { reader.main(); done.signal() }
        thread.start()
        var failure: Error?
        do { try command.run() } catch { failure = error }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        done.wait()
        if let failure { throw failure }
        return String(decoding: output, as: UTF8.self)
    }
}
