//
//  WelcomeView.swift
//  Agent Ring
//

import SwiftUI

struct WelcomeView: View {
    @ObservedObject private var settings = UserSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            if let icon = ImageHelper.createAppIcon(size: 76) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .padding(.bottom, 12)
            } else {
                Image("CodexIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .padding(.bottom, 12)
            }

            Text(L.Welcome.title)
                .font(.system(size: 28, weight: .semibold))

            Text(L.Welcome.subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 42)

            VStack(alignment: .leading, spacing: 14) {
                welcomeRow(icon: "key.horizontal", title: L.Welcome.authenticationSetup, detail: L.WebLogin.browserLoginRecommended)
                welcomeRow(icon: "rectangle.3.group", title: L.DisplayOptions.title, detail: L.DisplayOptions.smartDisplayDescription)
                welcomeRow(icon: "bell.badge", title: L.SettingsNotification.section, detail: L.SettingsNotification.description)
            }
            .padding(.top, 24)
            .frame(maxWidth: 420)

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        WebLoginWindowManager.shared.showCodexLoginWindow()
                    } label: {
                        Label(L.Account.addCodexAccount, systemImage: settings.hasValidCodexCredentials ? "checkmark.circle.fill" : "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        WebLoginWindowManager.shared.showCursorLoginWindow()
                    } label: {
                        Label(L.Account.addCursorAccount, systemImage: settings.hasValidCursorCredentials ? "checkmark.circle.fill" : "cursorarrow.rays")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(L.provider("configure_platforms")) {
                    NotificationCenter.default.post(name: .openSettings, object: nil, userInfo: ["tab": 1])
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 28)

            Spacer(minLength: 20)

            HStack {
                Button(L.Welcome.laterButton) {
                    finishWelcome()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L.Welcome.finish) {
                    finishWelcome()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.hasAnyValidCredentials)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 520, height: 560)
    }

    private func welcomeRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finishWelcome() {
        settings.isFirstLaunch = false
        dismiss()
    }
}

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
    }
}
