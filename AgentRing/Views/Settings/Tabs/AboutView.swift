//
//  AboutView.swift
//  Agent Ring
//

import SwiftUI

/// 关于页面
/// 显示应用信息、版本号与开源仓库
struct AboutView: View {
    @ObservedObject private var updateManager = AppUpdateManager.shared

    /// 从 Bundle 中读取应用版本号
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 应用图标
            if let icon = ImageHelper.createAppIcon(size: 96) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .cornerRadius(22)
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                    .padding(.bottom, 16)
            }
            
            // 应用名称和版本
            VStack(spacing: 6) {
                Text(L.App.name)
                    .font(.system(size: 20, weight: .bold))
                
                Text(L.SettingsAbout.version(appVersion))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 14)

            // 检查更新按钮
            Button(action: {
                updateManager.checkForUpdates(isUserInitiated: true)
            }) {
                if updateManager.isChecking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                        Text(L.SettingsUpdate.checking)
                    }
                } else {
                    Text(L.SettingsUpdate.checkNow)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(updateManager.isChecking || updateManager.isDownloading)
            .padding(.bottom, 24)
            
            Divider()
                .frame(maxWidth: 240)
                .padding(.bottom, 20)
            
            // 仓库地址链接
            Link(destination: URL(string: "https://github.com/kkk0913/AgentRing")!) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)

                    Text("kkk0913/AgentRing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.link)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
