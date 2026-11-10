import AppKit
import Darwin

struct ResolvedApp {
    let name: String
    let bundlePath: String?
    let bundleID: String?
    let execPath: String?
    let via: String?          // trafiği aslında yapan aracı süreç (ör. WebKit Networking)
}

/// Süreçleri kullanıcıya anlamlı gelen uygulamalara eşler.
/// 1) Yürütülebilir dosya bir .app içindeyse en dıştaki paket (Chrome Helper → Google Chrome)
/// 2) Değilse macOS'un "sorumlu süreç" bilgisi (XPC servisleri → onları başlatan uygulama)
/// 3) Değilse bilinen sistem servisleri için okunur ad
enum AppResolver {
    static let friendly: [String: String] = [
        "nsurlsessiond": "Background transfers (nsurlsessiond)",
        "mDNSResponder": "DNS (mDNSResponder)",
        "softwareupdated": "Software Update",
        "apsd": "Push notifications (apsd)",
        "cloudd": "iCloud (cloudd)",
        "bird": "iCloud Drive (bird)",
        "photoanalysisd": "Photos",
        "cloudphotod": "iCloud Photos",
        "trustd": "Certificate checks (trustd)",
        "rapportd": "Continuity (rapportd)",
        "identityservicesd": "iMessage/FaceTime",
        "mobileassetd": "System asset downloads",
        "commerce": "App Store",
        "storedownloadd": "App Store downloads",
        "akd": "Apple Account (akd)",
        "iCloudNotificat": "iCloud notifications",
        "parsecd": "Spotlight suggestions (parsecd)",
        "timed": "Time sync (timed)",
    ]

    /// Old (Turkish) display names → current names, for migrating saved data.
    static let renamed: [String: String] = [
        "Arka plan indirmeleri (nsurlsessiond)": "Background transfers (nsurlsessiond)",
        "Yazılım Güncelleme": "Software Update",
        "Push bildirimleri (apsd)": "Push notifications (apsd)",
        "Fotoğraflar": "Photos",
        "iCloud Fotoğraflar": "iCloud Photos",
        "Sertifika denetimi (trustd)": "Certificate checks (trustd)",
        "Süreklilik (rapportd)": "Continuity (rapportd)",
        "Sistem varlık indirmeleri": "System asset downloads",
        "App Store indirmeleri": "App Store downloads",
        "Apple Hesabı (akd)": "Apple Account (akd)",
        "iCloud bildirimleri": "iCloud notifications",
        "Spotlight önerileri (parsecd)": "Spotlight suggestions (parsecd)",
        "Saat eşitleme (timed)": "Time sync (timed)",
    ]

    /// Explanations for system services, shown in the detail view.
    static let notes: [String: String] = [
        "nsurlsessiond": "System service that uploads and downloads in the background on behalf of other apps (iCloud, App Store, Photos, Mail, etc.). The server names below hint at the actual service.",
        "mDNSResponder": "Handles DNS lookups and Bonjour; local network traffic is excluded.",
        "cloudd": "System service that runs iCloud sync (CloudKit).",
        "bird": "iCloud Drive file sync.",
        "apsd": "Apple push notification connection.",
    ]

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW),
              let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()

    static func resolve(pid: Int32, procName: String) -> ResolvedApp {
        let path = executablePath(pid)
        if let path, let bundle = outermostAppBundle(in: path) {
            return make(bundle: bundle, exec: path, via: nil)
        }
        // XPC servisi gibi paket dışı süreçler için sorumlu uygulamaya bak.
        if let fn = responsibleFn {
            let rp = fn(pid)
            if rp > 0, rp != pid, let rpath = executablePath(rp) {
                if let bundle = outermostAppBundle(in: rpath) {
                    return make(bundle: bundle, exec: path, via: procName)
                }
                let rname = URL(fileURLWithPath: rpath).lastPathComponent
                return ResolvedApp(name: friendly[rname] ?? rname, bundlePath: nil, bundleID: nil,
                                   execPath: path, via: procName)
            }
        }
        if procName.hasPrefix("com.apple.WebKit") || procName.hasPrefix("com.apple.Safar") {
            return make(bundle: "/Applications/Safari.app", exec: path, via: procName)
        }
        return ResolvedApp(name: friendly[procName] ?? procName, bundlePath: nil, bundleID: nil,
                           execPath: path, via: nil)
    }

    /// Unlocalized (English) app name, independent of the system language.
    static func displayName(_ bundle: String) -> String {
        let info = Bundle(path: bundle)?.infoDictionary
        let n = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return (n?.isEmpty == false ? n : nil)
            ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
    }

    private static func make(bundle: String, exec: String?, via: String?) -> ResolvedApp {
        let b = Bundle(path: bundle)
        return ResolvedApp(name: displayName(bundle), bundlePath: bundle, bundleID: b?.bundleIdentifier,
                           execPath: exec, via: via)
    }

    /// Sürecin başlangıç zamanı (çekirdekten).
    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private static func outermostAppBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    private static var iconCache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundlePath: String?) -> NSImage? {
        guard let p = bundlePath, FileManager.default.fileExists(atPath: p) else { return nil }
        if let i = iconCache[p] { return i }
        let i = NSWorkspace.shared.icon(forFile: p)
        iconCache[p] = i
        return i
    }
}

/// Uzak IP'ler için arka planda ters DNS çözümlemesi (önbellekli).
@MainActor
final class HostNames: ObservableObject {
    static let shared = HostNames()
    @Published private(set) var names: [String: String] = [:]
    private var pending: Set<String> = []

    func name(for ip: String) -> String? {
        if let n = names[ip] { return n.isEmpty ? nil : n }
        guard !pending.contains(ip) else { return nil }
        pending.insert(ip)
        Task.detached(priority: .background) {
            let n = Self.reverse(ip) ?? ""
            await MainActor.run {
                self.names[ip] = n
                self.pending.remove(ip)
            }
        }
        return nil
    }

    nonisolated private static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count),
                          nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: host)
    }
}
