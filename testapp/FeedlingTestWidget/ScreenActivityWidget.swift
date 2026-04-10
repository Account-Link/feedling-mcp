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
                    ExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "iphone")
                    .foregroundStyle(.cyan)
                    .font(.caption)
            } compactTrailing: {
                Text("\(context.state.topApp) · \(context.state.screenTimeMinutes)m")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "iphone")
                    .foregroundStyle(.cyan)
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .foregroundStyle(.cyan)
                    Text(state.topApp)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(state.screenTimeMinutes)m")
                        .font(.subheadline.bold())
                        .foregroundStyle(.cyan)
                }
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.85))
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
    }
}

// MARK: - Dynamic Island Expanded Regions

private struct ExpandedLeading: View {
    let state: ScreenActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.topApp)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text("\(state.screenTimeMinutes) min today")
                .font(.caption2)
                .foregroundStyle(.cyan)
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailing: View {
    let state: ScreenActivityAttributes.ContentState

    var body: some View {
        Image(systemName: "iphone")
            .font(.title2)
            .foregroundStyle(.cyan)
            .padding(.trailing, 4)
    }
}

private struct ExpandedBottom: View {
    let state: ScreenActivityAttributes.ContentState

    var body: some View {
        Text(state.message)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.bottom, 4)
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
              message: "45 min on TikTok. That's your entertainment budget.",
              updatedAt: Date())
    }
}

#Preview("Compact", as: .dynamicIsland(.compact), using: ScreenActivityAttributes.preview) {
    ScreenActivityWidget()
} contentStates: {
    ScreenActivityAttributes.ContentState.preview
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: ScreenActivityAttributes.preview) {
    ScreenActivityWidget()
} contentStates: {
    ScreenActivityAttributes.ContentState.preview
}

#Preview("Lock Screen", as: .content, using: ScreenActivityAttributes.preview) {
    ScreenActivityWidget()
} contentStates: {
    ScreenActivityAttributes.ContentState.preview
}
