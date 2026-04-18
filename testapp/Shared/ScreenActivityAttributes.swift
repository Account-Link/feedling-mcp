import ActivityKit
import Foundation

struct ScreenActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Short heading shown in Dynamic Island compact/expanded leading
        var title: String
        /// Optional one-line context (e.g. "TikTok · 45m")
        var subtitle: String?
        /// Main message body
        var body: String
        /// Reserved for future persona support — use "default" for now
        var personaId: String?
        /// Reserved for future template support — use "default" for now
        var templateId: String?
        /// Arbitrary key-value extension bag
        /// Screen-time example: ["top_app": "TikTok", "minutes": "45"]
        var data: [String: String]
        /// When this state was pushed
        var updatedAt: Date

        init(
            title: String,
            subtitle: String? = nil,
            body: String,
            personaId: String? = "default",
            templateId: String? = "default",
            data: [String: String] = [:],
            updatedAt: Date
        ) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.personaId = personaId
            self.templateId = templateId
            self.data = data
            self.updatedAt = updatedAt
        }
    }

    /// Unique ID for this activity session
    var activityId: String
}
