import Foundation

/// Bir sürecin açık bağlantılarından biri.
struct ConnSample {
    let key: String          // süreç anahtarı + bağlantı tanımı (benzersiz)
    let proto: String        // tcp4, udp6, quic4 ...
    let remoteIP: String
    let remotePort: String
    let isLocal: Bool        // yerel ağ / multicast / link-local → kotadan yemez
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// nettop'tan alınan tek bir sürecin kümülatif sayaçları ve bağlantıları.
struct ProcSample {
    let key: String          // "isim.pid"
    let name: String
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
    var conns: [ConnSample] = []
}

/// `nettop`'u sürekli akış modunda (saniyede bir örnek) çalıştırır.
/// Ayrı ayrı çalıştırmaya göre avantajı: kapanan süreçler son değerleriyle birkaç örnek daha
/// raporlanır, böylece kısa ömürlü süreçlerin (ör. 2 sn'lik bir indirme) trafiği kaybolmaz.
/// Pipe'a yazınca çıktı tamponlandığından sözde terminal (pty) üzerinden çalıştırılır.
final class NettopStream: @unchecked Sendable {
    private let onSample: @Sendable ([ProcSample]) -> Void
    private var process: Process?
    private var stopped = false

    init(onSample: @escaping @Sendable ([ProcSample]) -> Void) {
        self.onSample = onSample
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.runLoop() }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    private func runLoop() {
        while !stopped {
            runOnce()
            if !stopped { Thread.sleep(forTimeInterval: 2) }   // çökerse/kapanırsa yeniden başlat
        }
    }

    private func runOnce() {
        // nettop'u doğrudan sözde terminale (pty) bağla: satır satır, gecikmesiz çıktı verir.
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }
        var t = termios()
        tcgetattr(slave, &t); cfmakeraw(&t); tcsetattr(slave, TCSANOW, &t)

        let p = Process()
        // nettop ebeveyni ölünce kendiliğinden kapanmıyor; küçük bir kabuk bekçisi uygulama
        // (PID) yaşadığı sürece onu çalıştırır, uygulama nasıl kapanırsa kapansın onu da sonlandırır.
        let watchdog = """
        P=$1; shift; "$@" & C=$!
        while kill -0 "$P" 2>/dev/null && kill -0 "$C" 2>/dev/null; do sleep 1; done
        kill "$C" 2>/dev/null
        """
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog, "sh", String(getpid()), "/usr/bin/nettop",
                       "-L", "0", "-s", "1", "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out"]
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        p.standardOutput = slaveHandle
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { close(master); return }
        try? slaveHandle.close()           // ebeveynde slave'e gerek yok
        process = p
        defer { close(master) }
        var readBuf = [UInt8](repeating: 0, count: 65536)
        var buffer = Data()
        var current: [Substring] = []
        var started = false
        while true {
            // pty okuması süreç bitince EIO döner; FileHandle.availableData burada istisna atardı.
            let n = read(master, &readBuf, readBuf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }                            // EOF/EIO: süreç bitti
            buffer.append(contentsOf: readBuf[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let raw = String(data: lineData, encoding: .utf8) else { continue }
                let line = raw.trimmingCharacters(in: .controlCharacters)
                if line.contains(",bytes_in,bytes_out") {
                    // Yeni örnek başlığı → önceki örnek tamamlandı.
                    if started { onSample(NettopReader.parse(current)) }
                    started = true
                    current.removeAll(keepingCapacity: true)
                } else if started, !line.isEmpty {
                    current.append(Substring(line))
                }
            }
        }
        p.waitUntilExit()
        process = nil
    }
}

enum NettopReader {
    static func parse(_ lines: [Substring]) -> [ProcSample] {
        var out: [ProcSample] = []
        for line in lines {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3,
                  let bi = UInt64(cols[1]), let bo = UInt64(cols[2]) else { continue }
            let id = String(cols[0])

            if id.contains("<->") {
                // Bağlantı satırı: önceki süreç satırına aittir.
                guard !out.isEmpty, let c = parseConn(id, owner: out[out.count - 1].key, bi, bo) else { continue }
                out[out.count - 1].conns.append(c)
            } else {
                guard let dot = id.lastIndex(of: "."),
                      let pid = Int32(id[id.index(after: dot)...]) else { continue }
                out.append(ProcSample(key: id, name: String(id[..<dot]), pid: pid, bytesIn: bi, bytesOut: bo))
            }
        }
        return out
    }

    /// "tcp4 192.168.1.5:5000<->17.57.146.56:5223" veya "tcp6 fe80::1%en0.5000<->2a00::1.443"
    private static func parseConn(_ s: String, owner: String, _ bi: UInt64, _ bo: UInt64) -> ConnSample? {
        let parts = s.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let proto = String(parts[0])
        let ends = parts[1].components(separatedBy: "<->")
        guard ends.count == 2 else { return nil }
        let remote = ends[1]
        let sep: Character = proto.hasSuffix("6") ? "." : ":"
        var ip = remote, port = ""
        if let i = remote.lastIndex(of: sep) {
            ip = String(remote[..<i]); port = String(remote[remote.index(after: i)...])
        }
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        return ConnSample(key: owner + "|" + s, proto: proto, remoteIP: ip, remotePort: port,
                          isLocal: isLocalAddress(ip), bytesIn: bi, bytesOut: bo)
    }

    static func isLocalAddress(_ ip: String) -> Bool {
        if ip == "*" || ip.isEmpty || ip == "::1" { return true }
        let l = ip.lowercased()
        if l.contains(":") {
            return l.hasPrefix("fe80") || l.hasPrefix("fc") || l.hasPrefix("fd") || l.hasPrefix("ff")
        }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        switch (o[0], o[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (224..., _): return true          // multicast / broadcast
        default: return false
        }
    }
}
