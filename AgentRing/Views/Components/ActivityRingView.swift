//
//  ActivityRingView.swift
//  Agent Ring
//

import SwiftUI

/// Apple Watch 风格双环：按设置展示剩余或已用进度；未填充区间以半透明底轨补全成整圆。
/// 中心不放百分比——明细行已展示数值，圆环只做纯视觉仪表。
struct ActivityRingView: View {
    let outerPercentage: Double
    let innerPercentage: Double?
    let outerColor: Color
    let innerColor: Color
    let isRefreshing: Bool
    let showRemainingMode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var diameter: CGFloat = 88
    /// 较轻的线宽让用量文字成为主要阅读信息。
    var lineWidth: CGFloat = 9
    /// 内外环之间的间隙：同心几何（规范第 10 节），双环留出呼吸感
    private let ringSpacing: CGFloat = 5

    private var innerDiameter: CGFloat {
        diameter - (lineWidth + ringSpacing) * 2
    }

    var body: some View {
        ZStack {
            ring(
                diameter: diameter,
                percentage: outerPercentage,
                color: outerColor
            )

            if let innerPercentage {
                ring(
                    diameter: innerDiameter,
                    percentage: innerPercentage,
                    color: innerColor
                )
            }

            if isRefreshing {
                if reduceMotion {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L.Usage.loading)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L.Usage.loading)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private let usedPortionOpacity: Double = 0.08

    @ViewBuilder
    private func ring(diameter: CGFloat, percentage: Double, color: Color) -> some View {
        let range = UsageRingDisplay.displayedTrimRange(
            usedPercentage: percentage,
            showRemainingMode: showRemainingMode
        )
        let trackRange = UsageRingDisplay.trackTrimRange(
            usedPercentage: percentage,
            showRemainingMode: showRemainingMode
        )

        Group {
            if let trackRange, abs(trackRange.to - trackRange.from) >= 0.002 {
                ringStroke(
                    diameter: diameter,
                    range: trackRange,
                    color: color.opacity(contrast == .increased ? 0.25 : usedPortionOpacity)
                )
            }

            if abs(range.to - range.from) >= 0.002 {
                ringStroke(diameter: diameter, range: range, color: color)
            } else {
                // 弧长为 0 时不要整个消失：在 12 点位置留一个环色小点，
                // 用 round 线帽的极小弧段画出，天然继承环色与动画
                ringStroke(
                    diameter: diameter,
                    range: UsageRingTrimRange(from: 0, to: 0.002),
                    color: color
                )
            }
        }
    }

    private func ringStroke(diameter: CGFloat, range: UsageRingTrimRange, color: Color) -> some View {
        Circle()
            .trim(from: range.from, to: range.to)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(-90))
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1),
                value: range
            )
    }

}
