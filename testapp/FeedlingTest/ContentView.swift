import ActivityKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var lam: LiveActivityManager

    // Mock data options for local simulation
    private let mockStates: [ScreenActivityAttributes.ContentState] = [
        .init(topApp: "TikTok", screenTimeMinutes: 45,
              message: "45 min on TikTok. That's your entertainment budget.", updatedAt: Date()),
        .init(topApp: "Figma", screenTimeMinutes: 95,
              message: "Deep work mode. 95 min in Figma.", updatedAt: Date()),
        .init(topApp: "Instagram", screenTimeMinutes: 28,
              message: "28 min on Instagram. Wrap it up?", updatedAt: Date()),
    ]
    @State private var mockIndex = 0

    var body: some View {
        NavigationStack {
            List {

                // MARK: — Status
                Section("Live Activity") {
                    HStack {
                        Circle()
                            .fill(lam.isActive ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(lam.isActive ? "Active" : "Inactive")
                            .foregroundStyle(lam.isActive ? .primary : .secondary)
                    }

                    if let state = lam.lastState {
                        LabeledContent("Top App", value: state.topApp)
                        LabeledContent("Screen Time", value: "\(state.screenTimeMinutes) min")
                        LabeledContent("Message", value: state.message)
                    }
                }

                // MARK: — Controls
                Section("Controls") {
                    if !lam.isActive {
                        Button {
                            Task { await lam.startActivity() }
                        } label: {
                            Label("Start Live Activity", systemImage: "play.fill")
                        }
                    } else {
                        Button(role: .destructive) {
                            Task { await lam.stopActivity() }
                        } label: {
                            Label("Stop Live Activity", systemImage: "stop.fill")
                        }

                        Button {
                            let state = mockStates[mockIndex % mockStates.count]
                            mockIndex += 1
                            Task { await lam.updateActivity(state: state) }
                        } label: {
                            Label("Simulate Push Update", systemImage: "arrow.clockwise")
                        }
                    }
                }

                // MARK: — Tokens (for wiring up real APNs)
                Section("Push Tokens") {
                    tokenRow(label: "Device Token", value: lam.deviceToken)
                    tokenRow(label: "Activity Token", value: lam.activityPushToken)
                    if #available(iOS 17.2, *) {
                        tokenRow(label: "Push-to-Start Token", value: lam.pushToStartToken)
                    }
                }
            }
            .navigationTitle("Feedling Test")
        }
    }

    @ViewBuilder
    private func tokenRow(label: String, value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.prefix(24) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .onTapGesture {
                        UIPasteboard.general.string = value
                    }
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(label, value: "—")
                .foregroundStyle(.secondary)
        }
    }
}
