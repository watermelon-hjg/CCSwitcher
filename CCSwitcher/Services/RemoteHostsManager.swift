import Foundation
import Combine
import os
import Security

/// Owns the configured clauth daemons, their live state, and the merged view
/// the menu bar renders.
///
/// Each host is polled on its own task using the daemon's long-poll
/// (`?wait=`), so a switch on any machine reaches the menu bar in about as
/// long as the network takes rather than on a fixed interval. A host that
/// errors backs off instead of hammering a container that is down — these are
/// dev boxes that get rebuilt, and an unreachable one is the normal case, not
/// an exception worth retrying every second.
@MainActor
final class RemoteHostsManager: ObservableObject {
    /// Shared instance, so non-SwiftUI call sites (StatusItemController) can
    /// reach it without threading it through every initializer.
    static let shared = RemoteHostsManager()

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var states: [UUID: RemoteHostState] = [:]
    @Published var isSwitching: Set<UUID> = []
    /// Dev-box usage merged into the cost and activity panels.
    @Published private(set) var remoteUsage: RemoteLedgerService.RemoteUsage?
    @Published private(set) var ledgerRefreshing = false

    private let service = RemoteClauthService()
    private let ledgerService = RemoteLedgerService()
    private let log = Logger(subsystem: "com.ccswitcher", category: "RemoteHosts")
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    private static let storageKey = "remoteClauthHosts"
    /// Retry delay after a failed read. Backs off so a box that has been down
    /// for hours is not polled every 30s, but stays capped so recovery is still
    /// noticed within a few minutes — these containers get rebuilt often.
    private static let retryDelays: [Int] = [20, 45, 90, 180, 300]

    private static func retryDelay(failures: Int) -> Duration {
        let idx = min(max(failures - 1, 0), retryDelays.count - 1)
        return .seconds(retryDelays[idx])
    }

    init() {
        load()
        startPolling()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return }
        hosts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Host CRUD

    func addHost(_ host: RemoteHost, token: String) {
        hosts.append(host)
        RemoteTokenStore.save(token, for: host)
        persist()
        restartPolling(for: host.id)
    }

    func updateHost(_ host: RemoteHost, token: String? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        if let token { RemoteTokenStore.save(token, for: host) }
        persist()
        restartPolling(for: host.id)
    }

    func removeHost(_ id: UUID) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        states[id] = nil
        RemoteTokenStore.delete(for: host)
        SSHTunnelManager.shared.stop(hostID: id)
        hosts.removeAll { $0.id == id }
        persist()
    }

    /// Accept the certificate a host is presenting now — the deliberate step
    /// after a container rebuild re-signs against a new hostname/IP.
    func trustCurrentCertificate(for id: UUID) async {
        guard var host = hosts.first(where: { $0.id == id }) else { return }
        let probed = await RemoteClauthService.probeFingerprint(host: host)
        guard let probed else { return }
        host.pinnedFingerprint = probed
        updateHost(host)
    }

    // MARK: - Polling

    private func startPolling() {
        for host in hosts where host.enabled {
            restartPolling(for: host.id)
        }
    }

    private func restartPolling(for id: UUID) {
        pollTasks[id]?.cancel()
        guard let host = hosts.first(where: { $0.id == id }), host.enabled else {
            pollTasks[id] = nil
            SSHTunnelManager.shared.stop(hostID: id)
            return
        }
        // Bring the forward up before the first read, so the first attempt is
        // not a guaranteed failure that starts the backoff ladder.
        if let host = resolvingTunnelPort(host) {
            SSHTunnelManager.shared.ensureRunning(for: host)
        }
        pollTasks[id] = Task { [weak self] in
            await self?.pollLoop(hostID: id)
        }
    }

    /// Move a tunnelled host off a port another process already owns, and
    /// remember the choice so the URL and the forward stay in agreement.
    ///
    /// Returns nil when the record was rewritten — `updateHost` restarts this
    /// same path with the new port, so there is nothing left to do here.
    private func resolvingTunnelPort(_ host: RemoteHost) -> RemoteHost? {
        guard host.useSSHTunnel,
              !SSHTunnelManager.shared.isRunning(hostID: host.id) else { return host }
        let claimed = Set(hosts.filter { $0.id != host.id && $0.useSSHTunnel }
                               .map { SSHTunnelManager.localPort(for: $0) })
        let wanted = SSHTunnelManager.localPort(for: host)
        let taken = claimed.contains(wanted) || !SSHTunnelManager.isPortFree(wanted)
        guard taken,
              let free = SSHTunnelManager.firstFreePort(from: wanted + 1, excluding: claimed)
        else { return host }
        log.info("[\(host.name, privacy: .public)] local port \(wanted) is taken, using \(free)")
        var moved = host
        moved.localTunnelPort = free
        updateHost(moved)
        return nil
    }

    private func pollLoop(hostID: UUID) async {
        var isFirst = true
        while !Task.isCancelled {
            guard let host = hosts.first(where: { $0.id == hostID }), host.enabled else { return }
            guard let token = RemoteTokenStore.load(for: host) else {
                let fails = (states[hostID]?.failureCount ?? 0) + 1
                let delay = Self.retryDelay(failures: fails)
                states[hostID] = RemoteHostState(
                    hostID: hostID, status: nil, error: .unauthorized,
                    lastFetched: Date(), failureCount: fails,
                    nextRetryAt: Date().addingTimeInterval(Double(delay.components.seconds)))
                try? await Task.sleep(for: delay)
                continue
            }

            // First read is a plain GET so the UI fills immediately; later reads
            // long-poll so a remote switch lands without a polling interval.
            let result = await service.fetchStatus(host: host, token: token, wait: !isFirst)
            isFirst = false

            switch result {
            case .success(let status):
                if let status {
                    states[hostID] = RemoteHostState(hostID: hostID, status: status,
                                                     error: nil, lastFetched: Date(),
                                                     failureCount: 0, nextRetryAt: nil)
                } else {
                    // 304: content unchanged, keep what we have but refresh the stamp.
                    states[hostID]?.lastFetched = Date()
                    states[hostID]?.error = nil
                    states[hostID]?.failureCount = 0
                    states[hostID]?.nextRetryAt = nil
                }
            case .failure(let err):
                // A refresh cancels this task's in-flight long poll, which
                // surfaces as a read failure. Writing it would race the
                // replacement task's success and could leave the host showing
                // an error while it is perfectly reachable — so drop it.
                guard !Task.isCancelled else { return }
                let previous = states[hostID]?.status
                let fails = (states[hostID]?.failureCount ?? 0) + 1
                let delay = Self.retryDelay(failures: fails)
                states[hostID] = RemoteHostState(
                    hostID: hostID, status: previous, error: err, lastFetched: Date(),
                    failureCount: fails,
                    nextRetryAt: Date().addingTimeInterval(Double(delay.components.seconds)))
                log.error("[\(host.name, privacy: .public)] \(err.localizedText, privacy: .public) (retry #\(fails))")
                // A tunnelled host that keeps timing out is most likely a
                // stalled forward, not a dead daemon — rebuild it before the
                // backoff grows to minutes.
                if host.useSSHTunnel, fails % 2 == 0 {
                    SSHTunnelManager.shared.recycle(host: host)
                }
                // A changed certificate never heals on its own — it needs the
                // user to confirm the new fingerprint — so stop hammering it.
                if err.isCertificateMismatch { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Pull the token ledger from the first reachable box. One ledger covers
    /// every box (they share one sessions directory), so this is not a sum.
    func refreshLedger() async {
        guard !ledgerRefreshing else { return }
        ledgerRefreshing = true
        defer { ledgerRefreshing = false }
        let aliases = hosts.filter(\.enabled).map(\.effectiveSSHAlias)
        guard !aliases.isEmpty else { remoteUsage = nil; return }
        remoteUsage = await ledgerService.fetch(aliases: aliases)
    }

    func refreshNow() {
        Task { await refreshLedger() }
        for host in hosts where host.enabled {
            restartPolling(for: host.id)
        }
    }

    // MARK: - Switching

    @discardableResult
    func switchProfile(hostID: UUID, to profile: String) async -> RemoteError? {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let token = RemoteTokenStore.load(for: host) else { return .unauthorized }
        isSwitching.insert(hostID)
        defer { isSwitching.remove(hostID) }

        let result = await service.switchProfile(host: host, token: token, profile: profile)
        // The daemon republishes before answering, so re-reading now sees the
        // new active profile rather than the pre-switch one.
        restartPolling(for: hostID)
        if case .failure(let err) = result { return err }
        return nil
    }

    // MARK: - Merged view

    /// What the menu bar shows: one set of windows plus whether the machines
    /// agree on which account they are running.
    struct MergedView {
        var windows: [ClauthWindow] = []
        var activeProfileName: String?
        var onlineCount: Int = 0
        var totalCount: Int = 0
        /// True when reachable hosts are NOT all on the same profile — the one
        /// case where a single merged number would be misleading.
        var diverged: Bool = false
        var anyCertificateMismatch: Bool = false
        var anyStale: Bool = false
    }

    var merged: MergedView {
        var view = MergedView()
        let enabled = hosts.filter(\.enabled)
        view.totalCount = enabled.count

        var freshest: (date: Date, profile: ClauthProfile)?
        var activeNames = Set<String>()

        for host in enabled {
            guard let state = states[host.id] else { continue }
            if state.error?.isCertificateMismatch == true { view.anyCertificateMismatch = true }
            guard let profile = state.activeProfile else { continue }
            view.onlineCount += 1
            activeNames.insert(profile.name)
            if profile.isStale { view.anyStale = true }
            let stamp = state.lastFetched ?? .distantPast
            if freshest == nil || stamp > freshest!.date {
                freshest = (stamp, profile)
            }
        }

        view.diverged = activeNames.count > 1
        view.activeProfileName = activeNames.count == 1 ? activeNames.first : nil
        view.windows = freshest?.profile.windows ?? []
        return view
    }

    /// The scoped window (Fable / Opus…) of the merged view, if any.
    var mergedScopedWindow: ClauthWindow? {
        merged.windows.first(where: \.isScoped)
    }

    func window(labeled label: String) -> ClauthWindow? {
        merged.windows.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }
}

// MARK: - Token storage

/// Bearer tokens live in the login keychain, never in UserDefaults — they grant
/// a switch on the remote machine, so they are treated like the account
/// credentials the app already stores there.
enum RemoteTokenStore {
    private static let service = "com.ccswitcher.remote-clauth"

    static func save(_ token: String, for host: RemoteHost) {
        delete(for: host)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.tokenKeychainKey,
            kSecValueData as String: Data(token.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for host: RemoteHost) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.tokenKeychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for host: RemoteHost) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.tokenKeychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
