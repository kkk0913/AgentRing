import SwiftUI

struct PlanQuotaSettingsView: View {
    let provider: ProviderType
    @ObservedObject private var settings = UserSettings.shared
    @State private var secret = ""
    @State private var region = "cn"
    @State private var busy = false
    @State private var message: String?
    @State private var success = false
    @State private var service: PlanQuotaService?
    @State private var requestID = UUID()
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingCard(icon: "key", title: provider.displayName,
                        hint: L.provider(provider == .kimi ? "kimi.hint" : "glm.hint")) {
                Picker(L.provider("region"), selection: $region) {
                    Text(L.provider(provider == .glm ? "region.cn" : "kimi.region.cn")).tag("cn")
                    Text(provider == .glm ? "Z.ai" : L.provider("kimi.region.global")).tag("global")
                }.pickerStyle(.menu).disabled(busy)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.provider(provider == .kimi ? "kimi.token" : "glm.token")).font(.caption).foregroundStyle(.secondary)
                    SecureField(L.provider("secret.placeholder"), text: $secret).textFieldStyle(.roundedBorder).disabled(busy)
                }
                HStack {
                    Button(L.provider("validate_enable")) { validateAndSave() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let message {
                    Label(message, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(success ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Link(L.provider(provider == .kimi ? "kimi.get_key" : "setup_guide"), destination: URL(string: provider == .kimi
                    ? (region == "cn" ? "https://www.kimi.com/code/console" : "https://www.kimi.ai/code/console")
                    : "https://github.com/zai-org/zai-coding-plugins/tree/main/plugins/glm-plan-usage")!)
                Spacer()
                if settings.planConfigurations[provider] != nil {
                    Button(L.provider("remove"), role: .destructive) { confirmRemoval = true }
                        .disabled(busy)
                }
            }.font(.caption)
            Text(L.provider("encrypted")).font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear {
            service = PlanQuotaService()
            if let config = settings.planConfigurations[provider] {
                region = config.region
                if provider == .kimi && config.credentialKind != "apiKey" {
                    secret = ""; message = L.provider("kimi.migration")
                } else { secret = config.secret }
            }
        }
        .onDisappear { requestID = UUID(); service?.close(); service = nil }
        .alert(L.provider("remove"), isPresented: $confirmRemoval) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.provider("remove"), role: .destructive) {
                busy = true
                settings.savePlanConfiguration(nil, provider: provider) { saved in
                    busy = false
                    if saved { secret = ""; message = nil; settings.setProviderEnabled(provider, enabled: false) }
                    else { success = false; message = L.provider("error.save") }
                }
            }
        } message: { Text(L.provider("remove_hint")) }
    }

    private func validateAndSave() {
        let configuration = PlanQuotaConfiguration(secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  region: region)
        busy = true; message = nil; success = false
        let id = UUID(); requestID = id
        if service == nil { service = PlanQuotaService() }
        service?.fetch(provider: provider, configuration: configuration) { result in
            guard id == requestID else { return }
            switch result {
            case .success:
                settings.savePlanConfiguration(configuration, provider: provider) { saved in
                    busy = false; success = saved
                    if saved {
                        settings.setProviderEnabled(provider, enabled: true)
                        message = L.provider("connected")
                    } else { message = L.provider("error.save") }
                }
            case .failure(let error): busy = false; message = error.localizedDescription
            }
        }
    }
}
