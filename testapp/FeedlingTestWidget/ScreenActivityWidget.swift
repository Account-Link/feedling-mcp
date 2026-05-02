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
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.cinAccent1)
                            .frame(width: 6, height: 6)
                        Text(context.state.title)
                            .font(.cinMono(12, weight: .medium))
                            .foregroundStyle(Color.cinAccent1)
                            .kerning(0.5)
                    }
                    .padding(.leading, 6)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let sub = context.state.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.cinMono(10))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.trailing, 6)
                            .padding(.top, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.body)
                        .font(.cinSerif(14))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
            } compactLeading: {
                Circle()
                    .fill(Color.cinAccent1)
                    .frame(width: 7, height: 7)
                    .padding(.leading, 2)
            } compactTrailing: {
                Text(context.state.title)
                    .font(.cinMono(10, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .lineLimit(1)
            } minimal: {
                Circle()
                    .fill(Color.cinAccent1)
                    .frame(width: 7, height: 7)
            }
            .widgetURL(URL(string: "feedlingtest://live-activity"))
            .keylineTint(Color.cinAccent1)
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let state: ScreenActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.cinAccent1)
                        .frame(width: 6, height: 6)
                    Text(state.title.uppercased())
                        .font(.cinMono(9, weight: .medium))
                        .foregroundStyle(Color.cinAccent1)
                        .kerning(2)
                }
                Spacer()
                if let sub = state.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.cinMono(9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.cinLine)
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // Body
            Text(state.body)
                .font(.cinSerif(13))
                .foregroundStyle(Color.cinFg)
                .lineLimit(4)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cinBg)
        .activityBackgroundTint(Color.cinBg)
        .activitySystemActionForegroundColor(Color.cinFg)
    }
}

// MARK: - Preview

extension ScreenActivityAttributes {
    static var preview: ScreenActivityAttributes {
        .init(activityId: "preview-id")
    }
}

extension ScreenActivityAttributes.ContentState {
    static var preview: ScreenActivityAttributes.ContentState {
        .init(
            title: "OpenClaw",
            body: "你今天刷了 45 分钟 TikTok，差不多该歇一歇了。",
            data: ["top_app": "TikTok", "minutes": "45"],
            updatedAt: Date()
        )
    }
}
