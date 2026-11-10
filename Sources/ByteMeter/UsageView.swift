import SwiftUI

private let downColor = Color.accentColor
private let upColor = Color.accentColor.opacity(0.4)
private let topCount = 10

struct UsageView: View {
    @EnvironmentObject var store: UsageStore
    @State private var confirmReset = false
    @State private var showSettings = false
    @State private var limitText = ""
    @State private var expanded: String?
    @State private var showAll = false
    @State private var listHeight: CGFloat = 0

    private var apps: [AppUsage] { store.sortedApps }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summary
            if let f = store.limitFraction { limitBar(f) }
            Divider()
            breakdown
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 440)
    }

    // MARK: Bölümler

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ByteMeter").font(.headline)
            Spacer()
            Text("Since \(Fmt.date(store.since))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.gigabytes(store.total))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 16) {
                Label(Fmt.bytes(store.totalIn), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Label(Fmt.bytes(store.totalOut), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Text("Now ↓\(Fmt.rate(store.rateIn))  ↑\(Fmt.rate(store.rateOut))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    private func limitBar(_ f: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(f, 1))
                .tint(f >= 1 ? .red : f >= 0.8 ? .orange : .green)
            HStack {
                Text("\(Fmt.percent(f)) of \(Fmt.number(store.limitGB)) GB quota used")
                    .foregroundStyle(f >= 0.8 ? .orange : .secondary)
                Spacer()
                if let left = store.remainingBytes {
                    Text("\(Fmt.bytes(left)) left").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.caption)
            if let next = store.nextResetAt {
                Text("Resets automatically on \(Fmt.date(next, time: false))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var breakdown: some View {
        let shown = showAll ? apps : Array(apps.prefix(topCount))
        let rest = apps.dropFirst(topCount)
        let maxBytes = Double(apps.first?.total ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(showAll ? "All apps" : "Top \(min(topCount, apps.count)) apps")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                legend
            }
            if apps.isEmpty {
                Text("No traffic recorded yet. Measuring every \(Int(store.interval)) s.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                            row(a, rank: i + 1, maxBytes: maxBytes)
                        }
                        if !rest.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                            } label: {
                                HStack {
                                    Text(showAll ? "Show top \(topCount) only"
                                                 : "\(rest.count) more apps")
                                    Spacer()
                                    if !showAll {
                                        Text(Fmt.bytes(rest.reduce(0) { $0 + $1.total })).monospacedDigit()
                                    }
                                    Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                    })
                }
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
                .frame(height: min(max(listHeight, 60), 460))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).fill(downColor).frame(width: 10, height: 8); Text("Download") }
            HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).fill(upColor).frame(width: 10, height: 8); Text("Upload") }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func row(_ a: AppUsage, rank: Int, maxBytes: Double) -> some View {
        let share = store.total > 0 ? Double(a.total) / Double(store.total) : 0
        let scale = maxBytes > 0 ? Double(a.total) / maxBytes : 0     // en çok kullanan = tam genişlik
        let inFrac = a.total > 0 ? Double(a.bytesIn) / Double(a.total) : 0
        let open = expanded == a.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(rank)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                appIcon(a).frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(a.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if let r = store.liveRates[a.name], r > 1024 {
                            Text("● \(Fmt.rate(r))").font(.caption2).foregroundStyle(.green).monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.bytes(a.total)).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.callout)

                    GeometryReader { g in
                        let w = max(3, g.size.width * scale)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                            HStack(spacing: 0) {
                                Rectangle().fill(downColor).frame(width: w * inFrac)
                                Rectangle().fill(upColor).frame(width: w * (1 - inFrac))
                            }
                            .frame(width: w, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 10) {
                        Text(Fmt.percent(share))
                        Text("↓ \(Fmt.bytes(a.bytesIn))")
                        Text("↑ \(Fmt.bytes(a.bytesOut))")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded = open ? nil : a.name }
            }
            if open { AppDetailView(app: a).padding(.leading, 50) }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(open ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func appIcon(_ a: AppUsage) -> some View {
        if let img = AppResolver.icon(for: a.bundlePath) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSettings { settings }
            HStack {
                if confirmReset {
                    Text("Reset all counters?").font(.callout)
                    Button("Cancel") { confirmReset = false }
                    Button("Reset", role: .destructive) {
                        store.reset(); confirmReset = false
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { confirmReset = true } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    Button { showSettings.toggle() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            .controlSize(.small)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monthly quota (GB, 0 = off)")
                TextField("0", text: $limitText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyLimit)
                Button("Save", action: applyLimit)
            }
            Picker("Auto-reset every month on", selection: $store.resetDay) {
                Text("Off").tag(0)
                ForEach(1...31, id: \.self) { d in Text("Day \(d)").tag(d) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if store.resetDay > 28 {
                Text("In shorter months the reset happens on the last day.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
        }
        .font(.callout)
        .onAppear { limitText = store.limitGB > 0 ? Fmt.number(store.limitGB) : "" }
    }

    private func applyLimit() {
        let v = Double(limitText.replacingOccurrences(of: ",", with: ".")) ?? 0
        store.limitGB = max(0, v)
    }
}

/// Bir uygulamanın detayları: kimlik, süreçler ve konuştuğu sunucular.
struct AppDetailView: View {
    let app: AppUsage
    @ObservedObject private var hostNames = HostNames.shared
    @State private var showAllHosts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            if let note = noteText {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            processes
            hosts
        }
        .font(.caption)
        .padding(.bottom, 4)
    }

    private var noteText: String? {
        return app.processes.keys.compactMap { AppResolver.notes[$0] }.first
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let id = app.bundleID { kv("Bundle ID", id) }
            if let p = app.bundlePath ?? app.sortedProcesses.first?.path {
                HStack(alignment: .top, spacing: 4) {
                    kv("Location", p)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
                }
            }
            kv("First / last traffic", "\(Fmt.time(app.firstSeen)) – \(Fmt.relative(app.lastSeen))")
            if app.localBytes > 0 {
                kv("Local network (excluded)", Fmt.bytes(app.localBytes))
            }
        }
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Processes").font(.caption.weight(.semibold))
            ForEach(app.sortedProcesses) { p in
                HStack {
                    Image(systemName: p.via ? "arrow.triangle.branch" : "cpu")
                        .foregroundStyle(.secondary)
                        .help(p.via ? "Helper service working on behalf of the app" : "App process")
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Text("PID \(p.pids.sorted().map(String.init).joined(separator: ", "))")
                        .foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Text("↓\(Fmt.bytes(p.bytesIn)) ↑\(Fmt.bytes(p.bytesOut))").monospacedDigit()
                }
                .help(p.path ?? p.name)
            }
        }
    }

    private var hosts: some View {
        let list = app.sortedHosts
        let shown = showAllHosts ? Array(list.prefix(50)) : Array(list.prefix(8))
        return VStack(alignment: .leading, spacing: 2) {
            Text("Servers contacted (\(list.count))").font(.caption.weight(.semibold))
            if list.isEmpty {
                Text("No servers recorded yet.").foregroundStyle(.secondary)
            }
            ForEach(shown) { h in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hostNames.name(for: h.ip) ?? h.ip)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("\(h.ip) · \(h.proto) :\(h.port) · \(Fmt.relative(h.lastSeen))")
                            .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text("↓\(Fmt.bytes(h.bytesIn)) ↑\(Fmt.bytes(h.bytesOut))").monospacedDigit()
                }
            }
            if list.count > 8 {
                Button(showAllHosts ? "Show less" : "Show all (\(list.count))") {
                    showAllHosts.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(k + ":").foregroundStyle(.secondary)
            Text(v).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
