//
//  SettingsView.swift
//  Agent Ring
//

import SwiftUI

/// 设置视图
/// 侧边栏布局：左侧标签导航 + 右侧内容区，对齐 macOS 13+ 系统设置风格
struct SettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var selectedTab: Int?
    @StateObject private var localization = LocalizationManager.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 188)
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        SettingsSidebarMaterial()
                    }
                }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text((SidebarTab(rawValue: selectedTab ?? 0) ?? .general).title)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)

                Group {
                    switch selectedTab ?? 0 {
                    case 1: AuthSettingsView()
                    case 2: BluetoothSettingsView()
                    case 3: AboutView()
                    default: GeneralSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity)
        .frame(minHeight: 560, maxHeight: .infinity)
        .id(localization.updateTrigger)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let icon = ImageHelper.createAppIcon(size: 24) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .cornerRadius(6)
                }
                Text(L.App.name)
                    .font(.headline)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)

            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .padding(.vertical, 4)
                    .tag(tab.rawValue)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

/// 系统侧栏材质会跟随窗口激活状态与系统外观。
private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Sidebar Tab

private enum SidebarTab: Int, CaseIterable, Identifiable {
    case general = 0, auth = 1, bluetooth = 2, about = 3

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .auth: return "key.horizontal"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return L.SettingsTab.general
        case .auth: return L.SettingsTab.auth
        case .bluetooth: return L.SettingsTab.bluetooth
        case .about: return L.SettingsTab.about
        }
    }
}

/// Pins scroll content to the pane width so macOS radio/form controls
/// cannot inflate the hosting view and shove the sidebar off the window.
struct SettingsPaneScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 预览
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
