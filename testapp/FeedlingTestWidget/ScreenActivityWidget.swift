import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Cinnabar design tokens (mirrored from main app)

private extension Color {
    static let cinBg         = Color(hex: "#f3eee2")
    static let cinFg         = Color(hex: "#1a1814")
    static let cinSub        = Color(hex: "#7a7065")
    static let cinLine       = Color(hex: "#d6cfc0")
    static let cinAccent1    = Color(hex: "#b8442e")
    static let cinAccent1Soft = Color(hex: "#f0e8df")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >> 8)  & 0xff) / 255
        let b = Double(int         & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private extension Font {
    static func cinMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .medium ? "DMMono-Medium" : "DMMono-Regular"
        return .custom(name, size: size)
    }
    static func cinSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .medium ? "NotoSerifSC-Medium" : "NotoSerifSC-Regular"
        return .custom(name, size: size)
    }
    static func cinNewsreader(_ size: CGFloat, italic: Bool = false) -> Font {
        let name = italic
            ? "Newsreader-Italic-VariableFont_opsz,wght"
            : "Newsreader-VariableFont_opsz,wght"
        return .custom(name, size: size)
    }
}

// MARK: - Widget

struct ScreenActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScreenActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — match the lock screen Live Activity visual
                // (cinBg / cinFg). iOS doesn't expose an API to retint the
                // Dynamic Island blob itself, so we paint cinBg inside the
                // content area; a thin dark system ring at the blob edges is
                // unavoidable. Subtitle + body mirror LockScreenView.activeView.
                DynamicIslandExpandedRegion(.leading) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.body.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            if let sub = context.state.subtitle, !sub.isEmpty {
                                Text(sub)
                                    .font(.cinMono(9))
                                    .foregroundStyle(Color.cinSub)
                                    .kerning(1.5)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 6)
                                Rectangle()
                                    .fill(Color.cinLine)
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 14)
                            }
                            Text(context.state.body)
                                .font(.cinSerif(13))
                                .foregroundStyle(Color.cinFg)
                                .multilineTextAlignment(.leading)
                                .lineLimit(5)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, context.state.subtitle?.isEmpty == false ? 8 : 12)
                                .padding(.bottom, 12)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.cinBg)
                    }
                }
            } compactLeading: {
                // Empty when idle; subtle dot when agent has sent a message
                if !context.state.body.isEmpty {
                    Circle()
                        .fill(Color.cinAccent1)
                        .frame(width: 6, height: 6)
                        .padding(.leading, 2)
                }
            } compactTrailing: {
                EmptyView()
            } minimal: {
                // Minimal presence — tiny dot so the island isn't jarring
                Circle()
                    .fill(Color.cinAccent1.opacity(0.5))
                    .frame(width: 5, height: 5)
            }
            .widgetURL(URL(string: "feedlingtest://live-activity"))
            .keylineTint(Color.cinAccent1)
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let state: ScreenActivityAttributes.ContentState

    private var days: Int {
        Int(state.data["days"] ?? "0") ?? 0
    }

    var body: some View {
        Group {
            if state.body.isEmpty {
                idleView
            } else {
                activeView
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.cinBg)
        .activityBackgroundTint(Color.cinBg)
        .activitySystemActionForegroundColor(Color.cinFg)
    }

    // Idle: days-together display
    private var idleView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(days)")
                .font(.cinNewsreader(32))
                .foregroundStyle(Color.cinAccent1)
            Text(days == 1 ? "day together" : "days together")
                .font(.cinNewsreader(14, italic: true))
                .foregroundStyle(Color.cinSub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // Active push: show agent's message
    private var activeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sub = state.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.cinMono(9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.5)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.cinLine)
                    .frame(height: 0.5)
                    .padding(.horizontal, 20)
            }

            Text(state.body)
                .font(.cinSerif(13))
                .foregroundStyle(Color.cinFg)
                .lineLimit(4)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, state.subtitle?.isEmpty == false ? 10 : 18)
                .padding(.bottom, 18)
        }
    }
}

// MARK: - Preview

extension ScreenActivityAttributes {
    static var preview: ScreenActivityAttributes {
        .init(activityId: "preview-id")
    }
}

extension ScreenActivityAttributes.ContentState {
    static var previewIdle: ScreenActivityAttributes.ContentState {
        .init(
            title: "",
            body: "",
            data: ["days": "42"],
            updatedAt: Date()
        )
    }
    static var previewActive: ScreenActivityAttributes.ContentState {
        .init(
            title: "",
            subtitle: "TikTok · 45m",
            body: "你今天刷了 45 分钟 TikTok，差不多该歇一歇了。",
            data: ["days": "42"],
            updatedAt: Date()
        )
    }
}
