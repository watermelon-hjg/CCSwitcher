import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    // Observed on the shared instance rather than pulled from the environment:
    // this view is also built by StatusItemController, outside the SwiftUI
    // hierarchy that injects environment objects.
    @ObservedObject private var remoteHosts = RemoteHostsManager.shared
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var showingAddConfirm = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""
    /// Which dev box's account picker is open, if any.
    @State private var switchTarget: RemoteHost?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if appState.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.accounts) { account in
                            accountRow(account)
                        }
                    }
                    devBoxSection
                }
                .padding(16)
            }

            addAccountButtons
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Dev boxes

    /// Which account each dev box is currently running on. This belongs here
    /// rather than in the menu bar: it is a "who is on what" question you ask
    /// occasionally, not a number worth permanent space up top.
    @ViewBuilder
    private var devBoxSection: some View {
        let hosts = remoteHosts.hosts.filter(\.enabled)
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Dev boxes", bundle: L10n.bundle))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if remoteHosts.merged.diverged {
                        Text(String(localized: "accounts differ", bundle: L10n.bundle))
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }

                VStack(spacing: 6) {
                    ForEach(hosts) { host in
                        devBoxRow(host)
                    }
                }
            }
        }
    }

    /// One dev box: status, name, and the account it runs on as a popup menu.
    /// The account reads as a tappable chip rather than plain text, so the
    /// switch affordance is visible without hovering.
    @ViewBuilder
    private func devBoxRow(_ host: RemoteHost) -> some View {
        let state = remoteHosts.states[host.id]
        let switching = remoteHosts.isSwitching.contains(host.id)
        let profiles = state?.status?.profiles ?? []

        HStack(spacing: 9) {
            Circle()
                .fill(state?.isOnline == true ? Color.green
                      : (state?.error != nil ? Color.orange : Color.secondary.opacity(0.6)))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let w = state?.activeProfile?.windows?.first(where: { $0.isScoped }) {
                    Text("\(w.compactLabel) \(Int(w.utilizationPct))%")
                        .font(.system(size: 9))
                        .foregroundStyle(w.utilizationPct >= 100 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
            }

            Spacer(minLength: 6)

            if switching {
                ProgressView().controlSize(.small)
            } else if let p = state?.activeProfile {
                // A plain Button, not a Menu: macOS menu styles replace the
                // label with their own rendering (and add a leading chevron),
                // which drops the chip styling entirely.
                Button {
                    switchTarget = (switchTarget?.id == host.id) ? nil : host
                } label: {
                    HStack(spacing: 5) {
                        Text(p.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let tier = p.tier {
                            Text(tier)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.22), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4.5)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { switchTarget?.id == host.id },
                    set: { if !$0 { switchTarget = nil } }
                ), arrowEdge: .bottom) {
                    profilePicker(host: host, current: p, profiles: profiles)
                }
            } else {
                Text(state?.error?.localizedText
                     ?? String(localized: "connecting…", bundle: L10n.bundle))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The account list for one dev box, shown in a popover so it can be
    /// styled like the rest of the panel rather than as a system menu.
    @ViewBuilder
    private func profilePicker(host: RemoteHost, current: ClauthProfile,
                               profiles: [ClauthProfile]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)

            ForEach(profiles) { other in
                let isCurrent = other.name == current.name
                Button {
                    switchTarget = nil
                    guard !isCurrent else { return }
                    Task { await remoteHosts.switchProfile(hostID: host.id, to: other.name) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(other.name).font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            if let windows = other.windows, !windows.isEmpty {
                                Text(windows.map { "\($0.compactLabel) \(Int($0.utilizationPct))%" }
                                        .joined(separator: "  "))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 10)
                        if let t = other.tier {
                            Text(t)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.16), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
                .opacity(isCurrent ? 0.7 : 1)
            }
            Color.clear.frame(height: 6)
        }
        .frame(width: 250)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.textSecondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            // Provider icon
            Image(systemName: account.provider.iconName)
                .font(.title2)
                .foregroundStyle(account.isActive ? .brand : .secondary)
                .frame(width: 32, height: 32)

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                if editingAccountId == account.id {
                    HStack(spacing: 4) {
                        TextField("Custom label", text: $editingLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onSubmit { commitLabelEdit(account) }

                        Button {
                            commitLabelEdit(account)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingAccountId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.subheadline.weight(.medium))

                        Button {
                            editingLabel = account.customLabel ?? ""
                            editingAccountId = account.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit label")

                        if account.isActive {
                            Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .green)
                        }
                    }
                }

                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                HStack(spacing: 8) {
                    if let sub = account.displaySubscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                    }
                    Text(account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }

            Spacer()

            // Actions
            if !account.isActive {
                Button("Switch") {
                    Task { await appState.switchTo(account) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.brand)
            }

            Button {
                Task { await appState.reauthenticateAccount(account) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Re-authenticate (fix stale token)")

            Button {
                appState.removeAccount(account)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(account.isActive ? .cardFillStrong : .clear)
                .strokeBorder(.cardBorder, lineWidth: 1)
                .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
        )
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        editingAccountId = nil
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            // Logging in state
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 8) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation { showingAddConfirm = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Add Account") {
                        showingAddConfirm = false
                        Task { await appState.addAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else {
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                Button {
                    Task { await appState.loginNewAccount() }
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppStyle.buttonTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                // Secondary: Capture already-logged-in account
                Button {
                    withAnimation { showingAddConfirm = true }
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    colorScheme == .dark
                                        ? Color.gray.opacity(0.4)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
