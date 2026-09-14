import Foundation
import os

/// Keeps `ssh -N -L <local>:127.0.0.1:8443 <alias>` alive for dev boxes whose
/// container IP is not reachable directly.
///
/// Why this exists: some of these pods answer ICMP but have every TCP port
/// blocked from outside the cluster, so the daemon's REST API is unreachable at
/// its own address even though it is listening on 0.0.0.0. SSH through the
/// platform's jump host still works — that is how the terminal reaches them —
/// and a forwarded port over that connection answers in ~0.2s.
///
/// A bare `ssh -fN` is not enough on its own: it dies quietly, leaving the
/// local port bound by nothing, which looks exactly like a host that is up but
/// refusing requests. So the process is supervised here, with keep-alives on
/// and a restart when it exits.
@MainActor
final class SSHTunnelManager {
    static let shared = SSHTunnelManager()

    private let log = Logger(subsystem: "com.ccswitcher", category: "SSHTunnel")
    private var processes: [UUID: Process] = [:]
    private var restartTasks: [UUID: Task<Void, Never>] = [:]

    /// Local ports are derived from the host id so the same box always gets the
    /// same port — across launches, not just within one. `UUID.hashValue` is
    /// seeded per process and would drift, so this folds the raw bytes instead.
    ///
    /// Pure derivation, so `RemoteHost.baseURL` can call it off the main actor.
    nonisolated static func localPort(for host: RemoteHost) -> Int {
        if let fixed = host.localTunnelPort { return fixed }
        let bytes = withUnsafeBytes(of: host.id.uuid) { Array($0) }
        let folded = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 80 }
        return 18400 + folded
    }

    /// Whether a tunnel process is up for this host (not whether it forwards).
    func isRunning(hostID: UUID) -> Bool {
        processes[hostID]?.isRunning == true
    }

    /// Can we bind this port on IPv4 loopback?
    ///
    /// Worth checking before handing the port to ssh: `ExitOnForwardFailure`
    /// only fires when *every* bind fails, so a port already owned by another
    /// process on 127.0.0.1 still leaves ssh happily listening on ::1 alone.
    /// The tunnel then looks healthy while the other process answers — and
    /// silently never speaks TLS — which reads as a daemon that hangs.
    nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// First free port at or after `start`, skipping ports other hosts have
    /// claimed. A port whose tunnel has not been built yet still probes as
    /// free, so "unbound" is not the same as "available".
    nonisolated static func firstFreePort(from start: Int, excluding claimed: Set<Int>) -> Int? {
        (0..<60).lazy.map { start + $0 }
            .first { !claimed.contains($0) && isPortFree($0) }
    }

    func ensureRunning(for host: RemoteHost) {
        guard host.useSSHTunnel else {
            stop(hostID: host.id)
            return
        }
        if let p = processes[host.id], p.isRunning { return }
        start(host: host)
    }

    func stop(hostID: UUID) {
        restartTasks[hostID]?.cancel()
        restartTasks[hostID] = nil
        if let p = processes[hostID], p.isRunning { p.terminate() }
        processes[hostID] = nil
    }

    /// Tear the forward down and build a new one. An ssh that is still running
    /// is not proof the forward works — a channel can stall while the process
    /// stays alive and the local port stays bound, which looks identical to a
    /// daemon that accepts connections and never answers. When reads keep
    /// failing, replacing the tunnel is the only thing that clears that.
    func recycle(host: RemoteHost) {
        guard host.useSSHTunnel else { return }
        log.info("[\(host.effectiveSSHAlias, privacy: .public)] recycling stalled tunnel")
        stop(hostID: host.id)
        start(host: host)
    }

    func stopAll() {
        for id in processes.keys { stop(hostID: id) }
    }

    private func start(host: RemoteHost) {
        let port = Self.localPort(for: host)
        let alias = host.effectiveSSHAlias
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            // Detect a dead peer instead of holding a socket that forwards
            // nothing — the failure mode that made this look like a server bug.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(port):127.0.0.1:8443",
            alias
        ]
        // Discard rather than pipe: nothing reads these, and an undrained pipe
        // would eventually block the ssh process itself.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("[\(alias, privacy: .public)] tunnel failed to start: \(error.localizedDescription, privacy: .public)")
            scheduleRestart(host: host, after: 30)
            return
        }
        processes[host.id] = process
        log.info("[\(alias, privacy: .public)] tunnel up on 127.0.0.1:\(port)")

        // Supervise: when ssh exits for any reason, bring it back.
        let id = host.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.processes[id] != nil else { return }   // deliberate stop
                self.processes[id] = nil
                self.scheduleRestart(host: host, after: 5)
            }
        }
    }

    private func scheduleRestart(host: RemoteHost, after seconds: Int) {
        restartTasks[host.id]?.cancel()
        restartTasks[host.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.ensureRunning(for: host) }
        }
    }
}
