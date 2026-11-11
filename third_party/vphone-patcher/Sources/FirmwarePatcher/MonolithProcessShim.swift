// MONOLITH: iOS has no Foundation.Process (an app runs no other programs). This stand-in keeps vphone's
// code as it is; running anything says which tool it wanted, so that place gets Monolith's own code
// (its APFS reader/writer, AppleArchive, ...) instead.
#if !os(macOS)
import Foundation
import VPhoneCoreKit

final class Process {
    enum TerminationReason: Int { case exit = 1, uncaughtSignal = 2 }

    var executableURL: URL?
    var launchPath: String? { get { executableURL?.path } set { executableURL = newValue.map { URL(fileURLWithPath: $0) } } }
    var arguments: [String]?
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: ((Process) -> Void)?
    private(set) var terminationStatus: Int32 = 127
    private(set) var terminationReason: TerminationReason = .exit
    private(set) var processIdentifier: Int32 = 0
    var isRunning: Bool { false }

    init() {}

    func run() throws {
        let tool = ([executableURL?.lastPathComponent ?? "?"] + (arguments ?? []).prefix(2)).joined(separator: " ")
        throw VPhoneProcessUnavailable(tool: tool)
    }

    func launch() { _ = try? run() }
    func waitUntilExit() {}
    func terminate() {}
    func interrupt() {}
}
#endif
