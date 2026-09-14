import SwiftUI

/// A GitHub-style contribution grid over the merged history: this Mac's own
/// transcripts plus the dev boxes'.
///
/// The two sources parse different session stores, so a day's square is their
/// sum with no overlap. Intensity is ranked, not linear: one 10x day would
/// otherwise flatten every other day to the lightest shade.
struct ActivityHeatmapView: View {
    let dailyCosts: [DailyCost]
    var weeks: Int = 26

    /// The square under the pointer, with its grid position — deriving the
    /// card's placement from the index is exact, where converting a hover
    /// coordinate between spaces was not.
    @State private var hovered: (day: Day, col: Int, row: Int)?

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 7) {
                header
                HStack(alignment: .top, spacing: gap) {
                    weekdayLabels
                    grid(weeks: fittingWeeks(width: geo.size.width))
                }
                legend
            }
            // Overlaid rather than inserted, so the panel never reflows as the
            // pointer crosses squares — and deliberately NOT clamped to this
            // view: letting the card spill outside the activity box keeps it
            // off the grid the pointer is reading.
            .overlay(alignment: .topLeading) { floatingCard(container: geo.size) }
        }
        .frame(height: 7 * cell + 6 * gap + 46)
    }

    /// Follows the cursor, spilling outside the activity box, and flips to the
    /// pointer's left near the right edge. The panel this lives in is itself a
    /// menu-bar popover, and nesting a second popover there tends to dismiss
    /// the parent — so the card stays an overlay and is flipped rather than
    /// allowed to run off the panel and get clipped.
    @ViewBuilder
    private func floatingCard(container: CGSize) -> some View {
        if let h = hovered {
            // Beside the square, the same gap away on whichever side fits.
            // A wider card could not do this in a panel this narrow — it would
            // have to pin to an edge, which reads as the card jumping nearer on
            // one side and further on the other.
            let cellLeft = weekdayColumnWidth + gap + CGFloat(h.col) * (cell + gap)
            let cellTop = CGFloat(h.row) * (cell + gap) + headerHeight
            let rightX = cellLeft + cell + Self.cardGap
            let fitsRight = rightX + Self.cardWidth <= container.width
            let x = fitsRight ? rightX
                              : max(0, cellLeft - Self.cardGap - Self.cardWidth)
            dayDetail(h.day)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: Self.cardWidth, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.24), radius: 9, y: 3)
                .offset(x: x, y: cellTop)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// How many week columns fit without clipping. Sizing to the container
    /// beats a horizontal ScrollView here: the panel is a fixed width, and a
    /// scroll view clipped the last column mid-square.
    private func fittingWeeks(width: CGFloat) -> Int {
        let usable = width - weekdayColumnWidth - gap
        guard usable > 0 else { return 1 }
        return max(1, min(52, Int((usable + gap) / (cell + gap))))
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(String(localized: "Activity", bundle: L10n.bundle))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let busiest {
                Text(String(format: String(localized: "busiest %@ · $%.0f", bundle: L10n.bundle),
                            shortDate(busiest.date), busiest.totalCost))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static let space = "heatmapGrid"
    private static let cardWidth: CGFloat = 150
    /// Same distance from the square on either side, so scanning left to right
    /// does not feel like the card jumps nearer and further.
    private static let cardGap: CGFloat = 10
    private let weekdayColumnWidth: CGFloat = 16
    /// Header row plus its spacing, so a card lines up with its square.
    private let headerHeight: CGFloat = 23

    /// Date, spend, and the model split for the square under the pointer.
    @ViewBuilder
    private func dayDetail(_ d: Day) -> some View {
        let entry = dailyCosts.first { $0.date == d.date }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(d.date)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                Spacer(minLength: 4)
                Text(d.cost > 0 ? String(format: "$%.2f", d.cost)
                                : String(localized: "no activity", bundle: L10n.bundle))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(d.cost > 0 ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.tertiary))
            }
            if let entry, d.cost > 0 {
                Divider().opacity(0.4)
                ForEach(entry.modelBreakdown.filter { $0.value > 0 }
                            .sorted { $0.value > $1.value }.prefix(3), id: \.key) { name, cost in
                    HStack(spacing: 5) {
                        Circle().fill(Self.modelColor(name)).frame(width: 5, height: 5)
                        Text(name).font(.system(size: 9.5))
                        Spacer(minLength: 4)
                        Text(String(format: "$%.2f", cost))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if entry.totalTokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "number").font(.system(size: 8))
                        Text(compactTokens(entry.totalTokens) + " tokens")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Same hues the activity panel uses for its model row.
    private static func modelColor(_ name: String) -> Color {
        switch name {
        case "Fable":  return .purple
        case "Opus":   return .orange
        case "Sonnet": return .blue
        case "Haiku":  return .green
        default:       return .secondary
        }
    }

    private func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? Self.weekdaySymbols[row] : " ")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(height: cell)
            }
        }
        .frame(width: 16)
    }

    private func grid(weeks visible: Int) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(columns(weeks: visible).enumerated()), id: \.offset) { col, week in
                VStack(spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { row, day in
                        cellView(day, col: col, row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ day: Day?, col: Int, row: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(color(for: day))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color.primary.opacity(hovered?.day.date == day?.date ? 0.55 : 0),
                                  lineWidth: 1)
            )
            .onHover { inside in
                guard let day else { return }
                if inside {
                    hovered = (day, col, row)
                } else if hovered?.day.date == day.date {
                    hovered = nil
                }
            }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(String(localized: "less", bundle: L10n.bundle))
                .font(.system(size: 8)).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(shade(level))
                    .frame(width: 9, height: 9)
            }
            Text(String(localized: "more", bundle: L10n.bundle))
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data

    private struct Day {
        let date: String
        let cost: Double
    }

    private static let weekdaySymbols = ["", "M", "", "W", "", "F", ""]

    private var byDate: [String: Double] {
        Dictionary(dailyCosts.map { ($0.date, $0.totalCost) }, uniquingKeysWith: +)
    }

    /// Columns of 7, oldest first, ending on today. Leading blanks keep the
    /// weekday rows aligned the way a calendar reads.
    private func columns(weeks: Int) -> [[Day?]] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: Date())
        let totalDays = weeks * 7
        guard let start = cal.date(byAdding: .day, value: -(totalDays - 1), to: today) else { return [] }

        // Pad so the first column begins on Sunday.
        let leading = cal.component(.weekday, from: start) - 1
        var cells: [Day?] = Array(repeating: nil, count: leading)
        let table = byDate
        for offset in 0..<totalDays {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let key = fmt.string(from: d)
            cells.append(Day(date: key, cost: table[key] ?? 0))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// Rank-based thresholds: with spend this skewed, linear bucketing would put
    /// nearly every day in the lightest shade.
    private var thresholds: [Double] {
        let values = byDate.values.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [0, 0, 0, 0] }
        func q(_ p: Double) -> Double {
            let i = min(values.count - 1, max(0, Int(Double(values.count - 1) * p)))
            return values[i]
        }
        return [q(0.25), q(0.5), q(0.75), q(0.9)]
    }

    private var busiest: DailyCost? {
        dailyCosts.max { $0.totalCost < $1.totalCost }
    }

    private func color(for day: Day?) -> Color {
        guard let day, day.cost > 0 else { return Color.secondary.opacity(0.12) }
        let t = thresholds
        let level: Int
        switch day.cost {
        case ..<t[0]: level = 1
        case ..<t[1]: level = 2
        case ..<t[2]: level = 3
        case ..<t[3]: level = 4
        default:      level = 5
        }
        return shade(level)
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0:  return Color.secondary.opacity(0.12)
        case 1:  return Color.accentColor.opacity(0.25)
        case 2:  return Color.accentColor.opacity(0.45)
        case 3:  return Color.accentColor.opacity(0.65)
        case 4:  return Color.accentColor.opacity(0.82)
        default: return Color.accentColor
        }
    }

    private func tooltip(_ day: Day) -> String {
        day.cost > 0
            ? String(format: "%@ · $%.2f", day.date, day.cost)
            : String(format: String(localized: "%@ · no activity", bundle: L10n.bundle), day.date)
    }

    private func shortDate(_ s: String) -> String {
        s.count >= 10 ? String(s.dropFirst(5)) : s
    }
}
