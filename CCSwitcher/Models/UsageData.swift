import Foundation

// MARK: - Usage API Response (from /api/oauth/usage)

struct UsageAPIResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let iguanaNecktie: UsageWindow?
    let extraUsage: ExtraUsage?
    /// Modern generic shape: every limit bar the account has, session + weekly.
    /// `kind == "weekly_scoped"` carries the plan-tier window (Fable, Opus…)
    /// with its display name under `scope.model.display_name`.
    let limits: [UsageLimit]?
    /// Older normalized shape kept as a fallback.
    let weeklyScoped: [ScopedUsageWindow]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
        case limits
        case weeklyScoped = "weekly_scoped"
    }

    /// Plan-scoped weekly windows, newest API shape first, then the normalized
    /// array, then the legacy fixed keys — so every account vintage renders.
    var scopedWindows: [ScopedUsageWindow] {
        if let limits {
            let scoped = limits
                .filter { $0.kind == "weekly_scoped" }
                .map { ScopedUsageWindow(label: $0.derivedLabel,
                                         utilization: $0.percent,
                                         resetsAt: $0.resetsAt) }
            if !scoped.isEmpty { return scoped }
        }
        if let weeklyScoped, !weeklyScoped.isEmpty { return weeklyScoped }
        var legacy: [ScopedUsageWindow] = []
        if let w = sevenDayOpus {
            legacy.append(ScopedUsageWindow(label: "7d Opus", utilization: w.utilization, resetsAt: w.resetsAt))
        }
        if let w = sevenDaySonnet {
            legacy.append(ScopedUsageWindow(label: "7d Sonnet", utilization: w.utilization, resetsAt: w.resetsAt))
        }
        return legacy
    }
}

/// One entry of the API's generic `limits` array.
struct UsageLimit: Codable {
    let group: String?
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let severity: String?
    let isActive: Bool?
    let scope: UsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case group, kind, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// "7d Fable" for a model-scoped weekly bar; a plain "7d" when the API
    /// names no model. Never switch on this — it is display text only.
    var derivedLabel: String {
        if let name = scope?.model?.displayName, !name.isEmpty { return "7d \(name)" }
        return "7d"
    }
}

struct UsageLimitScope: Codable {
    let model: UsageLimitModel?
    let surface: String?
}

struct UsageLimitModel: Codable {
    let displayName: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case id
    }
}

/// A plan-scoped weekly window carrying its own display label.
struct ScopedUsageWindow: Codable, Identifiable {
    let label: String
    let utilization: Double?
    let resetsAt: String?

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label
        case utilization
        case resetsAt = "resets_at"
    }

    /// Reuse `UsageWindow`'s date/countdown rendering without duplicating it.
    var window: UsageWindow { UsageWindow(utilization: utilization, resetsAt: resetsAt) }
}

struct UsageWindow: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    var resetTimeString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            return formatter.string(from: date)
        } else if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }

    /// Compact countdown rendering for narrow menu-bar modules.
    /// Always returns a fixed-shape string ("now", "5m", "2h 14m", "4d 6h").
    /// Never falls back to a date format — the menu bar can't afford the width.
    var compactResetString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = Int(date.timeIntervalSinceNow)
        guard remaining > 0 else { return "now" }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3600
        let minutes = (remaining % 3600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// How much of the rate-limit window has already elapsed, as a 0–100
    /// percentage: `1 − remaining / windowSeconds`, clamped to [0, 100].
    /// `windowSeconds` is the fixed window length (5h = 18000, 7d = 604800).
    /// Returns nil if there's no reset timestamp. Compared against the usage
    /// bar this shows whether you're burning faster or slower than the clock.
    func elapsedPercent(windowSeconds: Double) -> Double? {
        guard windowSeconds > 0, let date = resetsAtDate else { return nil }
        let elapsed = 1.0 - (date.timeIntervalSinceNow / windowSeconds)
        return min(max(elapsed, 0), 1) * 100
    }
}

/// Fixed rate-limit window lengths, in seconds.
enum RateLimitWindow {
    static let fiveHourSeconds: Double = 5 * 60 * 60       // 18,000
    static let sevenDaySeconds: Double = 7 * 24 * 60 * 60  // 604,800
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - Stats Cache (matches ~/.claude/stats-cache.json)

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]?
    let totalSessions: Int?
    let totalMessages: Int?
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct DailyActivity: Codable, Identifiable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int

    var id: String { date }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

struct LongestSession: Codable {
    let sessionId: String?
    let duration: Int?
    let messageCount: Int?
    let timestamp: String?
}

// MARK: - Computed Usage Summary

struct UsageSummary {
    let weeklyMessages: Int
    let weeklySessionCount: Int
    let weeklyToolCalls: Int
    let todayMessages: Int
    let todaySessionCount: Int
    let todayToolCalls: Int
    let totalMessages: Int
    let totalSessions: Int
    let dailyActivity: [DailyActivity]

    static let empty = UsageSummary(
        weeklyMessages: 0,
        weeklySessionCount: 0,
        weeklyToolCalls: 0,
        todayMessages: 0,
        todaySessionCount: 0,
        todayToolCalls: 0,
        totalMessages: 0,
        totalSessions: 0,
        dailyActivity: []
    )
}

// MARK: - Session Info (from ~/.claude/sessions/*.json)

struct SessionInfo: Codable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String?
    let startedAt: Double?

    var id: String { sessionId }

    var startDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }
}
