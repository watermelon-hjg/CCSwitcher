import Foundation

/// One clauth daemon reachable over its TLS REST API (`clauth daemon --listen`).
///
/// The daemon serves `/api/v1/status` — the same `status.json` body it publishes
/// locally — plus `/api/v1/switch`. Its certificate is self-signed and per-host
/// (CN and SAN carry that container's own name and IP), so each host pins its
/// own SHA-256 fingerprint rather than trusting a shared CA.
struct RemoteHost: Codable, Identifiable, Equatable {
    var id: UUID
    /// Display name, defaults to the SSH alias the user already knows.
    var name: String
    var host: String
    var port: Int
    /// SHA-256 of the DER certificate, uppercase hex, no separators.
    /// `nil` until the first connection records one (trust-on-first-use).
    var pinnedFingerprint: String?
    var enabled: Bool
    /// SSH alias used to read this box's token ledger. Defaults to `name`,
    /// which is already the alias in practice.
    var sshAlias: String?
    /// Reach the daemon through a forwarded port instead of its own address.
    /// Needed for pods whose TCP ports are blocked from outside the cluster.
    var useSSHTunnel: Bool = false
    /// Fixed local port for that forward; derived from the id when unset.
    var localTunnelPort: Int?

    init(id: UUID = UUID(),
         name: String,
         host: String,
         port: Int = 8443,
         pinnedFingerprint: String? = nil,
         enabled: Bool = true,
         sshAlias: String? = nil,
         useSSHTunnel: Bool = false,
         localTunnelPort: Int? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.pinnedFingerprint = pinnedFingerprint
        self.enabled = enabled
        self.sshAlias = sshAlias
        self.useSSHTunnel = useSSHTunnel
        self.localTunnelPort = localTunnelPort
    }

    /// The alias to shell out to; falls back to the display name.
    var effectiveSSHAlias: String { (sshAlias?.isEmpty == false ? sshAlias! : name) }

    /// Where to send requests: the box's own address, or the local end of the
    /// tunnel. The daemon's certificate lists 127.0.0.1 in its SAN, so the
    /// forwarded address validates the same way the direct one does.
    var baseURL: URL? {
        if useSSHTunnel {
            return URL(string: "https://127.0.0.1:\(SSHTunnelManager.localPort(for: self))")
        }
        return URL(string: "https://\(host):\(port)")
    }

    /// Keychain account key for this host's bearer token.
    var tokenKeychainKey: String { "remote-clauth-\(id.uuidString)" }
}

// MARK: - status.json (schema 2)

/// The daemon's published status feed. Field names match the wire format.
struct ClauthStatus: Codable {
    let schema: Int?
    let generatedAt: String?
    let activeProfile: String?
    let pendingSwitch: String?
    let refreshIntervalMs: Int?
    let profiles: [ClauthProfile]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case activeProfile = "active_profile"
        case pendingSwitch = "pending_switch"
        case refreshIntervalMs = "refresh_interval_ms"
        case profiles
    }
}

struct ClauthProfile: Codable, Identifiable {
    let name: String
    let active: Bool
    let tier: String?
    let authStatus: String?
    let fetchStatus: String?
    /// Additive in schema 2; absent means the reading is trusted.
    let stale: Bool?
    let hasLiveSession: Bool?
    let fetchedAt: String?
    let windows: [ClauthWindow]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, active, tier, stale, windows
        case authStatus = "auth_status"
        case fetchStatus = "fetch_status"
        case hasLiveSession = "has_live_session"
        case fetchedAt = "fetched_at"
    }

    /// `true` when the figures should be dimmed rather than read as current.
    var isStale: Bool { stale ?? false }
}

/// One usage window. `label` is derived by the daemon from the plan tier
/// ("5h", "7d", "7d fable", "7d Opus") — display text only, never a key.
struct ClauthWindow: Codable, Identifiable {
    let label: String
    let utilizationPct: Double
    let resetsAt: String?

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label
        case utilizationPct = "utilization_pct"
        case resetsAt = "resets_at"
    }

    /// The two windows every account has; anything else is plan-scoped.
    var isScoped: Bool {
        let l = label.lowercased()
        return l != "5h" && l != "7d"
    }

    /// "7d fable" -> "FABLE", for the menu bar's narrow top line.
    var compactLabel: String {
        guard isScoped else { return label.uppercased() }
        let trimmed = label
            .replacingOccurrences(of: "7d ", with: "")
            .replacingOccurrences(of: "7D ", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? label : trimmed).uppercased()
    }
}

// MARK: - Per-host fetch outcome

/// What the app knows about one remote host right now.
struct RemoteHostState: Identifiable {
    let hostID: UUID
    var status: ClauthStatus?
    var error: RemoteError?
    var lastFetched: Date?
    /// Consecutive failed reads; drives the retry delay and lets the UI say
    /// "retrying" rather than looking wedged.
    var failureCount: Int = 0
    var nextRetryAt: Date?

    var id: UUID { hostID }

    var isOnline: Bool { status != nil && error == nil }

    /// The profile this host is currently running on.
    var activeProfile: ClauthProfile? {
        guard let status else { return nil }
        return status.profiles.first { $0.active }
            ?? status.profiles.first { $0.name == status.activeProfile }
    }
}

enum RemoteError: Error, Equatable {
    case unreachable(String)
    case unauthorized
    /// The presented certificate does not match the pin. Carries the new
    /// fingerprint so the UI can ask the user to confirm a legitimate re-sign
    /// (container rebuilds re-issue the cert against a new hostname/IP).
    case certificateMismatch(expected: String, actual: String)
    case decodeFailed(String)
    case switchRefused(code: String, reason: String?)

    var isCertificateMismatch: Bool {
        if case .certificateMismatch = self { return true }
        return false
    }

    var localizedText: String {
        switch self {
        case .unreachable(let m):
            return String(format: String(localized: "Unreachable: %@", bundle: L10n.bundle), m)
        case .unauthorized:
            return String(localized: "Token rejected", bundle: L10n.bundle)
        case .certificateMismatch:
            return String(localized: "Certificate changed — confirm to trust", bundle: L10n.bundle)
        case .decodeFailed(let m):
            return String(format: String(localized: "Bad response: %@", bundle: L10n.bundle), m)
        case .switchRefused(let code, let reason):
            return reason.map { "\(code): \($0)" } ?? code
        }
    }
}
