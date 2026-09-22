//
//  CodexAccountUsage.swift
//  Agent Ring
//

import Foundation

/// 单个 Codex 账号的用量与状态（多账号同显的数据单元）。
struct CodexAccountUsage: Identifiable {
    let accountId: UUID
    var displayName: String
    var usage: CodexUsageData?
    var needsRelogin: Bool = false
    var errorMessage: String?

    var id: UUID { accountId }
}
