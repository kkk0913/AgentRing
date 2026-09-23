//
//  AuthSettingsView.swift
//  Agent Ring
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct AuthSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var selectedProvider: ProviderType = .codex
    @State private var isShowingToken = false
    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Account?
    @State private var antigravityCredentialsPresent = false
    @State private var isRecheckingAntigravity = false
    @State private var showDiagnostics = false
    /// Codex 复选模式下展开详情的账号
    @State private var expandedAccountId: UUID?
    @State private var draggedAccount: Account?
    @State private var dropTargetAccountId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.provider("platforms")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(ProviderType.configurable, id: \.self) { provider in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { settings.isProviderEnabled(provider) },
                            set: { settings.setProviderEnabled(provider, enabled: $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel(L.provider("monitor") + " " + provider.displayName)
                        Button { selectedProvider = provider } label: {
                            Text(provider.displayName).font(.system(size: 12, weight: selectedProvider == provider ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .background(selectedProvider == provider ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                Text(L.provider("selection_hint")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                Spacer(minLength: 0)
            }.frame(width: 142).padding(.top, 20).padding(.horizontal, 12)
            Divider()
            SettingsPaneScroll {
            VStack(alignment: .leading, spacing: 16) {

                Group {
                    switch selectedProvider {
                    case .codex:
                        providerAccountsCard(
                            accounts: settings.codexAccounts,
                            multiSelect: true,
                            title: L.Account.codexAccounts,
                            addTitle: L.Account.addCodexAccount,
                            tokenLabel: "Codex Token",
                            onSelect: nil,
                            isSelected: { _ in false },
                            isEnabled: { settings.isCodexAccountEnabled($0.id) },
                            isExpanded: { expandedAccountId == $0.id },
                            onRowClick: { account in
                                isShowingToken = false
                                expandedAccountId = expandedAccountId == account.id ? nil : account.id
                            },
                            onToggle: { settings.setCodexAccountEnabled($0, enabled: $1) },
                            onMove: { settings.moveCodexAccounts(from: $0, to: $1) },
                            onAdd: { WebLoginWindowManager.shared.showCodexLoginWindow() },
                            onUpdateAlias: { settings.updateCodexAccount($0, alias: $1) }
                        )
                    case .cursor:
                        providerAccountsCard(
                            accounts: settings.cursorAccounts,
                            multiSelect: true,
                            title: L.Account.cursorAccounts,
                            addTitle: L.Account.addCursorAccount,
                            tokenLabel: "Cursor Session",
                            onSelect: nil,
                            isSelected: { _ in false },
                            isEnabled: { !settings.disabledCursorAccountIds.contains($0.id) },
                            isExpanded: { expandedAccountId == $0.id },
                            onRowClick: { account in isShowingToken = false; expandedAccountId = expandedAccountId == account.id ? nil : account.id },
                            onToggle: { settings.setCursorAccountEnabled($0, enabled: $1) },
                            onMove: { settings.moveCursorAccounts(from: $0, to: $1) },
                            onAdd: { WebLoginWindowManager.shared.showCursorLoginWindow() },
                            onUpdateAlias: { settings.updateCursorAccount($0, alias: $1) }
                        )
                    case .kimi, .glm:
                        PlanQuotaSettingsView(provider: selectedProvider).id(selectedProvider)
                    case .antigravity, .antigravityThird:
                        antigravityCard
                    }
                }

                if selectedProvider != .kimi && selectedProvider != .glm { diagnosticsDisclosure }
            }
        }
        }
        .alert(L.Account.deleteConfirmTitle, isPresented: $showDeleteConfirmation) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.Account.delete, role: .destructive) {
                if let accountToDelete {
                    if accountToDelete.provider == .cursor {
                        settings.removeCursorAccount(accountToDelete)

                    } else {
                        settings.removeCodexAccount(accountToDelete)
                    }
                }
            }
        } message: {
            Text(L.Account.deleteConfirmMessage)
        }
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            if draggedAccount != nil && NSEvent.pressedMouseButtons == 0 {
                draggedAccount = nil
                dropTargetAccountId = nil
            }
        }
        .onDisappear {
            draggedAccount = nil
            dropTargetAccountId = nil
            isShowingToken = false
        }
        .onAppear {
            refreshAntigravityCredentialStatus()
        }
        .onChange(of: settings.antigravityEnabled) { _ in
            refreshAntigravityCredentialStatus()
        }
        .onChange(of: selectedProvider) { _ in
            isShowingToken = false
            expandedAccountId = nil
            draggedAccount = nil
            dropTargetAccountId = nil
        }
    }

    // MARK: - Provider accounts (Codex 复选多选 / Cursor 单选)

    private func providerAccountsCard(
        accounts: [Account],
        multiSelect: Bool,
        title: String,
        addTitle: String,
        tokenLabel: String,
        onSelect: ((Account) -> Void)?,
        isSelected: @escaping (Account) -> Bool,
        isEnabled: @escaping (Account) -> Bool,
        isExpanded: @escaping (Account) -> Bool,
        onRowClick: @escaping (Account) -> Void,
        onToggle: ((Account, Bool) -> Void)?,
        onMove: ((IndexSet, Int) -> Void)?,
        onAdd: @escaping () -> Void,
        onUpdateAlias: @escaping (Account, String?) -> Void
    ) -> some View {
        SettingCard(
            icon: "person.crop.circle",
            iconColor: .secondary,
            title: title,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text(L.Account.noAccounts)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                if multiSelect, let onToggle {
                                    Toggle(
                                        L.Account.enableAccount,
                                        isOn: Binding(
                                            get: { isEnabled(account) },
                                            set: { onToggle(account, $0) }
                                        )
                                    )
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("\(L.Account.enableAccount): \(account.displayName)")
                                    .help(L.Account.enableAccount)
                                } else if let onSelect {
                                    AccountRadioButton(
                                        selected: isSelected(account),
                                        label: account.displayName,
                                        action: { onSelect(account) }
                                    )
                                    .frame(width: 18, height: 22)
                                }

                                Button {
                                    onRowClick(account)
                                } label: {
                                    HStack(spacing: 6) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(account.displayName)
                                                .font(.body)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                            if let alias = account.alias, !alias.isEmpty {
                                                Text(account.accountName)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if multiSelect {
                                            Image(systemName: "chevron.right")
                                                .rotationEffect(.degrees(isExpanded(account) ? 90 : 0))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(multiSelect ? L.Account.accountDetails : L.Account.selectAccount)

                                if multiSelect, let onMove, accounts.count > 1,
                                   let accountIndex = accounts.firstIndex(where: { $0.id == account.id }) {
                                    Menu {
                                        Button(L.Account.moveUp) {
                                            onMove(IndexSet(integer: accountIndex), accountIndex - 1)
                                        }
                                        .disabled(accountIndex == 0)
                                        Button(L.Account.moveDown) {
                                            onMove(IndexSet(integer: accountIndex), accountIndex + 2)
                                        }
                                        .disabled(accountIndex == accounts.count - 1)
                                    } label: {
                                        Image(systemName: "arrow.up.arrow.down")
                                            .frame(width: 24, height: 24)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .help(L.Account.reorder)
                                    .accessibilityLabel("\(L.Account.reorder): \(account.displayName)")

                                    Image(systemName: "line.3.horizontal")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                        .help(L.Usage.dragToReorder)
                                        .accessibilityLabel(L.Usage.dragToReorder)
                                        .onDrag {
                                            draggedAccount = account
                                            return NSItemProvider(object: account.id.uuidString as NSString)
                                        } preview: {
                                            Text(account.displayName)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                        }
                                }
                            }

                            if isExpanded(account) {
                                accountDetailInline(
                                    account: account,
                                    tokenLabel: tokenLabel,
                                    onUpdateAlias: { onUpdateAlias(account, $0) }
                                )
                            }
                        }
                        .frame(minHeight: 36)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .opacity(draggedAccount?.id == account.id ? 0.35 : 1.0)
                        .overlay {
                            if dropTargetAccountId == account.id,
                               let dragged = draggedAccount,
                               dragged.id != account.id,
                               let from = accounts.firstIndex(where: { $0.id == dragged.id }),
                               let to = accounts.firstIndex(where: { $0.id == account.id }) {
                                VStack(spacing: 0) {
                                    if to > from { Spacer(minLength: 0) }
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                        .padding(.horizontal, 8)
                                    if to < from { Spacer(minLength: 0) }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .onDrop(
                            of: [UTType.text.identifier],
                            delegate: AccountDropDelegate(
                                account: account,
                                accounts: accounts,
                                onMove: { onMove?($0, $1) },
                                draggedItem: $draggedAccount,
                                dropTargetAccountId: $dropTargetAccountId,
                                reduceMotion: reduceMotion
                            )
                        )

                        if account.id != accounts.last?.id {
                            Divider()
                        }
                    }
                }

                if multiSelect {
                    Text(L.Account.multiSelectHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onAdd) {
                    Label(addTitle, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
    }

    private func accountDetailInline(
        account: Account,
        tokenLabel: String,
        onUpdateAlias: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.Account.alias)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField(account.accountName, text: Binding(
                        get: { account.alias ?? "" },
                        set: { newValue in
                            onUpdateAlias(newValue.isEmpty ? nil : newValue)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    if let alias = account.alias, !alias.isEmpty {
                        Button {
                            onUpdateAlias(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L.Account.clearAlias)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(tokenLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    if isShowingToken {
                        Text(account.credentialToken)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(String(repeating: "•", count: min(account.credentialToken.count, 24)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        isShowingToken.toggle()
                    } label: {
                        Image(systemName: isShowingToken ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isShowingToken ? L.SettingsAuth.hidePassword : L.SettingsAuth.showPassword)
                    .accessibilityLabel(isShowingToken ? L.SettingsAuth.hidePassword : L.SettingsAuth.showPassword)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
            }

            Button(role: .destructive) {
                accountToDelete = account
                showDeleteConfirmation = true
            } label: {
                Label(L.Account.deleteAccount, systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.leading, 28)
        .padding(.vertical, 8)
    }

    // MARK: - Antigravity

    private var antigravityCard: some View {
        let statusText: String = {
            if !settings.antigravityEnabled {
                return L.Account.antigravityDisabled
            }
            if isRecheckingAntigravity {
                return L.Account.antigravityChecking
            }
            return antigravityCredentialsPresent ? L.Account.antigravityReady : L.Account.antigravityMissing
        }()
        let statusColor: Color = {
            if !settings.antigravityEnabled || isRecheckingAntigravity { return .secondary }
            return antigravityCredentialsPresent ? .green : .orange
        }()
        let statusIcon: String = {
            if !settings.antigravityEnabled { return "pause.circle" }
            if isRecheckingAntigravity { return "arrow.triangle.2.circlepath" }
            return antigravityCredentialsPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }()

        return SettingCard(
            icon: "sparkles",
            iconColor: .secondary,
            title: L.Account.antigravityTitle,
            hint: L.Account.antigravityHint
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $settings.antigravityEnabled) {
                    Text(L.Account.antigravityEnableMonitoring)
                        .font(.subheadline)
                }
                .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L.Account.antigravityRecheck) {
                        refreshAntigravityCredentialStatus(force: true)
                        NotificationCenter.default.post(
                            name: .accountChanged,
                            object: nil,
                            userInfo: [Notification.UserInfoKey.provider: ProviderType.antigravity.rawValue]
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!settings.antigravityEnabled || isRecheckingAntigravity)
                }

                Text(L.Account.antigravitySourceHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Diagnostics (collapsed)

    private var diagnosticsDisclosure: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            DiagnosticsView()
                .padding(.top, 8)
        } label: {
            Label(L.Diagnostic.sectionTitle, systemImage: "stethoscope")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Helpers

    private func refreshAntigravityCredentialStatus(force: Bool = true) {
        isRecheckingAntigravity = true
        DispatchQueue.global(qos: .userInitiated).async {
            if force {
                AntigravityAPIService.invalidateCredentialsCache()
            }
            let present = AntigravityAPIService.credentialsAvailable(forceRefresh: force)
            DispatchQueue.main.async {
                antigravityCredentialsPresent = present
                isRecheckingAntigravity = false
            }
        }
    }
}

/// 账号行拖拽排序（Codex 复选模式）：落下时把源账号移动到目标位。
private struct AccountDropDelegate: DropDelegate {
    let account: Account
    let accounts: [Account]
    let onMove: (IndexSet, Int) -> Void
    @Binding var draggedItem: Account?
    @Binding var dropTargetAccountId: UUID?
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard draggedItem?.id != account.id else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1)) {
            dropTargetAccountId = account.id
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetAccountId == account.id {
            dropTargetAccountId = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedItem = nil
            dropTargetAccountId = nil
        }
        guard let dragged = draggedItem,
              dragged.id != account.id,
              let from = accounts.firstIndex(where: { $0.id == dragged.id }),
              let to = accounts.firstIndex(where: { $0.id == account.id }) else {
            return false
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
            onMove(IndexSet(integer: from), to > from ? to + 1 : to)
        }
        return true
    }
}

/// Native AppKit radio semantics for Cursor's mutually exclusive account selection.
private struct AccountRadioButton: NSViewRepresentable {
    let selected: Bool
    let label: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(radioButtonWithTitle: "", target: context.coordinator, action: #selector(Coordinator.select))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = selected ? .on : .off
        button.setAccessibilityLabel(label)
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func select() { action?() }
    }
}
