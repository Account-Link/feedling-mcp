import ActivityKit
import Foundation
import SwiftUI

@MainActor
class LiveActivityManager: ObservableObject {

    static let shared = LiveActivityManager()

    @Published var currentActivity: Activity<ScreenActivityAttributes>?
    @Published var isActive = false
    @Published var deviceToken: String?
    @Published var activityPushToken: String?
    @Published var pushToStartToken: String?
    @Published var lastState: ScreenActivityAttributes.ContentState?

    private let backendURL: String

    private init() {
        backendURL = ProcessInfo.processInfo.environment["FEEDLING_API_URL"] ?? "http://localhost:5001"

        // Reconnect to any activity that survived an app restart
        if let existing = Activity<ScreenActivityAttributes>.activities.first {
            currentActivity = existing
            isActive = true
            observeTokens(for: existing)
        }

        // Observe push-to-start tokens (iOS 17.2+)
        if #available(iOS 17.2, *) {
            observePushToStartToken()
        }
    }

    // MARK: - Lifecycle

    func startActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] ❌ Activities not enabled on this device")
            return
        }

        // Reuse existing activity if any
        if let existing = Activity<ScreenActivityAttributes>.activities.first {
            currentActivity = existing
            isActive = true
            observeTokens(for: existing)
            return
        }

        let attrs = ScreenActivityAttributes(activityId: UUID().uuidString)
        let initialState = ScreenActivityAttributes.ContentState(
            topApp: "—",
            screenTimeMinutes: 0,
            message: "Waiting for data from OpenClaw...",
            updatedAt: Date()
        )

        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: .init(state: initialState, staleDate: nil),
                pushType: .token
            )
            currentActivity = activity
            isActive = true
            lastState = initialState
            observeTokens(for: activity)
            print("[LiveActivity] ✅ Started: \(activity.id)")
        } catch {
            print("[LiveActivity] ❌ Failed to start: \(error.localizedDescription)")
        }
    }

    func updateActivity(state: ScreenActivityAttributes.ContentState) async {
        guard let activity = currentActivity else {
            print("[LiveActivity] ⚠️ No active activity to update")
            return
        }
        await activity.update(.init(state: state, staleDate: nil))
        lastState = state
        print("[LiveActivity] 🔄 Updated: \(state.topApp) \(state.screenTimeMinutes)m")
    }

    func stopActivity() async {
        guard let activity = currentActivity else { return }
        let finalState = ScreenActivityAttributes.ContentState(
            topApp: lastState?.topApp ?? "—",
            screenTimeMinutes: lastState?.screenTimeMinutes ?? 0,
            message: "Session ended.",
            updatedAt: Date()
        )
        await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .default)
        currentActivity = nil
        isActive = false
        activityPushToken = nil
        lastState = nil
        print("[LiveActivity] 🛑 Stopped")
    }

    // MARK: - Token registration

    func registerDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await upload(path: "/v1/push/register-token",
                            body: ["type": "device", "token": hex]) }
    }

    // MARK: - Private helpers

    private func observeTokens(for activity: Activity<ScreenActivityAttributes>) {
        // Activity push token (used to update this specific activity via APNs)
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self.activityPushToken = hex }
                await upload(path: "/v1/push/register-token",
                             body: ["type": "live_activity", "token": hex,
                                    "activity_id": activity.id])
            }
        }

        // State updates (in case a push arrives while app is in foreground)
        Task {
            for await content in activity.contentUpdates {
                await MainActor.run { self.lastState = content.state }
            }
        }
    }

    @available(iOS 17.2, *)
    private func observePushToStartToken() {
        Task {
            for await tokenData in Activity<ScreenActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self.pushToStartToken = hex }
                await upload(path: "/v1/push/register-token",
                             body: ["type": "push_to_start", "token": hex])
            }
        }
    }

    private func upload(path: String, body: [String: String]) async {
        guard let url = URL(string: backendURL + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        print("[Token] 📤 Uploaded \(body["type"] ?? "?") token")
    }
}
