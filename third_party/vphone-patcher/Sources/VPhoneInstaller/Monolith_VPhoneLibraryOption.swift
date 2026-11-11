// MONOLITH: from vphone-cli's VPhoneVirtualMachineCommand.swift (the vm command group is not built here).
import ArgumentParser
import Foundation
import VPhoneCoreKit

struct VPhoneLibraryOption: ParsableArguments {
    @Option(
        name: [.customShort("l"), .long], help: "VM library root (default: ~/.vphone/machines or $VPHONE_LIBRARY_ROOT)",
    )
    var libraryRoot: String?

    var library: VPhoneLibrary {
        let root =
            libraryRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VPhoneLibrary.defaultRoot()
        return VPhoneLibrary(root: root)
    }
}
