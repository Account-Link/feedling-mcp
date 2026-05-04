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

    /// Days with user — set by IdentityViewModel when identity loads
    var daysWithUser: Int = 0

    private var backendURL: String { FeedlingAPI.baseURL }

    private init() {
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
            title: "",
            body: "",
            data: ["days": "\(daysWithUser)"],
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
        print("[LiveActivity] 🔄 Updated: \(state.title) — \(state.body.prefix(40))")
    }

    /// Call when identity card loads or days change. Updates the idle lock screen display.
    func setDays(_ days: Int) {
        daysWithUser = days
        guard let activity = currentActivity,
              lastState?.body.isEmpty != false else { return }
        Task {
            let updated = ScreenActivityAttributes.ContentState(
                title: lastState?.title ?? "",
                body: lastState?.body ?? "",
                data: ["days": "\(days)"],
                updatedAt: Date()
            )
            await activity.update(.init(state: updated, staleDate: nil))
        }
    }

    func stopActivity() async {
        guard let activity = currentActivity else { return }
        let finalState = ScreenActivityAttributes.ContentState(
            title: "",
            body: "",
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

    // Called after apiKey becomes available to upload any tokens that were skipped earlier.
    func retryPendingTokenUploads() async {
        if let token = deviceToken {
            await upload(path: "/v1/push/register-token", body: ["type": "device", "token": token])
        }
        if let token = activityPushToken, let activity = currentActivity {
            await upload(path: "/v1/push/register-token",
                         body: ["type": "live_activity", "token": token, "activity_id": activity.id])
        }
        if let token = pushToStartToken {
            await upload(path: "/v1/push/register-token", body: ["type": "push_to_start", "token": token])
        }
    }

    private func upload(path: String, body: [String: String]) async {
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        guard let req = FeedlingAPI.shared.authorizedRequest(path: path, method: "POST", body: bodyData) else { return }
        _ = try? await URLSession.shared.data(for: req)
        print("[Token] 📤 Uploaded \(body["type"] ?? "?") token")
    }
}
