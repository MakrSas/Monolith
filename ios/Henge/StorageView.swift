import SwiftUI

/// Everything Monolith keeps on this iPhone, by what it is, with its size on disk: machines (and ones
/// no list knows any more), installs that did not finish, downloaded firmware, caches and temporary
/// work. Any of it can be deleted from here.
struct StorageView: View {
    struct Item: Identifiable, Hashable {
        let id: URL
        let title: String
        let detail: String
        let bytes: Int64
        let machine: UUID? // a machine in Monolith's list: deleted through it
    }
    struct Group: Identifiable {
        let id: String
        let footer: String
        var items: [Item]
    }

    @State private var groups: [Group] = []
    @State private var free: Int64 = 0
    @State private var scanning = false
    @State private var pending: Item?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Free on this iPhone")
                    Spacer()
                    Text(Self.size(free)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("Used by Monolith")
                    Spacer()
                    Text(Self.size(groups.flatMap(\.items).reduce(0) { $0 + $1.bytes })).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .listRowBackground(Desk.card)
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Self.size(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pending = item }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { pending = item }
                        }
                    }
                } header: {
                    Text(group.id)
                } footer: {
                    Text(group.footer)
                }
                .listRowBackground(Desk.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Desk.page)
        .navigationTitle("Storage")
        .overlay { if scanning && groups.isEmpty { ProgressView() } }
        .refreshable { await scan() }
        .task { await scan() }
        .confirmationDialog("Delete \(pending?.title ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            Button("Delete \(Self.size(item.bytes))", role: .destructive) { Task { await delete(item) } }
        } message: { item in
            Text(item.machine != nil ? "The machine and its disk are deleted. This cannot be undone." : "This cannot be undone.")
        }
    }

    private func delete(_ item: Item) async {
        pending = nil
        if let id = item.machine {
            Machines.shared.delete(id)
        } else {
            let url = item.id
            await Task.detached { try? FileManager.default.removeItem(at: url) }.value
        }
        HengeLog.log("storage", "deleted \(item.id.path) (\(Self.size(item.bytes)))")
        await scan()
    }

    private func scan() async {
        scanning = true
        let known = Dictionary(uniqueKeysWithValues: Machines.shared.all.map { ($0.id, $0.name) })
        let (found, freeBytes) = await Task.detached { (Self.collect(known: known), Self.freeSpace()) }.value
        groups = found
        free = freeBytes
        scanning = false
    }

    // MARK: - What is where

    nonisolated private static func collect(known: [UUID: String]) -> [Group] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let vphone = support.appendingPathComponent("vphone", isDirectory: true)
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var groups: [Group] = []

        var machines: [Item] = []
        for dir in children(Machines.root) where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let id = UUID(uuidString: dir.lastPathComponent)
            if let id, let name = known[id] {
                machines.append(Item(id: dir, title: name, detail: "Machine", bytes: allocated(dir), machine: id))
            } else {
                machines.append(Item(id: dir, title: dir.lastPathComponent, detail: "Not in the machine list (left from a failed install or a removal)", bytes: allocated(dir), machine: nil))
            }
        }
        groups.append(Group(id: "Machines", footer: "Devices and Macs. A machine's disk only takes what its system has written.", items: machines))

        var unfinished: [Item] = []
        for dir in children(vphone.appendingPathComponent("machines")) {
            unfinished.append(Item(id: dir, title: dir.lastPathComponent, detail: "Install that did not finish", bytes: allocated(dir), machine: nil))
        }
        for dir in children(vphone) where dir.lastPathComponent.hasPrefix(".pcc-restoration") || dir.lastPathComponent.hasPrefix(".firmware-prepare") {
            unfinished.append(Item(id: dir, title: dir.lastPathComponent, detail: "Install work folder", bytes: allocated(dir), machine: nil))
        }
        if !unfinished.isEmpty {
            groups.append(Group(id: "Unfinished installs", footer: "What an install that stopped left. A new install also clears these.", items: unfinished))
        }

        var firmware: [Item] = []
        let ipsws = vphone.appendingPathComponent("ipsws")
        for url in children(ipsws) + children(ipsws.appendingPathComponent("ota")) {
            if url.lastPathComponent == "ota" { continue }
            let name = url.lastPathComponent
            let partial = name.hasSuffix(".partial")
            firmware.append(Item(id: url, title: partial ? String(name.dropFirst().split(separator: ".").first ?? "") : name,
                                 detail: partial ? "Unfinished download" : (url.deletingLastPathComponent().lastPathComponent == "ota" ? "OTA update" : "Restore image"),
                                 bytes: allocated(url), machine: nil))
        }
        for dir in children(vphone.appendingPathComponent("gpu-drivers")) {
            firmware.append(Item(id: dir, title: dir.lastPathComponent, detail: "GPU driver from cloudOS", bytes: allocated(dir), machine: nil))
        }
        if !firmware.isEmpty {
            groups.append(Group(id: "Firmware", footer: "Downloads kept so the next install of the same device downloads nothing.", items: firmware))
        }

        var other: [Item] = []
        let resources = vphone.appendingPathComponent("resources")
        if fm.fileExists(atPath: resources.path) {
            other.append(Item(id: resources, title: "Guest resources", detail: "Unpacked from the app; made again when needed", bytes: allocated(resources), machine: nil))
        }
        for url in children(fm.temporaryDirectory) {
            other.append(Item(id: url, title: url.lastPathComponent, detail: "Temporary", bytes: allocated(url), machine: nil))
        }
        for url in children(fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
            other.append(Item(id: url, title: url.lastPathComponent, detail: "Cache", bytes: allocated(url), machine: nil))
        }
        for url in children(Machines.inbox) {
            other.append(Item(id: url, title: url.lastPathComponent, detail: url.pathExtension == "log" ? "Log" : "Documents", bytes: allocated(url), machine: nil))
        }
        let known = Set([Machines.root.lastPathComponent, "vphone"])
        for url in children(support) where !known.contains(url.lastPathComponent) {
            other.append(Item(id: url, title: url.lastPathComponent, detail: "App data", bytes: allocated(url), machine: nil))
        }
        if !other.isEmpty {
            groups.append(Group(id: "Other", footer: "Temporary work, caches, logs and the rest of the app's data.", items: other.sorted { $0.bytes > $1.bytes }))
        }
        return groups
    }

    /// Bytes on disk (sparse disk images count only what is written).
    nonisolated private static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var sum: Int64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walk?.nextObject() as? URL {
            sum += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return sum
    }

    nonisolated private static func freeSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
