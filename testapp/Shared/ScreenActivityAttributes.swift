import ActivityKit
import Foundation

struct ScreenActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Top app name, e.g. "TikTok"
        var topApp: String
        /// Total screen time in minutes for that app today
        var screenTimeMinutes: Int
        /// Message composed by OpenClaw, e.g. "You've been on TikTok for 45 min"
        var message: String
        /// When this state was pushed
        var updatedAt: Date
    }

    /// Unique ID for this activity session
    var activityId: String
}
