import ActivityKit
import ReplayKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var lam: LiveActivityManager
    @State private var showBroadcastPicker = false

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
            VStack(spacing: 0) {

                // MARK: — Screen Recording Button
                VStack(spacing: 6) {
                    Text("SCREEN RECORDING")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    ZStack {
                        BroadcastPickerView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                        // Invisible overlay to ensure touches pass through to the picker
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .background(Color(UIColor.systemGroupedBackground))

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
                } // List
            } // VStack
            .navigationTitle("Feedling Test")
        }
    }

    @ViewBuilder
    private func tokenRow(label: String, value: String?) -> some View {

        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(value.prefix(24) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = value
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(label, value: "—")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Broadcast Picker

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width - 32, height: 52))
        picker.preferredExtension = "com.feedling.mcp.broadcast"
        picker.showsMicrophoneButton = false
        picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Style the inner button
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.imageView?.tintColor = .white
                button.backgroundColor = .clear
            }
        }
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width - 32, height: 52)
    }
}
