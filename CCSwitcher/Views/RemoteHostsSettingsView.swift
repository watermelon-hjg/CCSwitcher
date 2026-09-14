import SwiftUI

/// Configure the clauth daemons running on the dev boxes.
///
/// A host is identified by IP and port; its bearer token comes from
/// `clauth daemon --print-token` on that machine. The certificate is
/// self-signed per container, so the first successful probe records a
/// fingerprint and every later connection must match it — a rebuilt container
/// re-signs legitimately and asks for one confirmation rather than being
/// trusted silently.
struct RemoteHostsSettingsView: View {
    @ObservedObject private var remoteHosts = RemoteHostsManager.shared
    @State private var editing: RemoteHost?
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if remoteHosts.hosts.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(remoteHosts.hosts) { host in
                        HostRow(host: host)
                        if host.id != remoteHosts.hosts.last?.id { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Label(String(localized: "Add dev box", bundle: L10n.bundle), systemImage: "plus")
                }
                Spacer()
                Button(String(localized: "Refresh now", bundle: L10n.bundle)) {
                    remoteHosts.refreshNow()
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            HostEditorSheet(host: nil)
                .environmentObject(remoteHosts)
        }
        .sheet(item: $editing) { host in
            HostEditorSheet(host: host)
                .environmentObject(remoteHosts)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "Dev boxes (clauth)", bundle: L10n.bundle))
                .font(.headline)
            Text(String(localized: "Usage from remote clauth daemons, merged into one reading. Switch accounts on any box from here.", bundle: L10n.bundle))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text(String(localized: "No dev boxes configured.", bundle: L10n.bundle))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Row

    @ViewBuilder
    private func HostRow(host: RemoteHost) -> some View {
        let state = remoteHosts.states[host.id]
        VStack(alignment: .leading, spacing: 9) {
            // Title line: status dot, name, address, and the row's actions,
            // which stay quiet until the row is hovered.
            HStack(spacing: 9) {
                StatusDot(color: statusColor(state), pulsing: remoteHosts.isSwitching.contains(host.id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: "\(host.host):\(String(host.port))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if remoteHosts.isSwitching.contains(host.id) {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button(String(localized: "Edit", bundle: L10n.bundle)) { editing = host }
                    Divider()
                    Button(String(localized: "Remove", bundle: L10n.bundle), role: .destructive) {
                        remoteHosts.removeHost(host.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if let err = state?.error {
                ErrorBanner(error: err, hostID: host.id)
            }

            if let profiles = state?.status?.profiles, !profiles.isEmpty {
                VStack(spacing: 5) {
                    ForEach(profiles) { p in ProfileRow(host: host, profile: p) }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    /// One account on one box: which it is, its tier, and its window meters.
    @ViewBuilder
    private func ProfileRow(host: RemoteHost, profile p: ClauthProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: p.active ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(p.active ? Color.accentColor : Color.secondary.opacity(0.5))

            Text(p.name)
                .font(.system(size: 12, weight: p.active ? .semibold : .regular))
                .frame(minWidth: 52, alignment: .leading)

            if let tier = p.tier {
                Text(tier)
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.16), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            // Meters rather than bare percentages: a number alone does not show
            // how close to the cap it sits.
            HStack(spacing: 7) {
                ForEach(p.windows ?? []) { w in WindowMeter(window: w) }
            }
            .opacity(p.isStale ? 0.45 : 1)

            if p.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(String(localized: "Reading may be out of date", bundle: L10n.bundle))
            }

            Spacer(minLength: 4)

            if !p.active {
                Button {
                    Task { await remoteHosts.switchProfile(hostID: host.id, to: p.name) }
                } label: {
                    Text(String(localized: "Switch", bundle: L10n.bundle))
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(remoteHosts.isSwitching.contains(host.id))
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func ErrorBanner(error: RemoteError, hostID: UUID) -> some View {
        HStack(spacing: 7) {
            Image(systemName: error.isCertificateMismatch
                  ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.localizedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let next = remoteHosts.states[hostID]?.nextRetryAt,
                   !error.isCertificateMismatch {
                    Text(retryText(next: next,
                                   count: remoteHosts.states[hostID]?.failureCount ?? 0))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if error.isCertificateMismatch {
                Button(String(localized: "Trust new certificate", bundle: L10n.bundle)) {
                    Task { await remoteHosts.trustCurrentCertificate(for: hostID) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// "retrying in 30s (attempt 3)" — makes an offline box look like it is
    /// being retried rather than stuck.
    private func retryText(next: Date, count: Int) -> String {
        let secs = max(0, Int(next.timeIntervalSinceNow))
        return String(format: String(localized: "retrying in %ds · attempt %d", bundle: L10n.bundle),
                      secs, count)
    }

    private func statusColor(_ state: RemoteHostState?) -> Color {
        guard let state else { return .secondary }
        if state.error != nil { return .orange }
        return state.isOnline ? .green : .secondary
    }
}

// MARK: - Editor

/// Placeholder values for the editor's fields.
///
/// Generic by default, but overridable per machine:
///
///     defaults write me.xueshi.ccswitcher devBoxExampleAlias my-box
///     defaults write me.xueshi.ccswitcher devBoxExampleHost  10.1.2.3
///
/// The placeholder is also what Tab adopts, so it is most useful when it is the
/// reader's own dev box — which is exactly the value that should not be baked
/// into source that gets published.
private enum Example {
    static var alias: String {
        UserDefaults.standard.string(forKey: "devBoxExampleAlias") ?? "my-dev-box"
    }
    static var address: String {
        UserDefaults.standard.string(forKey: "devBoxExampleHost") ?? "10.0.0.12"
    }
}

private struct HostEditorSheet: View {
    @ObservedObject private var remoteHosts = RemoteHostsManager.shared
    @Environment(\.dismiss) private var dismiss

    let host: RemoteHost?

    @State private var name = ""
    @State private var address = ""
    @State private var port = "8443"
    @State private var token = ""
    @State private var probedFingerprint: String?
    @State private var probing = false
    @State private var probeFailed = false
    @State private var useTunnel = false
    @State private var alias = ""
    @State private var detecting = false
    @State private var detectNote: (text: String, bad: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(host == nil
                 ? String(localized: "Add dev box", bundle: L10n.bundle)
                 : String(localized: "Edit dev box", bundle: L10n.bundle))
                .font(.headline)

            detectCard

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                LabeledField(String(localized: "Name", bundle: L10n.bundle),
                             example: Example.alias, text: $name) {
                    TextField("", text: $name, prompt: Text(verbatim: Example.alias))
                }
                LabeledField(String(localized: "Host", bundle: L10n.bundle),
                             example: Example.address, text: $address) {
                    TextField("", text: $address, prompt: Text(verbatim: Example.address))
                }
                LabeledField(String(localized: "Port", bundle: L10n.bundle),
                             example: "8443", text: $port) {
                    TextField("", text: $port, prompt: Text(verbatim: "8443"))
                }
                LabeledField(String(localized: "Bearer token", bundle: L10n.bundle)) {
                    SecureField("", text: $token,
                                prompt: Text(verbatim: "clauth daemon --print-token"))
                }
            }
            .textFieldStyle(.roundedBorder)

            tunnelRow

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Button {
                        probe()
                    } label: {
                        Text(String(localized: "Check certificate", bundle: L10n.bundle))
                    }
                    .disabled(address.isEmpty)
                    if probing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let fp = probedFingerprint {
                    Text(String(localized: "Certificate fingerprint (SHA-256)", bundle: L10n.bundle))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(spaced(fp))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if probeFailed {
                    Text(String(localized: "Could not read a certificate — check host, port and network.", bundle: L10n.bundle))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            // Name what is still missing, so a disabled Save is never a mystery.
            if let missing = missingFieldsText {
                Text(missing).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: L10n.bundle)) { dismiss() }
                Button(String(localized: "Save", bundle: L10n.bundle)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(missingFieldsText != nil)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: prefill)
    }

    /// Read address, token and certificate off the box over SSH.
    private func detect() {
        let target = alias.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        detecting = true
        detectNote = nil
        Task {
            do {
                let found = try await RemoteHostDetector.detect(alias: target)
                await MainActor.run {
                    if name.isEmpty { name = found.alias }
                    address = found.address
                    port = "8443"
                    token = found.token
                    probedFingerprint = found.fingerprint
                    probeFailed = false
                    useTunnel = found.needsTunnel
                    detectNote = (found.needsTunnel
                        ? String(format: String(localized: "Found %@ — not reachable directly, so it will use an SSH tunnel.", bundle: L10n.bundle), found.address)
                        : String(format: String(localized: "Found %@ — reachable directly.", bundle: L10n.bundle), found.address),
                        false)
                    // Something else answering that address is worth saying out
                    // loud: it is how a port collision or a stale forward looks.
                    if found.impostor != nil {
                        detectNote = (String(localized: "That address answers with a different certificate than the box's own daemon. Using a tunnel instead.", bundle: L10n.bundle), true)
                        useTunnel = true
                    }
                    detecting = false
                }
            } catch {
                await MainActor.run {
                    detectNote = (error.localizedDescription, true)
                    detecting = false
                }
            }
        }
    }

    /// The fast path, set apart from the manual fields: one alias is enough to
    /// read the address, token and certificate off the box itself.
    private var detectCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(String(localized: "Fill in from an SSH alias", bundle: L10n.bundle))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                LabeledField(String(localized: "SSH alias", bundle: L10n.bundle),
                             example: Example.alias, text: $alias) {
                    TextField("", text: $alias, prompt: Text(verbatim: Example.alias))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { detect() }
                }
                Button {
                    detect()
                } label: {
                    HStack(spacing: 5) {
                        if detecting {
                            ProgressView().controlSize(.small)
                        }
                        Text(String(localized: "Detect", bundle: L10n.bundle))
                    }
                    .frame(minWidth: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty || detecting)
            }

            detectNoteRow
        }
        .padding(11)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
    }

    /// Result of the last detection, or what it will do before you run one.
    @ViewBuilder
    private var detectNoteRow: some View {
        let note = detectNote
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: note == nil ? "info.circle"
                                          : (note!.bad ? "exclamationmark.triangle.fill"
                                                       : "checkmark.circle.fill"))
                .font(.system(size: 10))
                .foregroundStyle(note == nil ? AnyShapeStyle(.tertiary)
                                             : (note!.bad ? AnyShapeStyle(Color.orange)
                                                          : AnyShapeStyle(Color.green)))
            Text(note?.text ?? String(localized: "Reads the address, token and certificate over SSH, and works out whether a tunnel is needed.", bundle: L10n.bundle))
                .font(.caption)
                .foregroundStyle(note?.bad == true ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Tunnel switch. The local port is only meaningful for a host that already
    /// exists — for a new one it is assigned when the record is saved.
    private var tunnelRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $useTunnel) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Connect over an SSH tunnel", bundle: L10n.bundle))
                }
            }
            Text(host == nil
                 ? String(localized: "For boxes whose ports are blocked from this Mac. CCSwitcher keeps an `ssh -L` forward open through the alias above.", bundle: L10n.bundle)
                 : String(format: String(localized: "Forwarded through the alias above to this Mac's 127.0.0.1:%d.", bundle: L10n.bundle), tunnelPort))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 21)
        }
    }

    private func prefill() {
        guard let host else { return }
        name = host.name
        address = host.host
        port = String(host.port)
        probedFingerprint = host.pinnedFingerprint
        useTunnel = host.useSSHTunnel
        alias = host.effectiveSSHAlias
    }

    /// Shown in the hint so the toggle says exactly which port it will use.
    private var tunnelPort: Int {
        SSHTunnelManager.localPort(for: host ?? RemoteHost(name: name, host: address,
                                                           port: Int(port) ?? 8443,
                                                           useSSHTunnel: true))
    }

    private var missingFieldsText: String? {
        var missing: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append(String(localized: "Name", bundle: L10n.bundle))
        }
        if address.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append(String(localized: "Host", bundle: L10n.bundle))
        }
        if host == nil, token.isEmpty {
            missing.append(String(localized: "Bearer token", bundle: L10n.bundle))
        }
        guard !missing.isEmpty else { return nil }
        return String(format: String(localized: "Still needed: %@", bundle: L10n.bundle),
                      missing.joined(separator: ", "))
    }

    private func probe() {
        probing = true
        probeFailed = false
        var candidate = RemoteHost(name: name, host: address, port: Int(port) ?? 8443,
                                   sshAlias: name.isEmpty ? nil : name,
                                   useSSHTunnel: useTunnel)
        candidate.id = host?.id ?? candidate.id   // keep the derived local port stable
        if useTunnel { SSHTunnelManager.shared.ensureRunning(for: candidate) }
        Task {
            let fp = await RemoteClauthService.probeFingerprint(host: candidate)
            await MainActor.run {
                probedFingerprint = fp
                probeFailed = (fp == nil)
                probing = false
            }
        }
    }

    private func save() {
        let p = Int(port) ?? 8443
        if var existing = host {
            existing.name = name
            existing.host = address
            existing.port = p
            existing.useSSHTunnel = useTunnel
            existing.sshAlias = alias.isEmpty ? nil : alias
            if let probedFingerprint { existing.pinnedFingerprint = probedFingerprint }
            remoteHosts.updateHost(existing, token: token.isEmpty ? nil : token)
        } else {
            let new = RemoteHost(name: name, host: address, port: p,
                                 pinnedFingerprint: probedFingerprint,
                                 sshAlias: alias.isEmpty ? nil : alias,
                                 useSSHTunnel: useTunnel)
            remoteHosts.addHost(new, token: token)
        }
        dismiss()
    }

    /// Group hex into pairs so a fingerprint can be eyeballed against
    /// `openssl x509 -fingerprint -sha256` output.
    private func spaced(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: min(2, hex.count - i))
            return String(hex[s..<e])
        }.joined(separator: ":")
    }
}

/// Label above field, so long localized labels never squeeze the input.
///
/// When an `example` is supplied and the field is still empty, a small
/// "Use example" link fills it in — the placeholder shows a real, usable value
/// and there is a one-click way to take it, rather than making the reader
/// retype what they can already see.
private struct LabeledField<Content: View>: View {
    let label: String
    var example: String?
    var text: Binding<String>?
    @ViewBuilder let content: Content

    @FocusState private var focused: Bool

    init(_ label: String,
         example: String? = nil,
         text: Binding<String>? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.example = example
        self.text = text
        self.content = content()
    }

    private var isEmpty: Bool {
        (text?.wrappedValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if focused, isEmpty, example != nil {
                    // Only while the caret is here and the field is untouched:
                    // Tab takes the placeholder instead of skipping past it.
                    Text(String(localized: "Tab to use example", bundle: L10n.bundle))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            content
                .focused($focused)
                .onChange(of: focused) { _, nowFocused in
                    // Leaving an untouched field adopts the example, which is
                    // what Tab does: move on, keeping what was shown.
                    if !nowFocused, isEmpty, let example, let text {
                        text.wrappedValue = example
                    }
                }
        }
    }
}

// MARK: - Small components

/// Connection indicator. Pulses while a switch is in flight so a slow switch
/// (the daemon can legitimately take tens of seconds) still looks alive.
private struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 3)
                    .scaleEffect(on ? 1.9 : 1)
                    .opacity(on ? 0 : 1)
            )
            .onAppear { if pulsing { animate() } }
            .onChange(of: pulsing) { _, now in if now { animate() } else { on = false } }
    }

    private func animate() {
        guard !UIAccessibilityReduceMotion else { on = false; return }
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true }
    }

    /// `accessibilityReduceMotion` is not exposed to non-View code here, so read
    /// the system setting directly rather than animating over the user's wish.
    private var UIAccessibilityReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// A window's utilization as a label plus a short meter, so "how close to the
/// cap" reads at a glance instead of having to compare bare percentages.
private struct WindowMeter: View {
    let window: ClauthWindow

    private var fraction: Double { min(max(window.utilizationPct / 100, 0), 1) }

    private var tint: Color {
        switch window.utilizationPct {
        case ..<60:  return .green
        case ..<85:  return .yellow
        case ..<100: return .orange
        default:     return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(window.compactLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("\(Int(window.utilizationPct))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Capsule()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 42, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: 42 * fraction, height: 3)
                }
        }
        .help(resetHelp)
    }

    private var resetHelp: String {
        guard let r = window.resetsAt else { return window.label }
        return "\(window.label) · \(String(localized: "resets", bundle: L10n.bundle)) \(r.prefix(16))"
    }
}
