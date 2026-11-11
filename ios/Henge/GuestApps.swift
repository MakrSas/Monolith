import SwiftUI

/// The guest's apps, from its agent (vphoned): tap one to open it. For devices whose own UI has no
/// easy way to some apps (Settings on a HomeView, say).
struct GuestAppsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [(id: String, name: String)] = []
    @State private var status = "Asking the device…"
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                if apps.isEmpty {
                    Text(status).foregroundStyle(Desk.dim)
                }
                ForEach(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter) }, id: \.id) { app in
                    Button {
                        Task {
                            let r = await GuestAgent.rpc("apps.launch", ["bundle_id": app.id], timeout: 20)
                            HengeLog.log("agent", "launch \(app.id): \(r.map { "\($0)" } ?? "no answer")")
                            if r != nil { dismiss() } else { status = "\(app.name) did not open." }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).foregroundStyle(Desk.text)
                            Text(app.id).font(.system(size: 12)).foregroundStyle(Desk.dim)
                        }
                    }
                }
            }
            .searchable(text: $filter)
            .navigationTitle("Apps")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        GuestAgent.connect()
        guard let r = await GuestAgent.rpc("apps.list", timeout: 20), let list = r["apps"] as? [[String: Any]] else {
            status = "The device's agent is not answering yet. Wait until it has finished starting."
            return
        }
        apps = list.compactMap { a -> (id: String, name: String)? in
            guard let id = a["bundle_id"] as? String else { return nil }
            let name = (a["name"] as? String) ?? (a["display_name"] as? String) ?? (a["localized_name"] as? String) ?? id
            return (id, name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps.isEmpty { status = "No apps listed." }
    }
}

/// Opens the guest's apps list.
struct GuestAppsButton: View {
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .medium))
                Text("Apps").font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $shown) { GuestAppsSheet() }
    }
}
