import AppKit
import Foundation
import ServiceManagement

/// Bir uygulamanın konuştuğu uzak sunucu.
struct HostUsage: Codable, Identifiable {
    var ip: String
    var proto: String
    var port: String
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var lastSeen = Date()
    var id: String { ip }
    var total: UInt64 { bytesIn + bytesOut }
}

/// Uygulamaya ait (veya onun adına çalışan) bir süreç.
struct ProcUsage: Codable, Identifiable {
    var name: String
    var path: String?
    var via: Bool = false               // uygulama adına çalışan aracı süreç mi
    var pids: Set<Int32> = []
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var lastSeen = Date()
    var id: String { name }
    var total: UInt64 { bytesIn + bytesOut }
}

struct AppUsage: Codable, Identifiable {
    var name: String
    var bundlePath: String?
    var bundleID: String?
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var localBytes: UInt64 = 0          // yerel ağ trafiği (toplama dahil edilmez)
    var firstSeen = Date()
    var lastSeen = Date()
    var processes: [String: ProcUsage] = [:]
    var hosts: [String: HostUsage] = [:]
    var id: String { name }
    var total: UInt64 { bytesIn + bytesOut }
    var sortedHosts: [HostUsage] { hosts.values.sorted { $0.total > $1.total } }
    var sortedProcesses: [ProcUsage] { processes.values.sorted { $0.total > $1.total } }
}

private struct SavedState: Codable {
    var since: Date
    var apps: [String: AppUsage]
    var limitGB: Double?
    var resetDay: Int?
    var nextResetAt: Date?
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var since = Date()
    @Published private(set) var apps: [String: AppUsage] = [:]
    @Published private(set) var rateIn: Double = 0
    @Published private(set) var rateOut: Double = 0
    @Published private(set) var liveRates: [String: Double] = [:]   // uygulama başına anlık hız
    @Published var limitGB: Double = 0 { didSet { save() } }
    /// Day of month for the automatic reset (1–31, clamped to short months); 0 = off.
    @Published var resetDay: Int = 0 {
        didSet {
            nextResetAt = resetDay > 0 ? Self.nextBoundary(day: resetDay, after: Date()) : nil
            save()
        }
    }
    @Published private(set) var nextResetAt: Date?

    private struct Seen { var inB: UInt64; var outB: UInt64; var app: ResolvedApp }
    private struct ConnSeen { var inB: UInt64; var outB: UInt64; var poll: Int }
    private var lastSeen: [String: Seen] = [:]
    private var lastConn: [String: ConnSeen] = [:]
    private var primed = false
    private var pollCount = 0
    private var lastPollAt: Date?
    private var lastSave = Date()
    private var stream: NettopStream?
    let interval: TimeInterval = 1

    private static let fileURL: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ByteMeter", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("usage-v2.json")
        // One-time move from the app's previous name (DataKullanim).
        let old = support.appendingPathComponent("DataKullanim/usage-v2.json")
        if !fm.fileExists(atPath: file.path), fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: file)
        }
        return file
    }()

    init() {
        load()
        // /Applications'tan ilk açılışta girişte başlatmayı bir kez aç (sonra Ayarlar'dan değiştirilebilir).
        let key = "loginItemConfigured"
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) {
            launchAtLogin = true
            UserDefaults.standard.set(true, forKey: key)
        }
        NSLog("ByteMeter launch-at-login status: \(SMAppService.mainApp.status.rawValue)")

        let stream = NettopStream { [weak self] samples in
            Task { @MainActor in self?.ingest(samples) }
        }
        stream.start()
        checkAutoReset()
        self.stream = stream
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stream?.stop(); self?.save() }
        }
    }

    // MARK: Türetilmiş değerler

    var totalIn: UInt64 { apps.values.reduce(0) { $0 + $1.bytesIn } }
    var totalOut: UInt64 { apps.values.reduce(0) { $0 + $1.bytesOut } }
    var total: UInt64 { totalIn + totalOut }
    var sortedApps: [AppUsage] { apps.values.filter { $0.total > 0 }.sorted { $0.total > $1.total } }
    /// Menu bar text: quota percentage when a quota is set, otherwise the total in GB.
    var menuBarText: String {
        if let f = limitFraction { return "⇅ " + Fmt.percent(f) }
        return "⇅ " + Fmt.gigabytes(total)
    }
    var remainingBytes: UInt64? {
        guard limitGB > 0 else { return nil }
        let cap = UInt64(limitGB * Fmt.gb)
        return cap > total ? cap - total : 0
    }
    var limitFraction: Double? {
        guard limitGB > 0 else { return nil }
        return Double(total) / (limitGB * Fmt.gb)
    }

    // MARK: Ölçüm

    private static func delta(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
        // Aynı PID için sayaç gerçekte sıfırlanmaz; geri gidiş nettop'un eksik örneğidir → sayma.
        cur > prev ? cur - prev : 0
    }

    private func ingest(_ samples: [ProcSample]) {
        pollCount += 1
        let now = Date()
        var sumIn: UInt64 = 0, sumOut: UInt64 = 0
        var perApp: [String: UInt64] = [:]

        for s in samples {
            // Süreç düzeyi delta (kapanmış bağlantılar dahil).
            var pIn: UInt64 = 0, pOut: UInt64 = 0
            var baselineProc = false
            let app: ResolvedApp
            if let prev = lastSeen[s.key] {
                app = prev.app
                pIn = Self.delta(s.bytesIn, prev.inB)
                pOut = Self.delta(s.bytesOut, prev.outB)
            } else {
                app = AppResolver.resolve(pid: s.pid, procName: s.name)
                // Yalnızca önceki ölçümden sonra başlamış süreçlerin trafiği tamamen sayılır.
                // Daha önce başlamış (ilk kez görünen) süreçlerde geçmiş trafik taban çizgisi olur.
                let started = AppResolver.startTime(s.pid)
                if primed, let last = lastPollAt, let started, started > last.addingTimeInterval(-1) {
                    pIn = s.bytesIn; pOut = s.bytesOut
                } else {
                    baselineProc = true
                }
            }
            let old = lastSeen[s.key]
            lastSeen[s.key] = Seen(inB: max(s.bytesIn, old?.inB ?? 0), outB: max(s.bytesOut, old?.outB ?? 0), app: app)

            // Bağlantı düzeyi delta → sunucu detayları ve yerel ağ ayrımı.
            var localIn: UInt64 = 0, localOut: UInt64 = 0
            var hostDeltas: [(ConnSample, UInt64, UInt64)] = []
            for c in s.conns {
                var cIn: UInt64 = 0, cOut: UInt64 = 0
                if let prev = lastConn[c.key] {
                    cIn = Self.delta(c.bytesIn, prev.inB); cOut = Self.delta(c.bytesOut, prev.outB)
                } else if primed && !baselineProc {
                    // Yeni bağlantı: süreç yeni ya da zaten izleniyor → tamamı bu aralıkta oluştu.
                    cIn = c.bytesIn; cOut = c.bytesOut
                }
                let oc = lastConn[c.key]
                lastConn[c.key] = ConnSeen(inB: max(c.bytesIn, oc?.inB ?? 0), outB: max(c.bytesOut, oc?.outB ?? 0), poll: pollCount)
                if c.isLocal { localIn += cIn; localOut += cOut }
                else if cIn > 0 || cOut > 0 { hostDeltas.append((c, cIn, cOut)) }
            }

            let netIn = pIn - min(pIn, localIn)
            let netOut = pOut - min(pOut, localOut)
            guard netIn > 0 || netOut > 0 || !hostDeltas.isEmpty || localIn + localOut > 0 else { continue }

            var u = apps[app.name] ?? AppUsage(name: app.name, bundlePath: app.bundlePath,
                                               bundleID: app.bundleID, firstSeen: now)
            u.bytesIn += netIn; u.bytesOut += netOut
            u.localBytes += localIn + localOut
            u.lastSeen = now
            if u.bundlePath == nil { u.bundlePath = app.bundlePath }
            if u.bundleID == nil { u.bundleID = app.bundleID }

            var p = u.processes[s.name] ?? ProcUsage(name: s.name, path: app.execPath, via: app.via != nil)
            p.pids.insert(s.pid)
            if p.pids.count > 20 { p.pids = Set(p.pids.sorted().suffix(20)) }
            p.bytesIn += netIn; p.bytesOut += netOut; p.lastSeen = now
            u.processes[s.name] = p

            for (c, i, o) in hostDeltas {
                var h = u.hosts[c.remoteIP] ?? HostUsage(ip: c.remoteIP, proto: c.proto, port: c.remotePort)
                h.bytesIn += i; h.bytesOut += o; h.lastSeen = now
                h.proto = c.proto; h.port = c.remotePort
                u.hosts[c.remoteIP] = h
            }
            if u.hosts.count > 150 {
                u.hosts = Dictionary(uniqueKeysWithValues: u.sortedHosts.prefix(100).map { ($0.ip, $0) })
            }
            apps[app.name] = u
            sumIn += netIn; sumOut += netOut
            perApp[app.name, default: 0] += netIn + netOut
        }

        // Temizlik: kapanmış bağlantılar ve ölmüş süreçler.
        if pollCount % 30 == 0 {
            lastSeen = lastSeen.filter { kill(Self.pid(of: $0.key), 0) == 0 || errno != ESRCH }
            // Bağlantıları yalnızca sahibi süreç ölünce unut (geçici kaybolanlar yeniden sayılmasın).
            lastConn = lastConn.filter { k, _ in
                lastSeen[String(k.prefix { $0 != "|" })] != nil
            }
        }


        if let last = lastPollAt, primed {
            let dt = max(now.timeIntervalSince(last), 0.5)
            rateIn = Double(sumIn) / dt
            rateOut = Double(sumOut) / dt
            liveRates = perApp.mapValues { Double($0) / dt }
        }
        lastPollAt = now
        primed = true

        if pollCount % 30 == 0 { checkAutoReset() }
        if now.timeIntervalSince(lastSave) > 30 { save() }
    }

    private static func pid(of key: String) -> Int32 {
        guard let dot = key.lastIndex(of: ".") else { return 0 }
        return Int32(key[key.index(after: dot)...]) ?? 0
    }

    // MARK: Sıfırlama / kalıcılık

    func reset(at date: Date = Date()) {
        apps = [:]
        since = date
        rateIn = 0; rateOut = 0; liveRates = [:]
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        since = s.since
        apps = s.apps
        limitGB = s.limitGB ?? 0
        resetDay = s.resetDay ?? 0
        nextResetAt = s.nextResetAt ?? nextResetAt
        // Migrate names saved under their old Turkish (localized) labels.
        var renames = AppResolver.renamed
        for (k, u) in apps { if let p = u.bundlePath { renames[k] = AppResolver.displayName(p) } }
        for (old, new) in renames where old != new {
            guard var u = apps.removeValue(forKey: old) else { continue }
            u.name = new
            if let e = apps[new] { u.bytesIn += e.bytesIn; u.bytesOut += e.bytesOut }
            apps[new] = u
        }
    }

    // MARK: Monthly auto-reset

    private func checkAutoReset() {
        guard resetDay > 0, let due = nextResetAt, Date() >= due else { return }
        reset(at: due)
        nextResetAt = Self.nextBoundary(day: resetDay, after: Date())
        save()
    }

    /// The first midnight on `day` (clamped to the month's length) that is later than `date`.
    static func nextBoundary(day: Int, after date: Date) -> Date {
        let cal = Calendar.current
        var month = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        while true {
            let days = cal.range(of: .day, in: .month, for: month)!.count
            let d = cal.date(byAdding: .day, value: min(day, days) - 1, to: month)!
            if d > date { return d }
            month = cal.date(byAdding: .month, value: 1, to: month)!
        }
    }

    func save() {
        lastSave = Date()
        let s = SavedState(since: since, apps: apps, limitGB: limitGB,
                           resetDay: resetDay, nextResetAt: nextResetAt)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Girişte başlat

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Could not change launch at login: \(error)") }
            objectWillChange.send()
        }
    }
}

enum Fmt {
    static let gb: Double = 1024 * 1024 * 1024
    static let locale = Locale(identifier: "en_US")

    private static func num(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    static func gigabytes(_ b: UInt64) -> String { num(Double(b) / gb, 2) + " GB" }

    /// KB/MB for small values, GB for large ones.
    static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= gb { return gigabytes(b) }
        if d >= 1024 * 1024 { return num(d / 1024 / 1024, 1) + " MB" }
        return num(d / 1024, 0) + " KB"
    }

    static func rate(_ bps: Double) -> String {
        if bps >= 1024 * 1024 { return num(bps / 1024 / 1024, 1) + " MB/s" }
        return num(bps / 1024, 0) + " KB/s"
    }

    static func percent(_ f: Double) -> String {
        if f > 0 && f < 0.01 { return "<1%" }
        return "\(Int((f * 100).rounded()))%"
    }

    static func number(_ v: Double) -> String { v.formatted(.number.locale(locale)) }

    static func date(_ d: Date, time: Bool = true) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(locale))
    }

    static func time(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func relative(_ d: Date) -> String {
        d.formatted(Date.RelativeFormatStyle(presentation: .named).locale(locale))
    }
}
