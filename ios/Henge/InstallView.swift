import SwiftUI
import VPhoneCoreKit

/// Download macOS (or use a copy already on this device) and install it on a new Mac.
struct InstallView: View {
    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var devices = DeviceInstaller.shared
    @State private var target = "mac" // "mac", or a GuestKind's id
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var jitReady = JITBootstrap.ready
    @StateObject private var display = DisplayRouter()
    @State private var release = MacOSRelease.all.first(where: Installer.haveImage) ?? MacOSRelease.recommended
    @State private var name = "Mac"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var deleteAfter = false
    @State private var refresh = 0 // redraws the list when a download is deleted
    @State private var details = false
    @State private var stageStarted = Date()
    @State private var stageSeen = -1
    @State private var confirmDeleteDownload: MacOSRelease?
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if devices.phase != .idle {
                        DeviceProgressView(installer: devices)
                    } else {
                    switch installer.phase {
                    case .idle:
                        if let r = devices.resumable, !installer.busy {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(r.name) is not finished").font(.system(size: 18, weight: .bold))
                                Text("Its restore is done; the last steps did not complete. They can run again without a new download or restore.")
                                    .font(.system(size: 14)).foregroundStyle(Desk.dim)
                                Button("Retry the last steps") { devices.resume() }.buttonStyle(DeskButtonStyle(enabled: jitReady))
                                    .disabled(!jitReady).padding(.top, 4)
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading).deskCard(radius: 30).padding(.bottom, 14)
                        }
                        if !installer.busy { targetPicker }
                        if target == "mac" { chooser } else if let kind = GuestKind.all.first(where: { $0.id == target }) {
                            DeviceChooser(kind: kind, jitReady: jitReady)
                                .id(kind.id) // a new chooser per device: its versions and name are that device's
                        }
                    case .checking:
                        ProgressView("Preparing to install macOS…")
                            .padding(20)
                    case .downloading, .preparing, .installing: progress
                    case .done(let text): finished(text)
                    case .failed(let text): failed(text)
                    }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle(installer.busy || devices.busy ? "Installing" : "Install")
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    // MARK: Choosing

    /// Which kind of device: a Mac, or one of vphone's devices.
    private var targetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                targetButton("mac", "Mac", "desktopcomputer")
                ForEach(GuestKind.all) { kind in targetButton(kind.id, kind.title, kind.symbol) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
        .padding(.bottom, 4)
    }

    private func targetButton(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { target = id } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .regular)).frame(height: 30)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(width: 86, height: 74)
            .foregroundStyle(target == id ? Desk.text : Desk.dim)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(target == id ? Desk.card : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(target == id ? Desk.accentLight : Desk.hairline, lineWidth: target == id ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var chooser: some View {
        DeskHeading("Version")
        VStack(spacing: 0) {
            ForEach(MacOSRelease.all) { r in
                HStack(spacing: 0) {
                    Button { release = r } label: { versionRow(r) }
                        .buttonStyle(.plain)
                    if (Installer.haveImage(r) || Installer.partSize(r) != nil) && !installer.busy { // restore images are 15-25 GB: deleting one should be easy to find
                        Button { confirmDeleteDownload = r } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Desk.dim)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete the \(r.name) download")
                        .padding(.trailing, 6)
                    }
                }
                    .contextMenu {
                        if Installer.haveImage(r) || Installer.partSize(r) != nil {
                            Button("Delete Download", role: .destructive) { confirmDeleteDownload = r }
                        }
                    }
                if r.id != MacOSRelease.all.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()
        .id(refresh)
        .confirmationDialog("Delete this download?", isPresented: Binding(get: { confirmDeleteDownload != nil }, set: { if !$0 { confirmDeleteDownload = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) {
                if let r = confirmDeleteDownload { Installer.deleteImage(r) }
                refresh += 1
            }
        }

        DeskHeading("New Mac")
        VStack(spacing: 0) {
            TextField("Name", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Stepper(value: $ramGB, in: Device.memoryChoices) {
                HStack {
                    Text("Memory").font(.system(size: 16))
                    Spacer()
                    Text("\(ramGB) GB").font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            if let note = Device.memoryNote(ramGB) {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 10)
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Toggle("Delete the download after", isOn: $deleteAfter)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
        }
        .deskCard()

        Button(Installer.haveImage(release) ? "Install" : "Download and Install") {
            installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus, keepImage: !deleteAfter)
        }
        .buttonStyle(DeskButtonStyle(enabled: jitReady && !Device.chipTooOld))
        .disabled(!jitReady || Device.chipTooOld)
        .padding(.top, 20)
        Text(Device.chipTooOld ? Device.chipTooOldText : jitReady ? "Keep Monolith open and the \(Device.name) plugged in. Needs about \(ByteText.string(UInt64(Installer.spaceNeeded(release)))) free."
                                : JITBootstrap.lastFailure ?? "Turn on JIT first. \(jit.automaticDescription)")
            .font(.system(size: 13))
            .foregroundStyle(Desk.dim)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
        if !jitReady && !Device.chipTooOld {
            // Before any Mac exists, this is the only place to ask for JIT (#23).
            Button("Turn On JIT") { jit.enable() }
                .buttonStyle(DeskButtonStyle())
                .padding(.top, 12)
        }
    }

    private func versionRow(_ r: MacOSRelease) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                if let size = Installer.imageSize(r) {
                    Text("Downloaded, \(ByteText.string(UInt64(size)))").font(.system(size: 13)).foregroundStyle(Desk.good)
                } else if let part = Installer.partSize(r) {
                    Text("\(ByteText.string(UInt64(part))) of \(ByteText.string(UInt64(r.bytes))) downloaded: goes on from there")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                } else {
                    Text("\(ByteText.string(UInt64(r.bytes))) download").font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                Text(r.note).font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Spacer()
            if release == r { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Going

    private static let stages = ["Download", "Start installer", "Write macOS", "Check macOS", "Finish"]

    private var stage: Int {
        switch installer.phase {
        case .downloading: return 0
        case .preparing: return 1
        default:
            switch installer.step {
            case 0, 1: return 1
            case 2: return 2
            case 3: return 3
            default: return 4
            }
        }
    }

    private var fraction: Double {
        if case .downloading = installer.phase {
            return installer.expected > 0 ? Double(installer.received) / Double(installer.expected) : 0
        }
        return installer.stepProgress
    }

    /// From how this step has gone so far; nothing until there is enough to go on.
    private var timeLeft: String? {
        let elapsed = Date().timeIntervalSince(stageStarted)
        guard stageSeen == stage, fraction > 0.03, fraction < 1, elapsed > 10 else { return nil }
        let minutes = Int((elapsed / fraction * (1 - fraction) / 60).rounded(.up))
        return minutes <= 1 ? "About a minute left in this step" : "About \(minutes) minutes left in this step"
    }

    @ViewBuilder private var progress: some View {
        Text("\(release.name) on this \(Device.name). Keep Monolith open.")
            .font(.system(size: 16))
            .foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 66, weight: .bold))
                    .monospacedDigit()
                Text(timeLeft ?? "Step \(stage + 1) of \(Self.stages.count)")
                    .font(.system(size: 15))
                    .foregroundStyle(Desk.dim)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                DeskBar(fraction: fraction, height: 11)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard(radius: 30)
        }
        .onChange(of: stage) { value in
            stageSeen = value
            stageStarted = Date()
        }
        .onAppear {
            stageSeen = stage
            stageStarted = Date()
        }

        DeskHeading("Steps")
        VStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: i == stage ? .semibold : .regular))
                        .foregroundStyle(i > stage ? Desk.faint : Desk.text)
                    Spacer()
                    if i < stage {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                    } else if i == stage {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
                if i < Self.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()

        Button(details ? "Hide details" : "Show details") { withAnimation { details.toggle() } }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Desk.accentLight)
            .padding(.top, 14)
        if details {
            VStack(spacing: 12) {
                if case .installing = installer.phase {
                    BootDisplay(display: display, role: .device)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                LogTail()
            }
            .padding(14)
            .deskCard()
            .padding(.top, 10)
        }
    }

    private func finished(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
            Text("Installed").font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .deskCard(radius: 30)
        .padding(.top, 8)
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("It did not work").font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 15))
            Text("Quit Monolith (swipe it away) and open it again before trying again: only one device can start per launch.")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            Button("Back") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
        }
        .padding(18)
        .deskCard(radius: 30)
        .padding(.top, 8)
        DeskHeading("Log")
        LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
    }
}

/// The last lines of Monolith's log.
private struct LogTail: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// Choosing a version of a vphone device (HomePod, watch, Apple TV, iPhone) and a name.
private struct DeviceChooser: View {
    let kind: GuestKind
    let jitReady: Bool
    @State private var pairings: [VPhoneFirmwarePairingRow] = []
    @State private var chosen: Int?
    @State private var name = ""
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        VStack(spacing: 0) {
            if let note = kind.note {
                Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.bottom, 8)
            }
            DeskHeading("Version")
            VStack(spacing: 0) {
                if pairings.isEmpty {
                    Text("No version of \(kind.title) is known to this build.").font(.system(size: 15)).foregroundStyle(Desk.dim).padding(17)
                }
                ForEach(pairings) { p in
                    Button { chosen = p.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.pairing.iosName).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text("Boot chain from \(p.pairing.cloudosName)").font(.system(size: 13)).foregroundStyle(Desk.dim)
                            }
                            Spacer()
                            if chosen == p.id { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
                        }
                        .padding(.horizontal, 17).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if p.id != pairings.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()

            DeskHeading("New \(kind.title)")
            TextField("Name", text: $name)
                .font(.system(size: 16)).padding(.horizontal, 17).padding(.vertical, 14)
                .deskCard()

            Button("Download and Install") {
                guard let c = chosen, let p = pairings.first(where: { $0.id == c }) else { return }
                DeviceInstaller.shared.start(kind, p.pairing, name: name.isEmpty ? kind.title : name, cpus: cpus)
            }
            .buttonStyle(DeskButtonStyle(enabled: jitReady && kind.available && chosen != nil))
            .disabled(!jitReady || !kind.available || chosen == nil)
            .padding(.top, 20)
            Text(jitReady ? "Keep Monolith open and the \(Device.name) plugged in. Needs about 20 GB free while it works."
                          : "Turn on JIT first.")
                .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.center).padding(.top, 10)
        }
        .onAppear { load() }
    }

    private func load() {
        let list = DeviceInstaller.pairings(kind)
        pairings = list.enumerated().map { VPhoneFirmwarePairingRow(id: $0.offset, pairing: $0.element) }
        chosen = pairings.last?.id // the newest
        name = kind.title
    }
}

struct VPhoneFirmwarePairingRow: Identifiable {
    let id: Int
    let pairing: VPhoneFirmwarePairing
}

/// A vphone device being installed.
private struct DeviceProgressView: View {
    @ObservedObject var installer: DeviceInstaller

    var body: some View {
        VStack(spacing: 0) {
            switch installer.phase {
            case .done(let text):
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
                    Text("Installed").font(.system(size: 24, weight: .bold))
                    Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
                    Button("Done") { installer.reset() }.buttonStyle(DeskButtonStyle())
                }
                .padding(20).frame(maxWidth: .infinity).deskCard(radius: 30).padding(.top, 8)
            case .failed(let text):
                VStack(alignment: .leading, spacing: 10) {
                    Text("It did not work").font(.system(size: 22, weight: .bold))
                    Text(text).font(.system(size: 15))
                    if installer.resumable != nil {
                        Button("Retry the last steps") { installer.resume() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
                        Text("The restored device is kept: no new download or restore.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    Button("Back") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
                }
                .padding(18).deskCard(radius: 30).padding(.top, 8)
            default:
                Text("\(installer.title). Keep Monolith open.")
                    .font(.system(size: 16)).foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.bottom, 16)
                VStack(spacing: 0) {
                    ForEach(Array(DeviceInstaller.stages.enumerated()), id: \.offset) { i, title in
                        HStack {
                            Text(title)
                                .font(.system(size: 16, weight: i == installer.stage ? .semibold : .regular))
                                .foregroundStyle(i > installer.stage ? Desk.faint : Desk.text)
                            Spacer()
                            if i < installer.stage {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                            } else if i == installer.stage {
                                if i == 0, installer.expected > 0, installer.downloaded < installer.expected {
                                    ProgressView().controlSize(.small)
                                } else if i == 2, installer.stepProgress > 0 {
                                    Text("\(Int(installer.stepProgress * 100))%").font(.system(size: 14)).monospacedDigit().foregroundStyle(Desk.dim)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .padding(.horizontal, 17).padding(.vertical, 13)
                        if i < DeviceInstaller.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                    }
                }
                .deskCard()
                if installer.stage == 0, installer.expected > 0 {
                    let fraction = min(Double(installer.downloaded) / Double(installer.expected), 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(Int(fraction * 100))%").font(.system(size: 44, weight: .bold)).monospacedDigit()
                        Text("\(ByteText.string(UInt64(installer.downloaded))) of \(ByteText.string(UInt64(installer.expected)))"
                             + (installer.speed > 1 ? " · \(ByteText.string(UInt64(installer.speed)))/s" : "")
                             + (installer.speed > 1 && installer.downloaded < installer.expected
                                ? " · about \(max(1, Int(Double(installer.expected - installer.downloaded) / installer.speed / 60))) min left" : ""))
                            .font(.system(size: 15)).foregroundStyle(Desk.dim).monospacedDigit()
                        DeskBar(fraction: fraction, height: 11)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .deskCard(radius: 30)
                    .padding(.top, 12)
                }
            }
            DeskHeading("Log")
            LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
        }
    }
}
