// MONOLITH: vphone-cli's `fw` command group, run inside Monolith (monolith-fw fw …, and the app).
import ArgumentParser
import Foundation

public enum MonolithFirmwareCommands {
    public static func main(_ arguments: [String]) -> Never {
        VPhoneFirmwareCommand.main(arguments)
        exit(0)
    }

    /// One command, returning instead of exiting (for the app).
    public static func run(_ arguments: [String]) throws {
        var command = try VPhoneFirmwareCommand.parseAsRoot(arguments)
        try command.run()
    }
}
