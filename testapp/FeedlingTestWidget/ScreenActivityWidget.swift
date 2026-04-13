import ActivityKit
import SwiftUI
import WidgetKit

struct ScreenActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScreenActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.cyan)
                            .font(.system(size: 12, weight: .bold))
                        Text("OpenClaw")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    .padding(.leading, 6)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.screenTimeMinutes > 0 {
                        Text("\(context.state.topApp) \(context.state.screenTimeMinutes)m")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.trailing, 6)
                            .padding(.top, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 11))
            } compactTrailing: {
                Text(context.state.message.prefix(18))
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 10))
            }
            .widgetURL(URL(string: "feedlingtest://live-activity"))
            .keylineTint(.cyan)
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let state: ScreenActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.cyan)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenClaw")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Text(state.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(4)
                if state.screenTimeMinutes > 0 {
                    Text("\(state.topApp) · \(state.screenTimeMinutes)m")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.9))
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
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
        .init(topApp: "TikTok", screenTimeMinutes: 45,
              message: "你今天刷了 45 分钟 TikTok，差不多该歇一歇了。",
              updatedAt: Date())
    }
}
