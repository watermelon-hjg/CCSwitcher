import Foundation
import os

/// Reads the dev boxes' token ledger so their usage joins this Mac's in the
/// cost and activity panels.
///
/// **Why SSH and not the REST API.** The clauth daemon's API serves limit
/// percentages only — no token breakdown. The per-day / per-model / per-hour
/// counts live in `~/.clauth/token_ledger.json`, which is 37 KB and reachable
/// over the SSH aliases the user already has configured.
///
/// **Why one host, not the sum of three.** The dev boxes symlink
/// `~/.claude/projects` to one shared directory, so every clauth instance
/// parses the same sessions and writes an identical ledger. Summing them would
/// triple-count. One host's ledger already represents all of them; the others
/// are only useful as fallbacks when the first is unreachable.
///
/// The Mac's own sessions live in its own `~/.claude/projects`, which the dev
/// boxes never see, so local + remote add up with no overlap.
actor RemoteLedgerService {
    private let log = Logger(subsystem: "com.ccswitcher", category: "RemoteLedger")

    /// Written by the aggregator we deploy: the whole transcript store folded
    /// into per-day / per-model / per-hour totals, deduped the same way this app
    /// dedups locally. clauth's own `token_ledger.json` only holds a few recent
    /// days, which is why we do not read it.
    private static let ledgerPath = "~/.cc_aggregate.json"
    private static let aggregatorPath = "/tmp/cc_aggregate.py"
    private static let timeout: TimeInterval = 60

    /// Ledger shape: `days[yyyy-MM-dd][model] = { input, output, cache_read, cache_create, hours[24] }`
    private struct Ledger: Decodable {
        let days: [String: [String: ModelDay]]
        let range: [String]?
        let generatedAt: String?

        enum CodingKeys: String, CodingKey {
            case days, range
            case generatedAt = "generated_at"
        }
    }

    private struct ModelDay: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheCreate: Int?
        let hours: [Int]?
        let msgs: Int?

        enum CodingKeys: String, CodingKey {
            case input, output, hours, msgs
            case cacheRead = "cache_read"
            case cacheCreate = "cache_create"
        }
    }

    /// What the panels need from the dev boxes.
    struct RemoteUsage {
        var dailyCosts: [DailyCost] = []
        /// model -> total input+output tokens, for the "favourite model" split.
        var modelTokens: [String: Int] = [:]
        /// "yyyy-MM-dd" -> hour (0..23) -> token total, for the activity heatmap.
        var hourly: [String: [Int]] = [:]
        var sourceHost: String?
        var recordedThrough: String?
        var earliestDate: String?
        var totalMessages: Int = 0
        /// "yyyy-MM-dd" -> display model name -> message count, the same unit
        /// the activity panel counts locally so the two can be added.
        var dailyModelMessages: [String: [String: Int]] = [:]
    }

    /// Try each alias in turn; the first that answers wins. A dev box that is
    /// rebuilt or asleep is the normal case, not an error worth surfacing.
    func fetch(aliases: [String]) async -> RemoteUsage? {
        for alias in aliases where !alias.isEmpty {
            // Refresh first: the aggregator keeps a per-file size+mtime cache,
            // so a repeat run over the 4 GB store touches only new transcripts
            // and finishes in seconds. Failure here is not fatal — a stale
            // aggregate still beats no data.
            await refreshRemote(alias: alias)
            guard let data = await run(alias: alias) else { continue }
            guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
                log.error("[\(alias, privacy: .public)] ledger did not decode")
                continue
            }
            var usage = await convert(ledger)
            usage.sourceHost = alias
            return usage
        }
        return nil
    }

    /// When the aggregator last ran, so a busy box is not asked to walk a 4 GB
    /// transcript store on every panel refresh.
    private var lastAggregateRun: [String: Date] = [:]
    private static let aggregateMinInterval: TimeInterval = 600

    /// Re-run the aggregator on the box, ignoring failures.
    private func refreshRemote(alias: String) async {
        if let last = lastAggregateRun[alias],
           Date().timeIntervalSince(last) < Self.aggregateMinInterval {
            return
        }
        lastAggregateRun[alias] = Date()
        _ = await shell(alias: alias,
                        command: "test -f \(Self.aggregatorPath) && python3 \(Self.aggregatorPath) >/dev/null 2>&1",
                        timeout: 120)
    }

    private func run(alias: String) async -> Data? {
        await shell(alias: alias, command: "cat \(Self.ledgerPath)", timeout: Self.timeout)
    }

    private func shell(alias: String, command: String, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=20",
                "-o", "StrictHostKeyChecking=accept-new",
                alias, command
            ]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()

            // A hung ssh must not wedge the refresh loop.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                continuation.resume(returning: nil)
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            continuation.resume(returning: process.terminationStatus == 0 && !data.isEmpty ? data : nil)
        }
    }

    /// "claude-fable-5-1" -> "Fable", so the panels read the same way whether a
    /// day's figure came from this Mac or a dev box.
    static func displayName(_ id: String) -> String {
        let l = id.lowercased()
        if l.contains("fable") { return "Fable" }
        if l.contains("opus") { return "Opus" }
        if l.contains("sonnet") { return "Sonnet" }
        if l.contains("haiku") { return "Haiku" }
        return id
    }

    private func convert(_ ledger: Ledger) async -> RemoteUsage {
        // Use the app's own litellm-backed table: the static one has no entry
        // for current ids like `claude-opus-5`, which silently priced at zero.
        await PricingService.shared.ensureLoaded()
        var usage = RemoteUsage()
        usage.recordedThrough = ledger.range?.last

        for (date, models) in ledger.days {
            var cost = 0.0
            var breakdown: [String: Double] = [:]
            var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
            var hours = [Int](repeating: 0, count: 24)

            for (model, day) in models {
                // `<synthetic>` is Claude Code's own bookkeeping, not a billable model.
                guard model != "<synthetic>" else { continue }
                let i = day.input ?? 0, o = day.output ?? 0
                let cr = day.cacheRead ?? 0, cc = day.cacheCreate ?? 0
                input += i; output += o; cacheRead += cr; cacheWrite += cc

                let modelCost = await PricingService.shared.pricing(for: model)?
                    .cost(input: i, output: o,
                          cacheCreate: cc, cacheCreate1h: 0,
                          cacheRead: cr, isFast: false) ?? 0
                cost += modelCost
                breakdown[Self.displayName(model), default: 0] += modelCost
                usage.modelTokens[model, default: 0] += i + o
                usage.totalMessages += day.msgs ?? 0
                let short = Self.displayName(model)
                usage.dailyModelMessages[date, default: [:]][short, default: 0] += day.msgs ?? 0

                if let buckets = day.hours {
                    for (idx, v) in buckets.prefix(24).enumerated() { hours[idx] += v }
                }
            }

            usage.hourly[date] = hours
            usage.dailyCosts.append(
                DailyCost(date: date,
                          totalCost: cost,
                          modelBreakdown: breakdown,
                          sessionCount: 0,      // the ledger does not count sessions
                          inputTokens: input,
                          outputTokens: output,
                          cacheWriteTokens: cacheWrite,
                          cacheReadTokens: cacheRead)
            )
        }
        usage.dailyCosts.sort { $0.date > $1.date }
        usage.earliestDate = ledger.range?.first
        return usage
    }
}
