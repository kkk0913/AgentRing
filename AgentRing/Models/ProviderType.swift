//
//  ProviderType.swift
//  Agent Ring
//

import Foundation

enum ProviderType: String, Codable, CaseIterable, Hashable {
    case codex
    case cursor
    case antigravity
    case antigravityThird = "antigravity_third"

    case kimi
    case glm

    static let configurable: [ProviderType] = [.codex, .cursor, .antigravity, .kimi, .glm]

    var displayName: String {
        switch self {
        case .kimi: return "Kimi Code"
        case .glm: return "GLM"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .antigravityThird: return "Antigravity Third"
        }
    }
}

