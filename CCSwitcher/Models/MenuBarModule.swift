import Foundation

/// One configurable module rendered in the macOS menu bar.
///
/// Display style matches iStats / Stats: two-line stacked module with a short
/// uppercase label on top and either a bar (for percentages) or a value text
/// (for absolute numbers / times) on the bottom.
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case account
    case sessionBar
    case sessionBarPlain
    case weeklyBar
    case weeklyBarPlain
    case dailyCost
    case sessionReset
    case weeklyReset
    /// Plan-scoped weekly window (e.g. "7d fable", "7d Opus"). The label comes
    /// from the API, so one module covers every plan tier.
    case scopedBar
    case scopedBarPlain

    var id: String { rawValue }

    /// Short uppercase label shown on the top line of the module.
    var compactLabel: String {
        switch self {
        case .account:         return "@"
        case .sessionBar:      return "5H"
        case .sessionBarPlain: return "5H"
        case .weeklyBar:       return "7D"
        case .weeklyBarPlain:  return "7D"
        case .dailyCost:       return "TODAY"
        case .sessionReset:    return "5H↻"
        case .weeklyReset:     return "7D↻"
        case .scopedBar:       return "7D*"
        case .scopedBarPlain:  return "7D*"
        }
    }

    /// True when the module renders the plan-scoped weekly window, whose top
    /// label is replaced at render time by the API-supplied one.
    var usesScopedLabel: Bool {
        self == .scopedBar || self == .scopedBarPlain
    }


    /// Human-readable name shown in the Settings reorder list.
    var localizedDisplayName: String {
        switch self {
        case .account:         return String(localized: "Account name", bundle: L10n.bundle)
        case .sessionBar:      return String(localized: "Session — usage vs time (5h)", bundle: L10n.bundle)
        case .sessionBarPlain: return String(localized: "Session usage (5h)", bundle: L10n.bundle)
        case .weeklyBar:       return String(localized: "Weekly — usage vs time (7d)", bundle: L10n.bundle)
        case .weeklyBarPlain:  return String(localized: "Weekly usage (7d)", bundle: L10n.bundle)
        case .dailyCost:       return String(localized: "Daily cost", bundle: L10n.bundle)
        case .sessionReset:    return String(localized: "Session reset countdown", bundle: L10n.bundle)
        case .weeklyReset:     return String(localized: "Weekly reset countdown", bundle: L10n.bundle)
        case .scopedBar:       return String(localized: "Plan window — usage vs time (7d scoped)", bundle: L10n.bundle)
        case .scopedBarPlain:  return String(localized: "Plan window usage (7d scoped)", bundle: L10n.bundle)
        }
    }

    /// Display name that names the account's actual scoped model when one is
    /// known ("Fable usage (7d)"), so the settings row matches what the menu
    /// bar renders. Falls back to the generic wording for accounts with no
    /// scoped window (Pro) or before the first usage fetch lands.
    func localizedDisplayName(scopedModelName: String?) -> String {
        guard usesScopedLabel, let name = scopedModelName, !name.isEmpty else {
            return localizedDisplayName
        }
        switch self {
        case .scopedBar:
            return String(format: String(localized: "%@ — usage vs time (7d)", bundle: L10n.bundle), name)
        case .scopedBarPlain:
            return String(format: String(localized: "%@ usage (7d)", bundle: L10n.bundle), name)
        default:
            return localizedDisplayName
        }
    }
}

/// Persistence helpers for the user's chosen module ordering.
enum MenuBarModuleStore {
    static let storageKey = "menuBarModules"
    static let migrationKey = "menuBarModulesMigratedV1"
    static let legacyShowAccountNameKey = "showAccountName"

    /// Decode resiliently: a single unknown/renamed rawValue (e.g. from a
    /// newer build or hand-edited prefs) must NOT wipe the whole list. We
    /// decode as `[String]` and keep the values that map to a known case.
    static func decode(_ data: Data) -> [MenuBarModule] {
        guard let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap(MenuBarModule.init(rawValue:))
    }

    static func encode(_ modules: [MenuBarModule]) -> Data {
        (try? JSONEncoder().encode(modules)) ?? Data()
    }

    /// Seed the new storage on first launch (fresh install or not-yet-migrated
    /// upgrade). Idempotent — runs once and never clobbers an existing
    /// `menuBarModules` value (so users already on 1.8.x keep their config).
    ///
    /// Default for new/unconfigured users: account name + the plain session
    /// and weekly usage bars. Upgraders who had explicitly turned the legacy
    /// "show account name" toggle OFF wanted a minimal menu bar, so they get
    /// nothing (their intent is preserved).
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        // If real config already exists, just mark migrated and leave it alone.
        if defaults.data(forKey: storageKey) != nil {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let legacy = defaults.object(forKey: legacyShowAccountNameKey) as? Bool ?? true
        let seed: [MenuBarModule] = legacy ? [.account, .sessionBarPlain, .weeklyBarPlain] : []
        defaults.set(encode(seed), forKey: storageKey)
        defaults.set(true, forKey: migrationKey)
    }
}
